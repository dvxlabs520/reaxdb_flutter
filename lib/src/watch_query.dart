import 'dart:async';

import 'package:collection/collection.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';

/// Live queries for ReaxDB.
extension ReaxWatchQuery on ReaxDB {
  /// Runs [query] now and again after every change to its collection.
  ///
  /// The stream emits the first result right away. When a document of the
  /// collection is written or deleted, it waits [debounce] and then runs the
  /// query once for every change made in that window, so a burst of writes
  /// costs one query and not one per write. The wait starts at the first
  /// change and is not extended by later ones, so a steady flow of writes
  /// still produces regular updates.
  ///
  /// When [distinct] is true (the default) a result equal to the previous
  /// one is not emitted, so changes to documents outside the filter do not
  /// rebuild the widget.
  ///
  /// Query errors are emitted as stream errors and the stream keeps going.
  /// The stream closes when the database is closed. While the subscription
  /// is paused the query does not run; it runs once on resume if anything
  /// changed.
  ///
  /// Each call returns a new single-subscription stream. In a widget, create
  /// it once (for example in `initState`) instead of in `build`, or every
  /// rebuild will start a new subscription and run the query again.
  ///
  /// [query] must come from this database (`db.query('collection')`). Its
  /// conditions are read every time it runs, so do not change the builder
  /// after passing it here.
  Stream<List<Map<String, dynamic>>> watchQuery(
    QueryBuilder query, {
    Duration debounce = const Duration(milliseconds: 50),
    bool distinct = true,
  }) {
    return watchResults<List<Map<String, dynamic>>>(
      changes: () => watchCollection(query.collection),
      run: query.find,
      debounce: debounce,
      distinct: distinct,
    );
  }
}

const DeepCollectionEquality _equality = DeepCollectionEquality();

/// The engine behind [ReaxWatchQuery.watchQuery], separated from ReaxDB so
/// it can be tested with fake change streams.
///
/// [changes] is called when the stream is listened to, and again if the
/// change stream ends with a [ChangeStreamOverflowException]; any other end
/// of [changes] closes the result stream. Not exported by the package.
Stream<T> watchResults<T>({
  required Stream<Object?> Function() changes,
  required Future<T> Function() run,
  required Duration debounce,
  required bool distinct,
}) {
  late final StreamController<T> controller;
  StreamSubscription<Object?>? subscription;
  Timer? timer;
  bool running = false;
  bool dirty = false;
  bool paused = false;
  bool done = false;
  bool hasLast = false;
  T? last;

  void finish() {
    if (done) return;
    done = true;
    timer?.cancel();
    timer = null;
    unawaited(controller.close());
  }

  late final void Function() schedule;

  Future<void> execute() async {
    if (done) return;
    running = true;
    dirty = false;
    try {
      final T result = await run();
      if (!done && !(distinct && hasLast && _equality.equals(last, result))) {
        last = result;
        hasLast = true;
        controller.add(result);
      }
    } on DatabaseClosedException {
      // The database closed while the query ran. The change stream ends too
      // and closes this stream.
    } catch (error, stackTrace) {
      if (!done) controller.addError(error, stackTrace);
    } finally {
      running = false;
    }
    if (dirty) schedule();
  }

  schedule = () {
    if (done) return;
    if (running || paused) {
      dirty = true;
      return;
    }
    timer ??= Timer(debounce, () {
      timer = null;
      unawaited(execute());
    });
  };

  void subscribe() {
    late final StreamSubscription<Object?> current;
    current = changes().listen(
      (_) => schedule(),
      onError: (Object error, StackTrace stackTrace) {
        if (error is ChangeStreamOverflowException) {
          // Events were dropped. Listen again and run the query, which
          // catches up with everything that was missed.
          subscription = null;
          try {
            subscribe();
          } catch (error, stackTrace) {
            if (!done) controller.addError(error, stackTrace);
            finish();
            return;
          }
          schedule();
          return;
        }
        if (!done) controller.addError(error, stackTrace);
      },
      onDone: () {
        if (identical(subscription, current)) finish();
      },
    );
    subscription = current;
  }

  controller = StreamController<T>(
    onListen: () {
      try {
        subscribe();
      } catch (error, stackTrace) {
        // For example a DatabaseClosedException from a closed database.
        controller.addError(error, stackTrace);
        finish();
        return;
      }
      unawaited(execute());
    },
    onPause: () {
      paused = true;
      if (timer != null) {
        timer!.cancel();
        timer = null;
        dirty = true;
      }
    },
    onResume: () {
      paused = false;
      if (dirty) schedule();
    },
    onCancel: () {
      done = true;
      timer?.cancel();
      timer = null;
      final StreamSubscription<Object?>? current = subscription;
      subscription = null;
      return current?.cancel();
    },
  );
  return controller.stream;
}
