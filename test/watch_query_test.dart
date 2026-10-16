import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
import 'package:reaxdb_flutter/src/watch_query.dart' show watchResults;

import 'helpers.dart';

typedef Docs = List<Map<String, dynamic>>;

/// Collects a stream's events so tests can wait for a given count.
class Recorder<T> {
  Recorder(Stream<T> stream) {
    subscription = stream.listen(
      (T value) {
        values.add(value);
        _changed();
      },
      onError: (Object error) {
        errors.add(error);
        _changed();
      },
      onDone: () {
        isDone = true;
        _changed();
      },
    );
  }

  late final StreamSubscription<T> subscription;
  final List<T> values = <T>[];
  final List<Object> errors = <Object>[];
  bool isDone = false;
  Completer<void> _signal = Completer<void>();

  void _changed() {
    if (!_signal.isCompleted) _signal.complete();
  }

  Future<void> waitFor(bool Function() condition) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out: values=$values errors=$errors done=$isDone');
      }
      _signal = Completer<void>();
      await _signal.future.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () {},
      );
    }
  }

  Future<void> cancel() => subscription.cancel();
}

List<String> titles(Docs docs) => [for (final d in docs) d['title'] as String];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('watchQuery on a real database', () {
    late Directory root;
    late ReaxDB db;

    setUp(() async {
      root = await setUpFakePlatform();
      db = await ReaxFlutter.open('notes');
    });
    tearDown(() => tearDownFakePlatform(root));

    test(
      'emits the current result, then a new one after each change',
      () async {
        await db.put('notes:1', {'title': 'a', 'n': 1});
        final Recorder<Docs> r = Recorder<Docs>(
          db.watchQuery(db.query('notes').orderBy('n')),
        );
        await r.waitFor(() => r.values.length == 1);
        expect(titles(r.values.last), ['a']);

        await db.put('notes:2', {'title': 'b', 'n': 2});
        await r.waitFor(() => r.values.length == 2);
        expect(titles(r.values.last), ['a', 'b']);

        await db.delete('notes:1');
        await r.waitFor(() => r.values.length == 3);
        expect(titles(r.values.last), ['b']);
        await r.cancel();
      },
    );

    test('ignores other collections and unchanged results', () async {
      await db.put('notes:1', {'title': 'a', 'done': false});
      final Recorder<Docs> r = Recorder<Docs>(
        db.watchQuery(db.query('notes').whereEquals('done', false)),
      );
      await r.waitFor(() => r.values.length == 1);

      await db.put('other:1', {'title': 'x', 'done': false});
      // Matches the collection but not the filter: the result is the same.
      await db.put('notes:2', {'title': 'b', 'done': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(r.values, hasLength(1));

      await db.put('notes:3', {'title': 'c', 'done': false});
      await r.waitFor(() => r.values.length == 2);
      expect(titles(r.values.last), ['a', 'c']);
      await r.cancel();
    });

    test('distinct: false emits after every change', () async {
      final Recorder<Docs> r = Recorder<Docs>(
        db.watchQuery(
          db.query('notes').whereEquals('done', false),
          distinct: false,
        ),
      );
      await r.waitFor(() => r.values.length == 1);
      await db.put('notes:1', {'title': 'a', 'done': true});
      await r.waitFor(() => r.values.length == 2);
      expect(r.values.last, isEmpty);
      await r.cancel();
    });

    test('a burst of writes costs one or two queries', () async {
      final Recorder<Docs> r = Recorder<Docs>(
        db.watchQuery(
          db.query('notes'),
          debounce: const Duration(milliseconds: 200),
        ),
      );
      await r.waitFor(() => r.values.length == 1);

      await db.putBatch({
        for (int i = 0; i < 50; i++) 'notes:$i': {'title': 't$i'},
      });
      for (int i = 50; i < 60; i++) {
        await db.put('notes:$i', {'title': 't$i'});
      }
      await r.waitFor(() => r.values.last.length == 60);
      expect(r.values.length, lessThanOrEqualTo(3));
      await r.cancel();
    });

    test('closes when the database closes', () async {
      final Recorder<Docs> r = Recorder<Docs>(db.watchQuery(db.query('notes')));
      await r.waitFor(() => r.values.length == 1);
      await db.close();
      await r.waitFor(() => r.isDone);
      expect(r.errors, isEmpty);
    });

    test('reports a closed database as an error and closes', () async {
      final QueryBuilder query = db.query('notes');
      await db.close();
      final Recorder<Docs> r = Recorder<Docs>(db.watchQuery(query));
      await r.waitFor(() => r.isDone);
      expect(r.errors.single, isA<DatabaseClosedException>());
    });
  });

  group('watchResults', () {
    test('runs again after a change that arrives while a query runs', () async {
      final StreamController<Object?> changes = StreamController<Object?>();
      int calls = 0;
      Completer<void> gate = Completer<void>();
      final Recorder<int> r = Recorder<int>(
        watchResults<int>(
          changes: () => changes.stream,
          run: () async {
            final int call = ++calls;
            await gate.future;
            return call;
          },
          debounce: Duration.zero,
          distinct: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      changes.add(null); // Arrives while the first query is still running.
      gate.complete();
      await r.waitFor(() => r.values.length == 2);
      expect(r.values, [1, 2]);
      gate = Completer<void>()..complete();
      await r.cancel();
      await changes.close();
    });

    test('keeps going after a query error', () async {
      final StreamController<Object?> changes = StreamController<Object?>();
      int calls = 0;
      final Recorder<int> r = Recorder<int>(
        watchResults<int>(
          changes: () => changes.stream,
          run: () async {
            calls++;
            if (calls == 1) throw StateError('boom');
            return calls;
          },
          debounce: Duration.zero,
          distinct: true,
        ),
      );
      await r.waitFor(() => r.errors.length == 1);
      changes.add(null);
      await r.waitFor(() => r.values.length == 1);
      expect(r.values.single, 2);
      await r.cancel();
      await changes.close();
    });

    test('listens again after a change stream overflow', () async {
      final List<StreamController<Object?>> streams =
          <StreamController<Object?>>[];
      int calls = 0;
      final Recorder<int> r = Recorder<int>(
        watchResults<int>(
          changes: () {
            final StreamController<Object?> c = StreamController<Object?>();
            streams.add(c);
            return c.stream;
          },
          run: () async => ++calls,
          debounce: Duration.zero,
          distinct: false,
        ),
      );
      await r.waitFor(() => r.values.length == 1);

      streams.first.addError(const ChangeStreamOverflowException('overflow'));
      await streams.first.close();
      await r.waitFor(() => r.values.length == 2);
      expect(streams, hasLength(2));
      expect(r.errors, isEmpty);
      expect(r.isDone, isFalse);

      streams.last.add(null);
      await r.waitFor(() => r.values.length == 3);
      await r.cancel();
      await streams.last.close();
    });

    test('does not run while paused, and runs once on resume', () async {
      final StreamController<Object?> changes = StreamController<Object?>();
      int calls = 0;
      final Recorder<int> r = Recorder<int>(
        watchResults<int>(
          changes: () => changes.stream,
          run: () async => ++calls,
          debounce: Duration.zero,
          distinct: false,
        ),
      );
      await r.waitFor(() => r.values.length == 1);

      r.subscription.pause();
      changes
        ..add(null)
        ..add(null)
        ..add(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);

      r.subscription.resume();
      await r.waitFor(() => r.values.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 2);
      await r.cancel();
      await changes.close();
    });

    test('stops when cancelled', () async {
      bool cancelled = false;
      final StreamController<Object?> changes = StreamController<Object?>(
        onCancel: () => cancelled = true,
      );
      int calls = 0;
      final Recorder<int> r = Recorder<int>(
        watchResults<int>(
          changes: () => changes.stream,
          run: () async => ++calls,
          debounce: const Duration(milliseconds: 20),
          distinct: false,
        ),
      );
      await r.waitFor(() => r.values.length == 1);
      changes.add(null);
      await r.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, 1, reason: 'the pending run must be dropped');
      expect(cancelled, isTrue);
      await changes.close();
    });
  });
}
