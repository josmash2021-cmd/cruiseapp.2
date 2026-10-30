import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Repo-wide guard for CLAUDE.md rules #32 / #33 / #37 (2026-10-29/30).
/// Fails the moment someone reintroduces a cause of "la flecha no sigue al
/// conductor / no gira / el pasajero lo ve parado mirando al norte".
void main() {
  final driverFiles = Directory('lib/screens/driver')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  String read(File f) => f.readAsStringSync().replaceAll('\r\n', '\n');

  test('#32: no raw platform speed/heading in driver code', () {
    final bad = RegExp(r'pos\.speed\.isFinite && pos\.speed >= 0|'
        r'pos\.speed >= 0 \?|pos\.heading >= 0 \?|pos\.heading >= 0 &&');
    final offenders = [
      for (final f in driverFiles)
        if (bad.hasMatch(read(f))) f.path,
    ];
    expect(offenders, isEmpty,
        reason: 'Android sends 0 when it did not measure — use '
            'measuredSpeedMps / measuredCourseDeg (lib/utils/fix_kinematics.dart)');
  });

  test('#33: every driver position STREAM uses the driver settings', () {
    final offenders = <String>[];
    for (final f in driverFiles) {
      final src = read(f);
      for (final m in RegExp(r'getPositionStream\(').allMatches(src)) {
        final call = src.substring(m.start, (m.start + 160).clamp(0, src.length));
        if (!call.contains('_tripGpsSettings()') &&
            !call.contains('driverLocationSettings(')) {
          offenders.add('${f.path}@${m.start}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'geolocator_android hands every later caller the FIRST '
            "stream's settings — a 10 m / 5 s config starved the nav arrow");
  });

  test('#37: uploads take measured-or-null heading/speed with accuracy', () {
    final gps = read(File('lib/services/gps_service.dart'));
    expect(gps, contains('void updatePosition(LatLng pos, double? heading, double? speed,'));
    expect(gps, contains('double? accuracyM'));
    for (final f in driverFiles) {
      expect(read(f).contains('updatePosition(p, 0, 0)'), isFalse,
          reason: '${f.path}: after a gap send null, never "0 km/h north"');
    }
  });
}
