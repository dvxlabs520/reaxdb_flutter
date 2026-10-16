import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
import 'package:reaxdb_flutter/src/watch_query.dart' show watchResults;

import 'helpers.dart';

/// A list of titles that rebuilds from a query stream.
class TitleList extends StatelessWidget {
  const TitleList({super.key, required this.stream});

  final Stream<List<Map<String, dynamic>>> stream;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: StreamBuilder<List<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('error: ${snapshot.error}');
          final List<Map<String, dynamic>>? docs = snapshot.data;
          if (docs == null) return const Text('loading');
          if (docs.isEmpty) return const Text('empty');
          return ListView(
            children: [for (final d in docs) Text(d['title'] as String)],
          );
        },
      ),
    );
  }
}

/// Lets real file I/O finish, then lets the widget tree catch up.
///
/// Widget tests run on a fake clock, so database work only completes inside
/// [WidgetTester.runAsync] and timers only fire when the clock is pumped.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(finder, findsOneWidget);
}

void main() {
  testWidgets('StreamBuilder follows the results of watchResults', (
    WidgetTester tester,
  ) async {
    final StreamController<Object?> changes = StreamController<Object?>();
    List<Map<String, dynamic>> current = <Map<String, dynamic>>[];
    int runs = 0;
    final Stream<List<Map<String, dynamic>>> stream =
        watchResults<List<Map<String, dynamic>>>(
          changes: () => changes.stream,
          run: () async {
            runs++;
            return List<Map<String, dynamic>>.of(current);
          },
          debounce: const Duration(milliseconds: 50),
          distinct: true,
        );

    await tester.pumpWidget(TitleList(stream: stream));
    expect(find.text('loading'), findsOneWidget);
    await tester.pump();
    expect(find.text('empty'), findsOneWidget);

    current = <Map<String, dynamic>>[
      {'title': 'first'},
    ];
    changes
      ..add(null)
      ..add(null)
      ..add(null);
    await tester.pump(const Duration(milliseconds: 49));
    expect(find.text('first'), findsNothing, reason: 'still waiting');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(runs, 2, reason: 'three changes, one query');

    // Unmounting cancels the subscription and the change stream.
    await tester.pumpWidget(const SizedBox());
    expect(changes.hasListener, isFalse);
    // Not awaited: the done future of a cancelled controller never fires on
    // the fake clock.
    unawaited(changes.close());
  });

  group('with a real database', () {
    late Directory root;
    late ReaxDB db;

    setUp(() async {
      root = await setUpFakePlatform();
    });
    tearDown(() => tearDownFakePlatform(root));

    testWidgets('a StreamBuilder shows writes as they happen', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        db = await ReaxFlutter.open('notes', encrypted: true);
        await db.put('notes:1', {'title': 'Buy milk', 'done': false});
        await db.put('notes:2', {'title': 'Old task', 'done': true});
      });

      await tester.pumpWidget(
        TitleList(
          stream: db.watchQuery(db.query('notes').whereEquals('done', false)),
        ),
      );
      await pumpUntilFound(tester, find.text('Buy milk'));
      expect(find.text('Old task'), findsNothing);

      await tester.runAsync(
        () => db.put('notes:3', {'title': 'Call Ana', 'done': false}),
      );
      await pumpUntilFound(tester, find.text('Call Ana'));

      await tester.runAsync(
        () => db.put('notes:1', {'title': 'Buy milk', 'done': true}),
      );
      for (
        int i = 0;
        i < 100 && find.text('Buy milk').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('Buy milk'), findsNothing);
      expect(find.text('Call Ana'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    });
  });
}
