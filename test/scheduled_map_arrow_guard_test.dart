import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: "la flecha en esta página debe moverse bien, no ser
/// estática" — the reservations map's arrow follows the live GPS, glided by
/// SmoothMotion and turned by the car's own course.
void main() {
  final src = File('lib/screens/driver/scheduled_rides_map_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('live fixes on the shared driver GPS channel', () {
    expect(src, contains('_gps = ResilientPositionStream('));
    expect(src, contains('settings: driverLocationSettings('),
        reason: 'one Android GPS channel for every driver screen (rule 33)');
    expect(src, contains('bearing: measuredCourseDeg(pos),'),
        reason: 'Android 0/0 is "not measured" (rule 32); no compass (41)');
    expect(src, contains('speedMps: measuredSpeedMps(pos),'));
    expect(src, contains('unawaited(_gps?.stop());'));
  });

  test('the dot glides and turns on the map, the last step always lands', () {
    expect(src, contains('await _driverDot.build(this, _onDotTick);'));
    expect(src, isNot(contains('await _driverDot.build(this, () {});')));
    expect(src, contains('annot.iconRotate = _driverDot.bearing;'));
    expect(src, contains("mgr.id, 'icon-rotation-alignment', 'map');"));
    expect(src, contains('_dotWriteAgain = true;'),
        reason: 'a write over one in flight is queued, not dropped (rule 25)');
  });
}
