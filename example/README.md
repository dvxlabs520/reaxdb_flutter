# reaxdb_flutter example

A small notes app. It opens an encrypted ReaxDB database with
`ReaxFlutter.open('notes', encrypted: true)` and shows the notes with a
`StreamBuilder` over `db.watchQuery(...)`. Add, check and swipe away notes,
and the list updates by itself.

```bash
flutter run
```

To run the end-to-end test on a simulator or device, with the real
Keychain or Keystore:

```bash
flutter test integration_test
```
