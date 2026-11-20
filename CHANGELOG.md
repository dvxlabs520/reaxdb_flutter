## 0.3.0

- `ReaxFlutter.rotateKey(name, db)` replaces the AES-256 key of an
  encrypted database with a new random one and returns the database opened
  with it. The new key is saved under a second entry,
  `reaxdb.<name>.key.next`, before the data is encrypted again, and only
  replaces the old key afterwards, so a crash or a secure storage error at
  any step never locks the app out of its data.
- `ReaxFlutter.open(name, encrypted: true)` finishes an interrupted
  rotation: when the main key does not open the database and the second
  entry does, it makes that key the main one. A leftover second entry that
  is not needed is deleted.
- `ReaxFlutter.deleteDatabase` also removes the second entry.
- Encrypted opens, rotations and deletes of the same database now run one
  at a time.
- The example app imports `package:material_ui`, which replaces
  `package:flutter/material.dart` from Flutter 3.50.

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
