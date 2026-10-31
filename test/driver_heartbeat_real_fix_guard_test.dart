import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner report 2026-10-31: drivers jumped around on the dispatch map. The
/// 5 s and 30 s heartbeats uploaded `_pos` — the DRAWN arrow (smoothed,
/// projected ahead, road-snapped, frozen when the map leaves the screen) —
/// with no captured_at, and the near-pickup/near-dropoff hooks uploaded the
/// pickup/dropoff coordinates themselves.
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();

  test('heartbeats upload the last real GPS fix with its own time', () {
    expect(screen, contains('Position? _lastRawFix;'));
    expect(ctrl, contains('_lastRawFix = pos;'));
    expect('final fix = _lastRawFix;'.allMatches(ctrl).length, 2,
        reason: 'the 5 s poll and the 30 s background heartbeat');
    expect('capturedAt: fix?.timestamp.toUtc(),'.allMatches(ctrl).length, 2);
  });

  test('the pickup/dropoff coordinates are never sent as the driver', () {
    expect(ctrl, isNot(contains('lat: _pickupLL.latitude')));
    expect(ctrl, isNot(contains('lat: _dropoffLL.latitude')));
  });
}
