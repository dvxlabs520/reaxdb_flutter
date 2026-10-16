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

  // One key load or creation at a time per secure storage entry, so two
  // concurrent first opens can never generate and save two different keys.
  static final Map<String, Future<Uint8List>> _pendingKeys =
      <String, Future<Uint8List>>{};

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
    LogLevel logLevel = LogLevel.warning,
    List<LogOutput>? logOutputs,
    String? loggerName,
    IsolationLevel defaultIsolationLevel = IsolationLevel.readCommitted,
    Duration lockTimeout = const Duration(seconds: 10),
    int schemaVersion = 1,
    FutureOr<void> Function(int from, int to, ReaxDB db)? onUpgrade,
  }) async {
    final String path = await pathFor(name);
    EncryptionConfig encryption = const EncryptionConfig.none();
    if (encrypted) {
      final Uint8List key = await _loadOrCreateKey(name, path, secureStorage);
      encryption = EncryptionConfig.aes256(key: key);
    }
    return ReaxDB.open(
      path: path,
      encryption: encryption,
      syncMode: syncMode,
      memtableSizeBytes: memtableSizeBytes,
      cacheMaxEntries: cacheMaxEntries,
      cacheMaxMemoryBytes: cacheMaxMemoryBytes,
      cacheDefaultTtl: cacheDefaultTtl,
      changeStreamBufferSize: changeStreamBufferSize,
      logLevel: logLevel,
      logOutputs: logOutputs,
      loggerName: loggerName,
      defaultIsolationLevel: defaultIsolationLevel,
      lockTimeout: lockTimeout,
      schemaVersion: schemaVersion,
      onUpgrade: onUpgrade,
    );
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

  /// Deletes the files of the database called [name] and its encryption key.
  ///
  /// Close the database first: deleting the files of an open database
  /// leaves that instance writing to files that no longer exist. Does
  /// nothing for a database that does not exist.
  static Future<void> deleteDatabase(
    String name, {
    FlutterSecureStorage secureStorage = defaultSecureStorage,
  }) async {
    final Directory directory = Directory(await pathFor(name));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await secureStorage.delete(key: keyNameFor(name));
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

  static Future<Uint8List> _loadOrCreateKey(
    String name,
    String path,
    FlutterSecureStorage storage,
  ) {
    final String entry = keyNameFor(name);
    final Future<Uint8List>? pending = _pendingKeys[entry];
    if (pending != null) return pending;
    final Future<Uint8List> load =
        _loadOrCreateKeyNow(name, entry, path, storage).whenComplete(() {
          // A block body: returning the removed future would make whenComplete
          // wait for itself.
          _pendingKeys.remove(entry);
        });
    _pendingKeys[entry] = load;
    return load;
  }

  static Future<Uint8List> _loadOrCreateKeyNow(
    String name,
    String entry,
    String path,
    FlutterSecureStorage storage,
  ) async {
    final String? stored = await storage.read(key: entry);
    if (stored != null) return _decodeKey(name, stored);

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

    final Random random = Random.secure();
    final Uint8List key = Uint8List.fromList(
      List<int>.generate(keyLength, (_) => random.nextInt(256)),
    );
    final String encoded = base64Encode(key);
    await storage.write(key: entry, value: encoded);
    // Never create the database with a key the platform did not keep.
    if (await storage.read(key: entry) != encoded) {
      throw EncryptionException(
        'Could not save the encryption key of "$name" in secure storage.',
      );
    }
    return key;
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
