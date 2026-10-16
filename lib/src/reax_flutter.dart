import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

/// Opens ReaxDB databases in the right place for a Flutter app.
///
/// Databases live in `<application support>/reaxdb/<name>`. On iOS that
/// directory is not visible to the user in the Files app and is included in
/// device backups; on Android it is the app's private `files` directory.
abstract final class ReaxFlutter {
  /// Name of the folder, inside the application support directory, that
  /// holds every database opened through this class.
  static const String directoryName = 'reaxdb';

  /// Length of the generated AES-256 key, in bytes.
  static const int keyLength = 32;

  /// Secure storage used when none is passed.
  ///
  /// On iOS the key is readable after the first unlock following a restart,
  /// so the database can also be opened by background work (push handlers,
  /// background fetch) while the device is locked.
  static const FlutterSecureStorage defaultSecureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // One encrypted open, key rotation or delete at a time per database, so
  // two concurrent first opens can never generate and save two different
  // keys, and an open never reads the key in the middle of a rotation.
  static final Map<String, Future<void>> _locks = <String, Future<void>>{};

  static final RegExp _validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

  /// Opens (or creates) the database called [name].
  ///
  /// [name] becomes a folder name, so it may contain only letters, digits,
  /// `_`, `-` and `.`, must start with a letter or digit, and is at most 100
  /// characters long.
  ///
  /// When [encrypted] is true the database is encrypted with AES-256-GCM. On
  /// the first open a random 32-byte key is generated, saved in
  /// [secureStorage] and then used; later opens read it back. If the
  /// database already has files on disk but the key is missing, this throws
  /// an [EncryptionException] instead of creating a new key, because a new
  /// key could never read the existing data. That happens, for example,
  /// when Android restores the app's files from a backup but not its
  /// Keystore entries. Call [deleteDatabase] to start over.
  ///
  /// With [keepInMemory] every value is also kept in memory, like a Hive
  /// box: reads and queries never touch the disk, and `db.getSync` reads a
  /// value without a `Future`, for example in a `build` method. Writes are
  /// still saved to disk first. Opening loads everything, so use it for data
  /// that fits comfortably in memory.
  ///
  /// If a [rotateKey] was interrupted (the app was killed, or saving the
  /// key failed), the new key is still in secure storage under a second
  /// entry. When the database does not open with the main key, this tries
  /// that one, and if it works, makes it the main key.
  ///
  /// Pass [secureStorage] to change how the key is stored (for example to
  /// use a Keychain access group). Use the same storage options every time,
  /// or the key will not be found.
  ///
  /// Every other parameter is passed to [ReaxDB.open] unchanged and has the
  /// same default.
  static Future<ReaxDB> open(
    String name, {
    bool encrypted = false,
    FlutterSecureStorage secureStorage = defaultSecureStorage,
    SyncMode syncMode = SyncMode.full,
    int memtableSizeBytes = 4 * 1024 * 1024,
    int cacheMaxEntries = 10000,
    int cacheMaxMemoryBytes = 64 * 1024 * 1024,
    Duration? cacheDefaultTtl,
    int changeStreamBufferSize = 10000,
    bool keepInMemory = false,
    LogLevel logLevel = LogLevel.warning,
    List<LogOutput>? logOutputs,
    String? loggerName,
    IsolationLevel defaultIsolationLevel = IsolationLevel.readCommitted,
    Duration lockTimeout = const Duration(seconds: 10),
    int schemaVersion = 1,
    FutureOr<void> Function(int from, int to, ReaxDB db)? onUpgrade,
  }) async {
    final String path = await pathFor(name);
    Future<ReaxDB> openWith(EncryptionConfig encryption) => ReaxDB.open(
      path: path,
      encryption: encryption,
      syncMode: syncMode,
      memtableSizeBytes: memtableSizeBytes,
      cacheMaxEntries: cacheMaxEntries,
      cacheMaxMemoryBytes: cacheMaxMemoryBytes,
      cacheDefaultTtl: cacheDefaultTtl,
      changeStreamBufferSize: changeStreamBufferSize,
      keepInMemory: keepInMemory,
      logLevel: logLevel,
      logOutputs: logOutputs,
      loggerName: loggerName,
      defaultIsolationLevel: defaultIsolationLevel,
      lockTimeout: lockTimeout,
      schemaVersion: schemaVersion,
      onUpgrade: onUpgrade,
    );

    if (!encrypted) return openWith(const EncryptionConfig.none());
    return _locked(
      name,
      () => _openEncrypted(name, path, secureStorage, openWith),
    );
  }

