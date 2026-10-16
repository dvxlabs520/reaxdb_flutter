// Runs the example on a device or simulator, with the real path_provider
// and the real Keychain or Keystore:
//
//   flutter test integration_test
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
import 'package:reaxdb_flutter_example/main.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

Finder inList(String text) =>
    find.descendant(of: find.byType(Scrollable), matching: find.text(text));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('notes survive a restart, encrypted on disk', (
    WidgetTester tester,
  ) async {
    await ReaxFlutter.deleteDatabase(databaseName);

    ReaxDB? db;
    Future<ReaxDB> open() async => db = await ReaxFlutter.open(
      databaseName,
      encrypted: true,
      keepInMemory: true,
    );

    await tester.pumpWidget(NotesApp(key: UniqueKey(), openDatabase: open));
    await waitFor(tester, find.text('No notes here yet.'));

    await tester.enterText(find.byKey(const Key('note-input')), 'Secret note');
    await tester.tap(find.byKey(const Key('add-note')));
    await waitFor(tester, inList('Secret note'));

    // The key is in the platform's secure storage.
    final String? key = await ReaxFlutter.defaultSecureStorage.read(
      key: ReaxFlutter.keyNameFor(databaseName),
    );
    expect(key, isNotNull);

    // The files are in the app support folder and hold no plain text.
    await db!.close();
    final String path = await ReaxFlutter.pathFor(databaseName);
    final List<int> bytes = <int>[
      for (final FileSystemEntity e in Directory(
        path,
      ).listSync(recursive: true))
        if (e is File) ...e.readAsBytesSync(),
    ];
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes).contains('Secret note'), isFalse);

    // "Restart": a new app instance opens the same database with the stored
    // key and shows the note again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(NotesApp(key: UniqueKey(), openDatabase: open));
    await waitFor(tester, inList('Secret note'));

    await tester.pumpWidget(const SizedBox());
    await db!.close();
    await ReaxFlutter.deleteDatabase(databaseName);
  });
}
