import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reaxdb_flutter/reaxdb_flutter.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const FlutterSecureStorage storage = ReaxFlutter.defaultSecureStorage;

  setUp(() async => root = await setUpFakePlatform());
  tearDown(() => tearDownFakePlatform(root));

  group('paths', () {
    test('stores databases in the app support directory', () async {
      expect(
        await ReaxFlutter.pathFor('notes'),
        p.join(root.path, 'reaxdb', 'notes'),
      );

      final ReaxDB db = await ReaxFlutter.open('notes');
      // ReaxDB reports canonical paths (lowercased on Windows).
      expect(db.path, p.canonicalize(p.join(root.path, 'reaxdb', 'notes')));
      await db.put('note:1', {'title': 'Hello'});
      await db.close();

      final ReaxDB reopened = await ReaxFlutter.open('notes');
      expect(await reopened.get<Map<String, dynamic>>('note:1'), {
        'title': 'Hello',
      });
    });

    test('rejects names that are not a single folder name', () async {
      for (final String name in <String>[
        '',
        '.',
        '..',
        '../notes',
        'a/b',
        r'a\b',
        '.hidden',
        'with space',
        'x' * 101,
      ]) {
        await expectLater(
          ReaxFlutter.open(name),
          throwsArgumentError,
          reason: name,
        );
        expect(() => ReaxFlutter.keyNameFor(name), throwsArgumentError);
      }
      expect(await ReaxFlutter.pathFor('my-app.db_2'), isNotEmpty);
    });
  });

  group('encryption key', () {
    test('creates a 32-byte key on first open and reuses it', () async {
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      await db.put('secret:1', {'pin': '1234'});
      await db.close();

      final String? stored = await storage.read(
        key: ReaxFlutter.keyNameFor('vault'),
      );
      expect(stored, isNotNull);
      expect(base64Decode(stored!), hasLength(32));

      final ReaxDB reopened = await ReaxFlutter.open('vault', encrypted: true);
      expect(await reopened.get<Map<String, dynamic>>('secret:1'), {
        'pin': '1234',
      });
      await reopened.close();
      expect(
        await storage.read(key: ReaxFlutter.keyNameFor('vault')),
        stored,
        reason: 'the key must not change between opens',
      );
    });

    test('each database gets its own key', () async {
      await (await ReaxFlutter.open('a', encrypted: true)).close();
      await (await ReaxFlutter.open('b', encrypted: true)).close();
      expect(
        await storage.read(key: ReaxFlutter.keyNameFor('a')),
        isNot(await storage.read(key: ReaxFlutter.keyNameFor('b'))),
      );
    });

    test('the data on disk is really encrypted', () async {
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      await db.put('secret:1', {'value': 'plain-text-marker'});
      await db.close();

      final List<int> bytes = <int>[
        for (final FileSystemEntity entity in Directory(
          await ReaxFlutter.pathFor('vault'),
        ).listSync(recursive: true))
          if (entity is File) ...entity.readAsBytesSync(),
      ];
      expect(latin1.decode(bytes).contains('plain-text-marker'), isFalse);

      // Opening without the key fails instead of returning garbage.
      await expectLater(
        ReaxFlutter.open('vault'),
        throwsA(isA<ReaxDbException>()),
      );
    });

    test('refuses to create a new key for existing files', () async {
      await (await ReaxFlutter.open('vault', encrypted: true)).close();
      await storage.delete(key: ReaxFlutter.keyNameFor('vault'));

      await expectLater(
        ReaxFlutter.open('vault', encrypted: true),
        throwsA(
          isA<EncryptionException>().having(
            (EncryptionException e) => e.message,
            'message',
            contains('deleteDatabase'),
          ),
        ),
      );
      expect(
        await storage.read(key: ReaxFlutter.keyNameFor('vault')),
        isNull,
        reason: 'no replacement key may be saved',
      );
    });

    test('rejects a damaged key', () async {
      await storage.write(
        key: ReaxFlutter.keyNameFor('short'),
        value: base64Encode(List<int>.filled(16, 1)),
      );
      await storage.write(
        key: ReaxFlutter.keyNameFor('garbage'),
        value: 'not base64!',
      );

      await expectLater(
        ReaxFlutter.open('short', encrypted: true),
        throwsA(isA<EncryptionException>()),
      );
      await expectLater(
        ReaxFlutter.open('garbage', encrypted: true),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('concurrent first opens agree on one key', () async {
      final List<Object> outcomes = await Future.wait(<Future<Object>>[
        for (int i = 0; i < 4; i++)
          ReaxFlutter.open(
            'race',
            encrypted: true,
          ).then<Object>((ReaxDB db) => db, onError: (Object e) => e),
      ]);
      final List<ReaxDB> opened = outcomes.whereType<ReaxDB>().toList();
      expect(opened, hasLength(1));
      expect(
        outcomes.whereType<DatabaseLockedException>(),
        hasLength(3),
        reason: '$outcomes',
      );

      await opened.single.put('k', 'v');
      await opened.single.close();
      final ReaxDB reopened = await ReaxFlutter.open('race', encrypted: true);
      expect(await reopened.get<String>('k'), 'v');
    });
  });

  group('deleteDatabase', () {
    test('removes the files and the key', () async {
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      await db.put('k', 'v');
      await db.close();

      await ReaxFlutter.deleteDatabase('vault');

      expect(Directory(await ReaxFlutter.pathFor('vault')).existsSync(), false);
      expect(await storage.read(key: ReaxFlutter.keyNameFor('vault')), isNull);

      final ReaxDB fresh = await ReaxFlutter.open('vault', encrypted: true);
      expect(await fresh.get<String>('k'), isNull);
    });

    test('does nothing for a database that does not exist', () async {
      await ReaxFlutter.deleteDatabase('missing');
    });
  });

  test('passes options through to ReaxDB.open', () async {
    await (await ReaxFlutter.open('versioned')).close();
    final ReaxDB db = await ReaxFlutter.open(
      'versioned',
      schemaVersion: 2,
      onUpgrade: (int from, int to, ReaxDB db) =>
          db.put('upgraded', '$from->$to'),
    );
    expect(await db.get<String>('upgraded'), '1->2');
  });
}
