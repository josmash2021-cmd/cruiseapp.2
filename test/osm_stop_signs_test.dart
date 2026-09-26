import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/directions_service.dart';

/// Guards for the OSM stop-sign path (user report 2026-09-25, "no estan
/// apareciendo los stops" — Mapbox's stop_sign coverage is effectively
/// empty on US routes, so stops come from Overpass).
void main() {
  group('decimatePolyline', () {
    test('keeps short polylines intact (same points, endpoints included)',
        () {
      final pts =
          List.generate(10, (i) => LatLng(26.0 + i * 0.001, -80.0));
      final out = DirectionsService.decimatePolyline(pts);
      expect(out.length, 10);
      expect(out.first.latitude, pts.first.latitude);
      expect(out.last.latitude, pts.last.latitude);
    });

    test('caps long polylines and preserves both endpoints', () {
      final pts =
          List.generate(1000, (i) => LatLng(26.0 + i * 0.0005, -80.0));
      final out = DirectionsService.decimatePolyline(pts);
      expect(out.length, 80);
      expect(out.first.latitude, pts.first.latitude);
      expect(out.last.latitude, closeTo(pts.last.latitude, 1e-9));
    });
  });

  group('buildStopSignQuery', () {
    test('queries highway=stop nodes in a 35 m corridor of the polyline', () {
      final q = DirectionsService.buildStopSignQuery(
          [LatLng(26.1, -80.1), LatLng(26.2, -80.2)]);
      expect(q.contains('node["highway"="stop"]'), isTrue);
      expect(q.contains('(around:35,26.1,-80.1,26.2,-80.2)'), isTrue);
      expect(q.startsWith('[out:json]'), isTrue);
    });
  });

  group('parseStopNodes', () {
    test('reads lat/lon elements and skips malformed ones', () {
      final out = DirectionsService.parseStopNodes({
        'elements': [
          {'type': 'node', 'lat': 26.12, 'lon': -80.34},
          {'type': 'node', 'lat': 26.55}, // no lon — skipped
          {'type': 'way'}, // no coords — skipped
          'garbage',
          {'lat': 26.99, 'lon': -80.01},
        ],
      });
      expect(out.length, 2);
      expect(out[0].latitude, 26.12);
      expect(out[0].longitude, -80.34);
      expect(out[1].latitude, 26.99);
    });

    test('empty / missing elements yields an empty list', () {
      expect(DirectionsService.parseStopNodes(const {}), isEmpty);
    });
  });
}
