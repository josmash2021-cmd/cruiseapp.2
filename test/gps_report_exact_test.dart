import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/gps_service.dart';

/// Owner report 2026-10-29: the location the driver's phone reported (to
/// the rider and dispatch) was not exact. Android's Doppler-less fixes went
/// out as "0 m/s facing north", and a vague fix replaced a good one.
void main() {
  const lat0 = 33.32872, lng0 = -86.78781;
  const mPerDegLng = 111320.0 * 0.8357;
  final gps = GpsService();

  setUp(gps.debugResetReported);

  Future<void> beat() => Future<void>.delayed(const Duration(milliseconds: 400));

  test('unknown speed/heading are derived from the track, not sent as 0/north',
      () async {
    gps.updatePosition(const LatLng(lat0, lng0), null, null, accuracyM: 5);
    await beat();
    gps.updatePosition(const LatLng(lat0, lng0 + 8 / mPerDegLng), null, null,
        accuracyM: 5);
    expect(gps.reportedHeading, closeTo(90, 2), reason: 'driving east');
    expect(gps.reportedSpeed, greaterThan(10), reason: '8 m in ~0.4 s');
  });

  test('measured values win when the platform has them', () async {
    gps.updatePosition(const LatLng(lat0, lng0), 180, 7, accuracyM: 5);
    expect(gps.reportedHeading, 180);
    expect(gps.reportedSpeed, 7);
  });

  test('a vague fix right after a good one does not replace it', () async {
    gps.updatePosition(const LatLng(lat0, lng0), 0, 0, accuracyM: 6);
    gps.updatePosition(const LatLng(lat0 + 0.0006, lng0), 0, 0, accuracyM: 70);
    expect(gps.reportedPos!.latitude, lat0, reason: '70 m fix ignored');
    gps.updatePosition(const LatLng(lat0 + 0.0001, lng0), 0, 0, accuracyM: 30);
    expect(gps.reportedPos!.latitude, lat0 + 0.0001,
        reason: 'a usable (<= 50 m) fix still moves it');
  });

  test('a parked car reports 0, never a made-up heading', () async {
    gps.updatePosition(const LatLng(lat0, lng0), 45, null, accuracyM: 5);
    await beat();
    gps.updatePosition(const LatLng(lat0, lng0 + 1 / mPerDegLng), null, null,
        accuracyM: 5);
    expect(gps.reportedSpeed, 0, reason: 'wander inside the fix error is not motion');
    expect(gps.reportedHeading, 45, reason: '1 m is GPS wander, keep heading');
  });
}
