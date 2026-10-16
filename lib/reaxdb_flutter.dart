/// Flutter companion for ReaxDB.
///
/// - [ReaxFlutter.open] stores the database in the app support directory,
///   so apps never pass a relative path (which fails on iOS and Android).
/// - With `encrypted: true` the AES-256 key is generated on first launch and
///   kept in the Keychain (iOS, macOS) or the Keystore (Android).
/// - [ReaxWatchQuery.watchQuery] turns a query into a stream that runs again
///   whenever its collection changes, ready for a `StreamBuilder`.
///
/// This library also exports the whole `reaxdb_dart` API, so one import is
/// enough.
library;

export 'package:reaxdb_dart/reaxdb_dart.dart';

// The types needed to pass custom secure storage to ReaxFlutter.open.
export 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show
        AndroidOptions,
        FlutterSecureStorage,
        IOSOptions,
        KeychainAccessibility,
        LinuxOptions,
        MacOsOptions,
        WindowsOptions;

export 'src/reax_flutter.dart' show ReaxFlutter;
export 'src/watch_query.dart' show ReaxWatchQuery;
