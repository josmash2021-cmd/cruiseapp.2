import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'firebase_auth_recovery.dart';
import 'notification_service.dart';

/// Live refresh for the scheduled-ride board (owner spec 2026-10-30: "cuando
/// alguien haga una reserva se actualiza al instante en la página de
/// scheduled rides y el botón de scheduled").
///
/// The backend bumps `config/scheduled_board.version` whenever an open
/// reservation appears or leaves the board (backend/services/
/// scheduled_board.py). Every bump fires
/// [NotificationService.scheduledRideRefreshNotifier] — the same signal the
/// FCM `scheduled_ride` push fires — so the GO-side badge, the online
/// sheet's badge and both scheduled pages refetch without new wiring.
///
/// Ref-counted: each screen that shows the board calls [acquire] in
/// initState and [release] in dispose; the listener lives while at least one
/// does. FCM stays the wake-up for a closed app; the polls stay as the floor.
class ScheduledBoardWatcher {
  ScheduledBoardWatcher._();

  static int _holders = 0;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  static StreamSubscription<User?>? _authSub;
  static Object? _lastVersion;
  static bool _primed = false;

  static void acquire() {
    if (kIsWeb) return;
    _holders++;
    if (_holders == 1) unawaited(_start());
  }

  static void release() {
    if (kIsWeb || _holders == 0) return;
    _holders--;
    if (_holders == 0) _stop();
  }

  static Future<void> _start() async {
    if (!FirebaseAuthRecovery.hasSession) {
      final ok = await FirebaseAuthRecovery.ensureSignedIn();
      if (_holders == 0) return;
      if (!ok) {
        // Same rule as the rider's service-zones listener: `false` can just
        // mean another caller is mid-recovery — wait for a session rather
        // than give up on live updates for the whole shift.
        _authSub?.cancel();
        _authSub = FirebaseAuth.instance.authStateChanges().listen((u) {
          if (u == null || _holders == 0) return;
          _authSub?.cancel();
          _authSub = null;
          _listen();
        });
        return;
      }
    }
    _listen();
  }

  static void _listen() {
    _sub?.cancel();
    _primed = false;
    _sub = FirebaseFirestore.instance
        .collection('config')
        .doc('scheduled_board')
        .snapshots()
        .listen((snap) {
      final v = snap.data()?['version'];
      // The first snapshot is the starting point, not a change — refetching
      // on it would double the load every screen already does on open.
      if (_primed && v != _lastVersion) {
        NotificationService.scheduledRideRefreshNotifier.value++;
      }
      _primed = true;
      _lastVersion = v;
    }, onError: (Object e) {
      // A Firestore listen is terminal once it errors. Drop the handle —
      // the polls keep the board fresh, so this never retries in a loop.
      debugPrint('[ScheduledBoard] listen failed: $e');
      _sub?.cancel();
      _sub = null;
    });
  }

  static void _stop() {
    _authSub?.cancel();
    _authSub = null;
    _sub?.cancel();
    _sub = null;
    _primed = false;
  }
}
