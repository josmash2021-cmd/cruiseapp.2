import 'package:cruise_app/services/directions_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lights and stops read from the map's own tiles (owner 2026-11-02: "los
/// semáforos no aparecen en el lugar exacto donde están y tampoco los
/// stops"). Mapbox Streets v8 carries the OSM nodes as `road` points of
/// class traffic_signals / stop_sign — the shape below is what
/// querySourceFeatures hands back.
void main() {
  Map<String?, Object?> point(String cls, double lon, double lat) => {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [lon, lat],
        },
        'properties': {'class': cls, 'type': cls, 'oneway': 'false'},
      };

  test('lights and stops come through, at their own coordinates', () {
    final out = DirectionsService.parseTileSigns([
      point('traffic_signals', -86.783293, 33.335084),
      point('stop_sign', -86.802131, 33.288685),
    ]);
    expect(out, hasLength(2));
    expect(out[0].isStopSign, isFalse);
    expect(out[0].at.latitude, 33.335084);
    expect(out[0].at.longitude, -86.783293);
    expect(out[1].isStopSign, isTrue);
  });

  test('anything else is skipped', () {
    final out = DirectionsService.parseTileSigns([
      point('turning_circle', -86.8, 33.3),
      point('level_crossing', -86.8, 33.3),
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [-86.8, 33.3],
            [-86.7, 33.4],
          ],
        },
        'properties': {'class': 'stop_sign'},
      },
      {'type': 'Feature', 'properties': {'class': 'stop_sign'}},
      null,
    ]);
    expect(out, isEmpty);
  });

  // "¿No aparecerán stops o semáforos en lugares donde no existen?" — a
  // sign counts at a crossing or on its near approach, in the driver's
  // direction; the far approach's stop (oncoming traffic) does not.
  group('signAtCrossing', () {
    const crossings = [400.0, 1300.0];
    test('at the crossing, or up to 30 m before it', () {
      expect(DirectionsService.signAtCrossing(400, crossings), isTrue);
      expect(DirectionsService.signAtCrossing(388, crossings), isTrue);
      expect(DirectionsService.signAtCrossing(371, crossings), isTrue);
    });
    test('past the crossing (oncoming traffic) or far from any: no', () {
      expect(DirectionsService.signAtCrossing(415, crossings), isFalse);
      expect(DirectionsService.signAtCrossing(800, crossings), isFalse);
      expect(DirectionsService.signAtCrossing(1500, crossings), isFalse);
    });
  });
}
