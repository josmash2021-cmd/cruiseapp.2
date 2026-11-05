import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../map/rider_heat.dart';
import 'api_service.dart';
import 'firebase_auth_recovery.dart';

/// Live heat cells for the driver's map (owner 2026-11-05: "eso es en
/// tiempo real"). The backend leader rewrites `config/rider_heat` whenever
/// the cells change (backend/services/rider_heat.py); this listens to it.
/// If the listen dies (Firestore drops a listener on its first error) it
/// falls back to polling `GET /zones/heat` every 30 s.
///
/// Ref-counted like [ScheduledBoardWatcher]: the screen that shows the map
/// calls [acquire] / [release].
class RiderHeatWatcher {
  RiderHeatWatcher._();

  static final ValueNotifier<List<HeatCell>> cells =
      ValueNotifier<List<HeatCell>>(const []);

  static const Duration _pollEvery = Duration(seconds: 30);

  static int _holders = 0;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  static StreamSubscription<User?>? _authSub;
  static Timer? _poll;

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
        // Same as the board watcher: `false` can mean another caller is
        // mid-recovery. Poll meanwhile, listen once a session lands.
        _startPolling();
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
    _sub = FirebaseFirestore.instance
        .collection('config')
        .doc('rider_heat')
        .snapshots()
        .listen((snap) {
      _poll?.cancel();
      _poll = null;
      _set(HeatCell.listFrom(snap.data()?['cells']));
    }, onError: (Object e) {
      debugPrint('[RiderHeat] listen failed: $e');
      _sub?.cancel();
      _sub = null;
      _startPolling();
    });
  }

  static void _startPolling() {
    if (_poll != null || _holders == 0) return;
    unawaited(_pollOnce());
    _poll = Timer.periodic(_pollEvery, (_) => unawaited(_pollOnce()));
  }

  static Future<void> _pollOnce() async {
    final raw = await ApiService.getRiderHeat();
    if (_holders == 0 || raw == null) return;
    _set(HeatCell.listFrom(raw));
  }

  static void _set(List<HeatCell> next) {
    final cur = cells.value;
    if (cur.length == next.length) {
      var same = true;
      for (var i = 0; i < cur.length && same; i++) {
        same = cur[i].key == next[i].key && cur[i].w == next[i].w;
      }
      if (same) return;
    }
    cells.value = next;
  }

  static void _stop() {
    _authSub?.cancel();
    _authSub = null;
    _sub?.cancel();
    _sub = null;
    _poll?.cancel();
    _poll = null;
  }
}
