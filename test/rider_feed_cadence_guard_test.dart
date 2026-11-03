import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: "el rider debe de ver el carrito fluido moviéndose, no
/// paso a paso o salto en salto". The rider's car glides with SmoothMotion
/// every frame, but between readings it can only guess: when the socket
/// relay does not reach the rider, the RTDB feed is all they get — and one
/// reading every 5 s drew a car that glided, stopped and jumped.
void main() {
  final gps = File('lib/services/gps_service.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('on an active trip the rider feed is written every second', () {
    expect(gps, contains(
        'static const Duration _rtdbTripInterval = Duration(seconds: 1);'));
    expect(gps, contains(
        '_activeTripId != null ? _rtdbTripInterval : _rtdbInterval;'));
    expect(gps, contains('now.difference(_lastRTDBAt!) >= _rtdbEvery'),
        reason: 'the per-fix upload uses the trip cadence');
  });

  test('a car crawling in traffic is not held back as "parked"', () {
    expect(gps, contains('final parkedM = _activeTripId != null ? 1.5 : 5.0;'));
  });

  test('the secondary fleet copy keeps its 5 s cadence', () {
    expect(gps, contains('now.difference(_lastDriversNodeAt!) >= _rtdbInterval'));
  });
}
