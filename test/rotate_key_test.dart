import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reaxdb_flutter/reaxdb_flutter.dart';

import 'helpers.dart';

/// Secure storage that fails on demand, to stop a rotation at one step.
class FaultyStorage extends FlutterSecureStorage {
  FaultyStorage({this.failWrite, this.failDelete, this.wrongReadBack});

  /// Entries whose write throws, as the platform channel would.
  final String? failWrite;

  /// Entries whose delete throws.
  final String? failDelete;

  /// Entries that read back a different value than was written.
  final String? wrongReadBack;

  final Set<String> _written = <String>{};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failWrite) {
      throw PlatformException(code: 'write', message: 'Keychain is busy');
    }
    _written.add(key);
    return super.write(key: key, value: value);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == wrongReadBack && _written.contains(key)) return 'lost';
    return super.read(key: key);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failDelete) {
      throw PlatformException(code: 'delete', message: 'Keychain is busy');
    }
    return super.delete(key: key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const FlutterSecureStorage storage = ReaxFlutter.defaultSecureStorage;
  final String mainEntry = ReaxFlutter.keyNameFor('vault');
  final String nextEntry = '${ReaxFlutter.keyNameFor('vault')}.next';

  setUp(() async => root = await setUpFakePlatform());
  tearDown(() => tearDownFakePlatform(root));

  Future<String?> stored(String entry) => storage.read(key: entry);

  String newKey(int seed) => base64Encode(List<int>.filled(32, seed));

  /// Creates the encrypted database "vault" with one note and returns its
  /// key, as saved in secure storage.
  Future<String> createVault() async {
    final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
    await db.put('note:1', {'text': 'Buy milk'});
    await db.close();
    return (await stored(mainEntry))!;
  }

  /// Re-encrypts "vault" with [key] without touching secure storage: what
  /// is on disk once step 2 of a rotation is done.
  Future<void> reencryptOnDisk(String key) async {
    final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
    final ReaxDB rekeyed = await db.rekey(
      EncryptionConfig.aes256(key: base64Decode(key)),
    );
    await rekeyed.close();
  }

  /// Opens "vault" and checks the note is there.
  Future<void> expectReadable() async {
    final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
    expect(await db.get<Map<String, dynamic>>('note:1'), {'text': 'Buy milk'});
    await db.close();
  }

  Future<void> expectKeyOpens(String key) async {
    final ReaxDB db = await ReaxDB.open(
      path: await ReaxFlutter.pathFor('vault'),
      encryption: EncryptionConfig.aes256(key: base64Decode(key)),
    );
    await db.close();
  }

  group('rotateKey', () {
    test('changes the key and keeps the data', () async {
      final String oldKey = await createVault();
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);

      final ReaxDB rotated = await ReaxFlutter.rotateKey('vault', db);

      expect(db.isClosed, isTrue);
      expect(rotated.isClosed, isFalse);
      expect(await rotated.get<Map<String, dynamic>>('note:1'), {
        'text': 'Buy milk',
      });
      await rotated.put('note:2', {'text': 'Call mum'});
      await rotated.close();

      final String? newKeyValue = await stored(mainEntry);
      expect(newKeyValue, isNot(oldKey));
      expect(base64Decode(newKeyValue!), hasLength(32));
      expect(await stored(nextEntry), isNull);

      await expectLater(
        expectKeyOpens(oldKey),
        throwsA(isA<EncryptionException>()),
      );
      final ReaxDB reopened = await ReaxFlutter.open('vault', encrypted: true);
      expect(await reopened.get<Map<String, dynamic>>('note:2'), {
        'text': 'Call mum',
      });
    });

    test('keeps the options the database was opened with', () async {
      await createVault();
      final ReaxDB db = await ReaxFlutter.open(
        'vault',
        encrypted: true,
        keepInMemory: true,
      );
      final ReaxDB rotated = await ReaxFlutter.rotateKey('vault', db);
      expect(rotated.keepsInMemory, isTrue);
      expect(rotated.getSync<Map<String, dynamic>>('note:1'), {
        'text': 'Buy milk',
      });
    });

    test('can rotate again', () async {
      await createVault();
      ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      final Set<String?> keys = <String?>{await stored(mainEntry)};
      for (int i = 0; i < 3; i++) {
        db = await ReaxFlutter.rotateKey('vault', db);
        keys.add(await stored(mainEntry));
      }
      expect(keys, hasLength(4));
      await db.close();
      await expectReadable();
    });

    test('rejects a database it cannot rotate, and leaves it open', () async {
      await createVault();
      final ReaxDB plain = await ReaxFlutter.open('plain');
      final ReaxDB vault = await ReaxFlutter.open('vault', encrypted: true);

      await expectLater(
        ReaxFlutter.rotateKey('plain', plain),
        throwsArgumentError,
      );
      await expectLater(
        ReaxFlutter.rotateKey('other', vault),
        throwsArgumentError,
      );
      expect(plain.isClosed, isFalse);
      expect(vault.isClosed, isFalse);

      await vault.close();
      await expectLater(
        ReaxFlutter.rotateKey('vault', vault),
        throwsArgumentError,
      );
      expect(await stored(nextEntry), isNull);
    });

    test('needs the key in the secure storage it is given', () async {
      final String oldKey = await createVault();
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      await storage.delete(key: mainEntry);

      await expectLater(
        ReaxFlutter.rotateKey('vault', db),
        throwsA(isA<EncryptionException>()),
      );
      expect(db.isClosed, isTrue);
      expect(await stored(nextEntry), isNull);
      await expectKeyOpens(oldKey);
    });

    test('an open started during a rotation waits for it', () async {
      await createVault();
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);

      final Future<ReaxDB> rotation = ReaxFlutter.rotateKey('vault', db);
      final Future<Object> opening = ReaxFlutter.open(
        'vault',
        encrypted: true,
      ).then<Object>((ReaxDB db) => db, onError: (Object e) => e);

      final ReaxDB rotated = await rotation;
      // The rotated database is open, so the second open is refused, but
      // never because it used the old key.
      expect(await opening, isA<DatabaseLockedException>());
      await rotated.close();
      await expectReadable();
    });
  });

  // Each test leaves secure storage and the files as a crash at one step
  // of rotateKey would, then checks that open still finds the data.
  group('open after an interrupted rotation', () {
    test('crash after saving the new key, before re-encrypting', () async {
      final String oldKey = await createVault();
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: oldKey,
        nextEntry: newKey(7),
      });

      await expectReadable();
      expect(await stored(mainEntry), oldKey);
      expect(await stored(nextEntry), isNull, reason: 'the unused key goes');
    });

    test('crash after re-encrypting, before replacing the key', () async {
      final String oldKey = await createVault();
      await reencryptOnDisk(newKey(7));
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: oldKey,
        nextEntry: newKey(7),
      });

      await expectReadable();
      expect(await stored(mainEntry), newKey(7), reason: 'promoted');
      expect(await stored(nextEntry), isNull);
      await expectReadable();
    });

    test('crash after replacing the key, before deleting the copy', () async {
      await createVault();
      await reencryptOnDisk(newKey(7));
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: newKey(7),
        nextEntry: newKey(7),
      });

      await expectReadable();
      expect(await stored(mainEntry), newKey(7));
      expect(await stored(nextEntry), isNull);
    });

    test('only the new key is left', () async {
      await createVault();
      await reencryptOnDisk(newKey(7));
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        nextEntry: newKey(7),
      });

      await expectReadable();
      expect(await stored(mainEntry), newKey(7));
      expect(await stored(nextEntry), isNull);
    });

    test('neither key works: the error is about the main key', () async {
      await createVault();
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: newKey(1),
        nextEntry: newKey(2),
      });

      await expectLater(
        ReaxFlutter.open('vault', encrypted: true),
        throwsA(
          isA<EncryptionException>().having(
            (EncryptionException e) => e.message,
            'message',
            contains('Wrong encryption key'),
          ),
        ),
      );
      expect(await stored(mainEntry), newKey(1), reason: 'nothing changes');
      expect(await stored(nextEntry), newKey(2));
    });

    test('a damaged new key does not hide the real error', () async {
      final String oldKey = await createVault();
      await reencryptOnDisk(newKey(7));
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: oldKey,
        nextEntry: 'not base64!',
      });

      await expectLater(
        ReaxFlutter.open('vault', encrypted: true),
        throwsA(
          isA<EncryptionException>().having(
            (EncryptionException e) => e.message,
            'message',
            contains('Wrong encryption key'),
          ),
        ),
      );
    });

    test('if promoting the new key fails, the next open does it', () async {
      final String oldKey = await createVault();
      await reencryptOnDisk(newKey(7));
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        mainEntry: oldKey,
        nextEntry: newKey(7),
      });

      final ReaxDB db = await ReaxFlutter.open(
        'vault',
        encrypted: true,
        secureStorage: FaultyStorage(failWrite: mainEntry),
      );
      expect(await db.get<Map<String, dynamic>>('note:1'), {
        'text': 'Buy milk',
      });
      await db.close();
      expect(await stored(mainEntry), oldKey);
      expect(await stored(nextEntry), newKey(7));

      await expectReadable();
      expect(await stored(mainEntry), newKey(7));
      expect(await stored(nextEntry), isNull);
    });
  });

  // rotateKey itself fails at one step; the app must still open the data.
  group('rotateKey fails at', () {
    Future<void> rotateWith(FlutterSecureStorage faulty, Matcher error) async {
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      await expectLater(
        ReaxFlutter.rotateKey('vault', db, secureStorage: faulty),
        throwsA(error),
      );
      expect(db.isClosed, isTrue);
    }

    test('saving the new key', () async {
      final String oldKey = await createVault();
      await rotateWith(
        FaultyStorage(failWrite: nextEntry),
        isA<PlatformException>(),
      );
      await expectReadable();
      expect(await stored(mainEntry), oldKey);
    });

    test('reading the new key back', () async {
      final String oldKey = await createVault();
      await rotateWith(
        FaultyStorage(wrongReadBack: nextEntry),
        isA<EncryptionException>(),
      );
      await expectReadable();
      expect(await stored(mainEntry), oldKey);
      expect(await stored(nextEntry), isNull);
    });

    test('re-encrypting', () async {
      final String oldKey = await createVault();
      // rekey writes its temporary archive next to the database folder.
      final Directory parent = Directory(
        p.dirname(await ReaxFlutter.pathFor('vault')),
      );
      await Process.run('chmod', <String>['555', parent.path]);
      try {
        await rotateWith(FaultyStorage(), isA<ReaxDbException>());
      } finally {
        await Process.run('chmod', <String>['755', parent.path]);
      }
      expect(await stored(nextEntry), isNotNull);

      await expectReadable();
      expect(await stored(mainEntry), oldKey);
      expect(await stored(nextEntry), isNull);
    }, skip: Platform.isWindows ? 'needs chmod' : false);

    test('replacing the old key', () async {
      final String oldKey = await createVault();
      await rotateWith(
        FaultyStorage(failWrite: mainEntry),
        isA<PlatformException>(),
      );
      // The re-encrypted database was closed too, or this open would find
      // it locked.
      final String? next = await stored(nextEntry);
      expect(await stored(mainEntry), oldKey);
      expect(next, isNot(oldKey));

      await expectReadable();
      expect(await stored(mainEntry), next);
      expect(await stored(nextEntry), isNull);
    });

    test('deleting the copy, which still succeeds', () async {
      await createVault();
      final ReaxDB db = await ReaxFlutter.open('vault', encrypted: true);
      final ReaxDB rotated = await ReaxFlutter.rotateKey(
        'vault',
        db,
        secureStorage: FaultyStorage(failDelete: nextEntry),
      );
      await rotated.close();
      expect(await stored(nextEntry), await stored(mainEntry));

      await expectReadable();
      expect(await stored(nextEntry), isNull);
    });
  });

  test('deleteDatabase also removes the new key of a rotation', () async {
    await createVault();
    await storage.write(key: nextEntry, value: newKey(7));

    await ReaxFlutter.deleteDatabase('vault');

    expect(await stored(mainEntry), isNull);
    expect(await stored(nextEntry), isNull);
  });
}
