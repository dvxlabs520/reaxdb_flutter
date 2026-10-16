import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
import 'package:reaxdb_flutter_example/main.dart';

class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

/// Lets real file I/O finish, then lets the widget tree catch up, until
/// [done] is true.
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (int i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(done(), isTrue);
}

bool empty() => find.text('No notes here yet.').evaluate().isNotEmpty;

/// Whether [text] is in the note list (not in the text field).
bool shows(String text) => find
    .descendant(of: find.byType(Scrollable), matching: find.text(text))
    .evaluate()
    .isNotEmpty;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reaxdb_example_test_');
    PathProviderPlatform.instance = FakePathProvider(root);
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() async {
    await ReaxDB.closeAll();
    await root.delete(recursive: true);
  });

  testWidgets('add, complete, filter and delete notes', (
    WidgetTester tester,
  ) async {
    // Real file I/O must run outside the fake clock of widget tests, so the
    // database is opened here and handed to the app.
    final ReaxDB db = (await tester.runAsync(
      () => ReaxFlutter.open(databaseName, encrypted: true),
    ))!;
    await tester.pumpWidget(NotesApp(openDatabase: () async => db));
    await settle(tester, () => empty());

    // The database was created encrypted, with a key in secure storage.
    final String? key = await tester.runAsync<String?>(
      () => ReaxFlutter.defaultSecureStorage.read(
        key: ReaxFlutter.keyNameFor(databaseName),
      ),
    );
    expect(key, isNotNull);

    await tester.enterText(find.byKey(const Key('note-input')), 'Buy milk');
    await tester.tap(find.byKey(const Key('add-note')));
    await settle(tester, () => shows('Buy milk'));

    await tester.enterText(find.byKey(const Key('note-input')), 'Call Ana');
    await tester.tap(find.byKey(const Key('add-note')));
    await settle(tester, () => shows('Call Ana'));

    // Newest first.
    expect(
      tester.getTopLeft(find.text('Call Ana')).dy,
      lessThan(tester.getTopLeft(find.text('Buy milk')).dy),
    );

    // Complete "Buy milk", then show only open notes.
    await tester.tap(find.text('Buy milk'));
    await settle(
      tester,
      () => tester
          .widget<CheckboxListTile>(
            find.ancestor(
              of: find.text('Buy milk'),
              matching: find.byType(CheckboxListTile),
            ),
          )
          .value!,
    );
    await tester.tap(find.text('Open'));
    await settle(tester, () => !shows('Buy milk'));
    expect(shows('Call Ana'), isTrue);

    await tester.tap(find.text('Done'));
    await settle(tester, () => shows('Buy milk') && !shows('Call Ana'));

    // Swipe the last note away.
    await tester.drag(find.text('Buy milk'), const Offset(-600, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester, () => empty());

    // Close on the real clock while pumping, because the change streams the
    // app listens to finish on the fake one. The app's dispose then has
    // nothing left to do.
    bool closed = false;
    await tester.runAsync(() async {
      unawaited(db.close().then((_) => closed = true));
    });
    await settle(tester, () => closed);
  });

  testWidgets('shows an error when the database cannot open', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      NotesApp(
        openDatabase: () =>
            Future<ReaxDB>.error(const EncryptionException('key missing')),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Could not open the database.'), findsOneWidget);
    expect(find.textContaining('key missing'), findsOneWidget);
  });
}
