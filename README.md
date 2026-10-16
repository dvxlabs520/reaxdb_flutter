# reaxdb_flutter

Flutter helpers for [ReaxDB](https://pub.dev/packages/reaxdb_dart), an
embedded NoSQL database written in pure Dart. The database itself is the
`reaxdb_dart` package; this one adds what a Flutter app needs on top.

This package does three things:

- **Puts the database in the right folder.** `ReaxFlutter.open('notes')`
  stores it in the app support directory. You never pass a path, so you
  never pass a relative one by mistake (relative paths fail on iOS and
  Android).
- **Keeps the encryption key safe.** With `encrypted: true`, a random
  256-bit key is created on the first launch and saved in the Keychain
  (iOS, macOS) or the Keystore (Android). Later launches read it back.
- **Turns a query into a stream.** `db.watchQuery(query)` runs the query
  again when its collection changes, so a `StreamBuilder` always shows
  current data.

## Install

```bash
flutter pub add reaxdb_flutter
```

This package exports all of `reaxdb_dart`, so one import is enough:

```dart
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
```

It supports Android, iOS, macOS, Windows and Linux. It does not support the
web, because ReaxDB writes files with `dart:io`. It needs Flutter 3.44 or
newer.

## Open a database

```dart
final ReaxDB db = await ReaxFlutter.open('notes');
```

The files go to `<app support directory>/reaxdb/notes`. The name may contain
letters, digits, `_`, `-` and `.`, and must start with a letter or digit.

Every option of `ReaxDB.open` is available, with the same defaults:

```dart
final ReaxDB db = await ReaxFlutter.open(
  'notes',
  syncMode: SyncMode.full,
  schemaVersion: 2,
  onUpgrade: (from, to, db) async {
    // Migrate your documents here.
  },
);
```

If you need the path itself, for example for a backup, use
`await ReaxFlutter.pathFor('notes')`.

## Encrypt it

```dart
final ReaxDB db = await ReaxFlutter.open('notes', encrypted: true);
```

What happens:

1. On the first open, a random 32-byte key is created with
   `Random.secure()`.
2. The key is saved in secure storage under `reaxdb.notes.key` and read
   back to make sure it was kept.
3. The database is opened with `EncryptionConfig.aes256(key: key)`
   (AES-256-GCM).

The key never leaves the device's secure storage, except in memory while
the database is open. There is no passphrase, so there is no slow key
derivation at startup.

### When the key is missing

If the database already has files but its key is gone, `open` throws an
`EncryptionException`. It does not create a new key, because a new key can
never read the old data. This can happen when:

- Android restores the app's files from a backup. The key cannot come
  back with them, because the Keystore is never part of a backup.
- The user or your code deleted the key.
- The database was first created without `encrypted: true`.

To avoid the Android case, exclude the `reaxdb` folder from Auto Backup, or
turn Auto Backup off. To start over, call:

```dart
await ReaxFlutter.deleteDatabase('notes');
```

This deletes the files and the key. Close the database first.

### Storage options

By default the key is readable after the device has been unlocked once
since it started. That lets background work (push handlers, background
fetch) open the database while the phone is locked. To change this, pass
your own `FlutterSecureStorage`:

```dart
const storage = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked),
);
final db = await ReaxFlutter.open(
  'notes',
  encrypted: true,
  secureStorage: storage,
);
```

Use the same storage every time you open that database, or the key will
not be found. `FlutterSecureStorage` and its option types are exported by
this package, so you do not need another import.

On macOS, secure storage needs the Keychain Sharing capability. See the
[flutter_secure_storage setup notes](https://pub.dev/packages/flutter_secure_storage).
On Linux it needs `libsecret`.

## Keep everything in memory

For data that fits in memory and is read far more than it is written,
keep every value in memory, like a Hive box:

```dart
final db = await ReaxFlutter.open('settings', keepInMemory: true);

// In a build method, no FutureBuilder needed:
final theme = db.getSync<String>('theme') ?? 'light';
```

Reads and queries then never touch the disk. Writes are still saved to disk
first, so nothing is lost if the app is killed. Opening takes longer,
because it loads everything.

## Watch a query

```dart
class NotesList extends StatefulWidget {
  const NotesList({super.key, required this.db});

  final ReaxDB db;

  @override
  State<NotesList> createState() => _NotesListState();
}

class _NotesListState extends State<NotesList> {
  late final Stream<List<Map<String, dynamic>>> _notes;

  @override
  void initState() {
    super.initState();
    _notes = widget.db.watchQuery(
      widget.db.query('notes').orderBy('createdAt', descending: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _notes,
      builder: (context, snapshot) {
        final notes = snapshot.data;
        if (notes == null) return const CircularProgressIndicator();
        return ListView(
          children: [for (final note in notes) Text(note['text'] as String)],
        );
      },
    );
  }
}
```

Documents of a collection are stored under `collection:id` keys, for
example `await db.put('notes:1', {'text': 'Buy milk'})`.

How the stream behaves:

- It emits the current result as soon as you listen.
- After a change to the collection it waits 50 ms, then runs the query
  once for all the changes made in that time. A burst of 100 writes costs
  one query, not 100. Change the wait with `debounce:`.
- It skips a result that is equal to the previous one, so writes that do
  not affect the result do not rebuild your widget. Pass `distinct: false`
  to get every result.
- A query error arrives as a stream error, and the stream keeps going.
- It closes when the database is closed.

Create the stream once, in `initState`, and not in `build`. Each call to
`watchQuery` starts a new subscription and runs the query again.

## Example

The [example](example) folder has a small notes app: an encrypted database,
a list that updates itself, filters, and swipe to delete.

## Working on this package

`reaxdb_dart` lives in its own repository,
[Reax-BD](https://github.com/dvxlabs520/Reax-BD). To test changes to both at
once, clone it next to this folder and add a `pubspec_overrides.yaml` here
(it is ignored by git):

```yaml
dependency_overrides:
  reaxdb_dart:
    path: ../Reax-BD
```

Do the same in `example/` with `path: ../../Reax-BD`.

## License

MIT. See [LICENSE](LICENSE).
