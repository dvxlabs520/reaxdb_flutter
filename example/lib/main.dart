import 'package:flutter/material.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';

/// Name of the example database, stored in the app support directory.
const String databaseName = 'notes';

void main() {
  runApp(const NotesApp());
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key, this.openDatabase = _openEncrypted});

  /// How the app opens its database. Tests replace it.
  final Future<ReaxDB> Function() openDatabase;

  static Future<ReaxDB> _openEncrypted() =>
      ReaxFlutter.open(databaseName, encrypted: true);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReaxDB notes',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2F5D50)),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F5D50),
        brightness: Brightness.dark,
      ),
      home: NotesPage(openDatabase: openDatabase),
    );
  }
}

enum NoteFilter { all, open, done }

class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.openDatabase});

  final Future<ReaxDB> Function() openDatabase;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final TextEditingController _input = TextEditingController();
  ReaxDB? _db;
  Object? _openError;
  NoteFilter _filter = NoteFilter.all;
  Stream<List<Map<String, dynamic>>>? _notes;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _input.dispose();
    _db?.close();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final ReaxDB db = await widget.openDatabase();
      if (!mounted) {
        await db.close();
        return;
      }
      setState(() {
        _db = db;
        _notes = _watch(db, _filter);
      });
    } catch (error) {
      if (mounted) setState(() => _openError = error);
    }
  }

  // The stream is created here, once per filter, and not in build.
  Stream<List<Map<String, dynamic>>> _watch(ReaxDB db, NoteFilter filter) {
    final QueryBuilder query = db
        .query('notes')
        .orderBy('createdAt', descending: true);
    switch (filter) {
      case NoteFilter.all:
        break;
      case NoteFilter.open:
        query.whereEquals('done', false);
      case NoteFilter.done:
        query.whereEquals('done', true);
    }
    return db.watchQuery(query);
  }

  void _setFilter(NoteFilter filter) {
    final ReaxDB? db = _db;
    if (db == null) return;
    setState(() {
      _filter = filter;
      _notes = _watch(db, filter);
    });
  }

  Future<void> _add() async {
    final String text = _input.text.trim();
    final ReaxDB? db = _db;
    if (text.isEmpty || db == null) return;
    final int now = DateTime.now().microsecondsSinceEpoch;
    final String id = '$now';
    await db.put('notes:$id', <String, dynamic>{
      'id': id,
      'text': text,
      'done': false,
      'createdAt': now,
    });
    _input.clear();
  }

  Future<void> _toggle(Map<String, dynamic> note) => _db!.put(
    'notes:${note['id']}',
    <String, dynamic>{...note, 'done': !(note['done'] as bool)},
  );

  Future<void> _delete(Map<String, dynamic> note) =>
      _db!.delete('notes:${note['id']}');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_openError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not open the database.\n\n$_openError'),
        ),
      );
    }
    if (_db == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('note-input'),
                  controller: _input,
                  decoration: const InputDecoration(
                    hintText: 'Write a note',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('add-note'),
                tooltip: 'Add note',
                onPressed: _add,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<NoteFilter>(
            segments: const <ButtonSegment<NoteFilter>>[
              ButtonSegment(value: NoteFilter.all, label: Text('All')),
              ButtonSegment(value: NoteFilter.open, label: Text('Open')),
              ButtonSegment(value: NoteFilter.done, label: Text('Done')),
            ],
            selected: <NoteFilter>{_filter},
            onSelectionChanged: (Set<NoteFilter> s) => _setFilter(s.single),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _notes,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              final List<Map<String, dynamic>>? notes = snapshot.data;
              if (notes == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (notes.isEmpty) {
                return const Center(child: Text('No notes here yet.'));
              }
              return ListView.builder(
                itemCount: notes.length,
                itemBuilder: (context, index) => _tile(notes[index]),
              );
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Stored encrypted in the app support folder. '
            'The key lives in the Keychain or Keystore.',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _tile(Map<String, dynamic> note) {
    final bool done = note['done'] as bool;
    return Dismissible(
      key: ValueKey<String>(note['id'] as String),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: const Icon(Icons.delete_outline),
      ),
      onDismissed: (_) => _delete(note),
      child: CheckboxListTile(
        value: done,
        onChanged: (_) => _toggle(note),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          note['text'] as String,
          style: done
              ? const TextStyle(decoration: TextDecoration.lineThrough)
              : null,
        ),
      ),
    );
  }
}
