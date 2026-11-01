// Mapbox invoice 2026-11-01: 1,497,236 Static Images requests in October
// ($1,148.80). The driver map's loading still stayed mounted at opacity 0
// and was rebuilt with a new centre on every GPS fix — one billed request
// per fix, for every driver with the app open. These guards fail with the
// old code.
import 'dart:io';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/widgets/static_map_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a GPS fix a few metres away reuses the same still URL', () {
    final a = StaticMapSnapshot.imageUrl(
        const LatLng(25.791601, -80.148881), 16, 400, 800);
    final b = StaticMapSnapshot.imageUrl(
        const LatLng(25.791612, -80.148869), 16, 400, 800);
    expect(a, b);
  });

  test('the driver map still leaves the tree once it has faded out', () {
    final src =
        File('lib/screens/driver/driver_online_widgets.dart').readAsStringSync();
    final veil = src.indexOf('opacity: (_mapStyleLoaded && _firstRenderDone)');
    expect(veil, greaterThan(0));
    final block = src.substring(veil, veil + 2500);
    expect(block, contains('onEnd:'));
    expect(block, contains('_mapVeilFadedOut'));
    expect(block, contains('const SizedBox.shrink()'));
  });

  test('the rider stand-in snaps the streamed driver position', () {
    final src =
        File('lib/screens/rider_confirm_pickup_screen.dart').readAsStringSync();
    final start = src.indexOf('Widget _buildMiniMapStandIn()');
    expect(start, greaterThan(0));
    final body = src.substring(start, start + 1500);
    expect(body, contains('dropoffLat:'));
    expect(body, contains('q(driver.latitude)'));
  });
}