  /// Replaces the encryption key of the database [name] with a new random
  /// key, and returns the database opened with it.
  ///
  /// [db] must be that database, open and encrypted, as returned by
  /// `open(name, encrypted: true)` with the same [secureStorage]. It is
  /// closed: use the returned instance from then on.
  ///
  /// Every value is encrypted again with the new key (see [ReaxDB.rekey]),
  /// which needs free space for about two copies of the data. The app
  /// never loses access to its data, even if it is killed halfway:
  ///
  /// 1. The new key is saved in a second secure storage entry,
  ///    `reaxdb.<name>.key.next`, and read back.
  /// 2. The database is encrypted again with the new key. A crash leaves it
  ///    readable with the old key or the new one, never a mix.
  /// 3. The new key replaces the old one in the main entry, and the second
  ///    entry is deleted.
  ///
  /// After a crash at any step, [open] finds the key that works.
  ///
  /// Throws an [ArgumentError], without touching [db], if [db] is closed,
  /// is not the database [name], or is not encrypted with AES-256. If
  /// anything else fails, [db] is closed and the database keeps a key that
  /// [open] finds: open it again.
  static Future<ReaxDB> rotateKey(
    String name,
    ReaxDB db, {
    FlutterSecureStorage secureStorage = defaultSecureStorage,
  }) async {
    final String path = await pathFor(name);
    if (db.isClosed) {
      throw ArgumentError.value(db, 'db', 'The database is closed');
    }
    if (db.path != p.canonicalize(path)) {
      throw ArgumentError.value(
        db,
        'db',
        'This is the database at ${db.path}, not "$name" at $path',
      );
    }
    if (db.encryptionInfo['type'] != EncryptionType.aes256.name) {
      throw ArgumentError.value(
        db,
        'db',
        'The database is not encrypted with AES-256. Open it with '
            'ReaxFlutter.open("$name", encrypted: true)',
      );
    }

    final String entry = keyNameFor(name);
    final String nextEntry = _nextKeyNameFor(name);
    return _locked(name, () async {
      ReaxDB current = db;
      try {
        if (await secureStorage.read(key: entry) == null) {
          throw EncryptionException(
            'The encryption key "$entry" of "$name" is not in this secure '
            'storage. Pass the secureStorage the database was opened with.',
          );
        }
        final Uint8List key = _generateKey();
        final String encoded = base64Encode(key);
        await _writeVerified(secureStorage, nextEntry, encoded, name);
        current = await db.rekey(EncryptionConfig.aes256(key: key));
        await _writeVerified(secureStorage, entry, encoded, name);
        // The main entry already holds the new key, so a leftover second
        // entry is harmless: the next open deletes it.
        await _deleteQuietly(secureStorage, nextEntry);
        return current;
      } catch (_) {
        if (!current.isClosed) await current.close();
        rethrow;
      }
    });
  }

  /// The absolute path of the database called [name].
  ///
  /// Useful for backups or for opening the same database with
  /// [ReaxDB.open] directly. Throws an [ArgumentError] if [name] is not a
  /// valid database name (see [open]).
  static Future<String> pathFor(String name) async {
    _checkName(name);
    final Directory support = await getApplicationSupportDirectory();
    return p.join(support.path, directoryName, name);
  }

  /// The secure storage entry that holds the key of the database [name].
  static String keyNameFor(String name) {
    _checkName(name);
    return 'reaxdb.$name.key';
  }

  // Holds the new key while a rotateKey is in progress.
  static String _nextKeyNameFor(String name) => '${keyNameFor(name)}.next';

