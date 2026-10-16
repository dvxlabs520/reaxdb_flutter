## 0.2.0

- `ReaxFlutter.open(name, keepInMemory: true)` keeps every value in memory,
  like a Hive box. Reads and queries skip the disk, and `db.getSync` reads a
  value without a `Future`. Writes are saved to disk first, as before.
- Needs `reaxdb_dart` 2.5.0, which also brings writes that no longer stall
  on maintenance and `rekey` / `changePassphrase`.

## 0.1.0

First release.

- `ReaxFlutter.open(name)` opens a database in the app support directory.
- `encrypted: true` creates a random AES-256 key on the first launch, keeps
  it in the Keychain or Keystore, and refuses to replace a missing key when
  the database already has files.
- `ReaxFlutter.deleteDatabase(name)` removes the files and the key.
- `ReaxFlutter.pathFor(name)` and `ReaxFlutter.keyNameFor(name)`.
- `db.watchQuery(query)` re-runs a query after changes to its collection,
  with a debounce and without repeating equal results.
- Needs `reaxdb_dart` 2.1.0 and Flutter 3.44 or newer.
