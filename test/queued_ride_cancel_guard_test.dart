// The ride queued behind the current one is cancelled (owner design
// 2026-11-02, drawing 15): the deeper two-note cue from the backend, at
// once, and "Viaje en cola cancelado" for 7 s. The current trip goes on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final cue = File('lib/services/queued_cancel_cue.dart').readAsStringSync();

  test('the queued ride is watched from the moment it is booked', () {
    expect(trip.contains('ChainedRideStore.set(offer);\n      _watchQueuedRide();'),
        isTrue);
    expect(trip.contains(".doc('sql_\$id')"), isTrue);
    expect(trip.contains('_queuedSub?.cancel();'), isTrue);
  });

  test('a stale "requested" right after the accept is not a cancel', () {
    expect(trip.contains('(_queuedSeenOurs &&'), isTrue);
  });

  test('the cue sounds, the store clears, the line stays 7 s', () {
    expect(trip.contains('unawaited(QueuedCancelCue.play());'), isTrue);
    expect(trip.contains('if (queued == id) ChainedRideStore.clear();'), isTrue);
    expect(trip.contains('Timer(const Duration(seconds: 7)'), isTrue);
    expect(trip.contains('queuedCanceled: _queuedCanceledShown,'), isTrue);
  });

  test('the cue comes from the backend, cached before it is needed', () {
    expect(cue.contains('/static/queued_cancel.wav'), isTrue);
    expect(File('backend/static/queued_cancel.wav').existsSync(), isTrue);
    expect(trip.contains('unawaited(QueuedCancelCue.warm());'), isTrue);
  });
}