  /// Deletes the files of the database called [name] and its encryption
  /// key, including the new key of an interrupted [rotateKey].
  ///
  /// Close the database first: deleting the files of an open database
  /// leaves that instance writing to files that no longer exist. Does
  /// nothing for a database that does not exist.
  static Future<void> deleteDatabase(
    String name, {
    FlutterSecureStorage secureStorage = defaultSecureStorage,
  }) async {
    final Directory directory = Directory(await pathFor(name));
    await _locked(name, () async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      await secureStorage.delete(key: keyNameFor(name));
      await secureStorage.delete(key: _nextKeyNameFor(name));
    });
  }

  static void _checkName(String name) {
    if (name.length > 100 || !_validName.hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Use 1 to 100 letters, digits, "_", "-" or ".", starting with a '
            'letter or digit',
      );
    }
  }

  static Future<T> _locked<T>(String name, Future<T> Function() action) {
    final Future<void> previous = _locks[name] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    _locks[name] = done.future;
    return previous.then((_) => action()).whenComplete(() {
      done.complete();
      if (identical(_locks[name], done.future)) _locks.remove(name);
    });
  }

  static Future<ReaxDB> _openEncrypted(
    String name,
    String path,
    FlutterSecureStorage storage,
    Future<ReaxDB> Function(EncryptionConfig encryption) openWith,
  ) async {
    final String entry = keyNameFor(name);
    final String nextEntry = _nextKeyNameFor(name);
    final String? stored = await storage.read(key: entry);
    final String? next = await storage.read(key: nextEntry);

    if (stored == null) {
      if (next != null) {
        // Not left by rotateKey, which never removes the main key, but the
        // second entry is still the only key there is.
        final ReaxDB db = await openWith(
          EncryptionConfig.aes256(key: _decodeKey(name, next)),
        );
        await _promote(storage, entry, nextEntry, next, name);
        return db;
      }
      return openWith(
        EncryptionConfig.aes256(
          key: await _createKey(name, entry, path, storage),
        ),
      );
    }

    final ReaxDB db;
    try {
      db = await openWith(
        EncryptionConfig.aes256(key: _decodeKey(name, stored)),
      );
    } on EncryptionException catch (error, stack) {
      if (next == null) rethrow;
      // A rotateKey was interrupted after the database was encrypted again
      // with the new key, but before that key replaced the old one.
      final ReaxDB rotated;
      try {
        rotated = await openWith(
          EncryptionConfig.aes256(key: _decodeKey(name, next)),
        );
      } on ReaxDbException {
        Error.throwWithStackTrace(error, stack);
      }
      await _promote(storage, entry, nextEntry, next, name);
      return rotated;
    }
    // The main key opened the database, so a rotation never got as far as
    // encrypting it again, or it finished: the second entry is not needed.
    if (next != null) await _deleteQuietly(storage, nextEntry);
    return db;
  }

  /// Makes the key in [nextEntry] the main key. The database is already open
  /// with it, so a failure here only means the next open does this again.
  static Future<void> _promote(
    FlutterSecureStorage storage,
    String entry,
    String nextEntry,
    String encoded,
    String name,
  ) async {
    try {
      await _writeVerified(storage, entry, encoded, name);
    } on Exception {
      return;
    }
    await _deleteQuietly(storage, nextEntry);
  }

  static Future<void> _deleteQuietly(
    FlutterSecureStorage storage,
    String entry,
  ) async {
    try {
      await storage.delete(key: entry);
    } on Exception {
      // A stale entry is harmless; the next open deletes it.
    }
  }

  static Future<Uint8List> _createKey(
    String name,
    String entry,
    String path,
    FlutterSecureStorage storage,
  ) async {
    if (await _hasFiles(path)) {
      throw EncryptionException(
        'The database "$name" already has files at $path, but its '
        'encryption key "$entry" is not in secure storage. The key may have '
        'been deleted, or the database may have been created without '
        'encryption. A new key cannot read the existing data. Restore the '
        'key, open the database without encryption if it was created that '
        'way, or call ReaxFlutter.deleteDatabase("$name") to start over.',
      );
    }
    final Uint8List key = _generateKey();
    // Never create the database with a key the platform did not keep.
    await _writeVerified(storage, entry, base64Encode(key), name);
    return key;
  }

  static Uint8List _generateKey() {
    final Random random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(keyLength, (_) => random.nextInt(256)),
    );
  }

  static Future<void> _writeVerified(
    FlutterSecureStorage storage,
    String entry,
    String encoded,
    String name,
  ) async {
    await storage.write(key: entry, value: encoded);
    if (await storage.read(key: entry) != encoded) {
      throw EncryptionException(
        'Could not save the encryption key of "$name" in secure storage.',
      );
    }
  }

  static Uint8List _decodeKey(String name, String stored) {
    final Uint8List key;
    try {
      key = base64Decode(stored);
    } on FormatException catch (error) {
      throw EncryptionException(
        'The encryption key of "$name" in secure storage is not valid base64.',
        cause: error,
      );
    }
    if (key.length != keyLength) {
      throw EncryptionException(
        'The encryption key of "$name" in secure storage is ${key.length} '
        'bytes long; expected $keyLength.',
      );
    }
    return key;
  }

  static Future<bool> _hasFiles(String path) async {
    final Directory directory = Directory(path);
    if (!await directory.exists()) return false;
    return !(await directory.list().isEmpty);
  }
}
