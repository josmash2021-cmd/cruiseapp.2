import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/flat_map_projection.dart';
import 'package:cruise_app/models/lat_lng.dart';

/// This arithmetic decides where the driver's own marker is drawn once they
/// pan the map. Getting it wrong does not look like a bug — it looks like
/// the driver being somewhere they are not, confidently. It is pure maths,
/// so it gets pinned down here rather than discovered on a phone.
void main() {
  const viewport = Size(400, 800);
  const pelham = LatLng(33.2857, -86.8097); // the area in the screenshots

  group('screenOffsetFlat', () {
    test('the camera centre lands in the middle of the viewport', () {
      final o = FlatMapProjection.screenOffsetFlat(
        target: pelham,
        cameraCenter: pelham,
        zoom: 16,
        bearingDeg: 0,
        pitchDeg: 0,
        viewport: viewport,
      )!;
      expect(o.dx, closeTo(200, 0.001));
      expect(o.dy, closeTo(400, 0.001));
    });

    test('north of centre draws above it, east draws to the right', () {
      const north = LatLng(33.2957, -86.8097);
      const east = LatLng(33.2857, -86.7997);
      final n = FlatMapProjection.screenOffsetFlat(
        target: north, cameraCenter: pelham, zoom: 15,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      final e = FlatMapProjection.screenOffsetFlat(
        target: east, cameraCenter: pelham, zoom: 15,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      // Screen y grows downward, so further north is a smaller y.
      expect(n.dy, lessThan(400));
      expect(n.dx, closeTo(200, 0.001));
      expect(e.dx, greaterThan(200));
      expect(e.dy, closeTo(400, 0.001));
    });

    test('one zoom level in doubles the distance from centre', () {
      const away = LatLng(33.2957, -86.8097);
      final z15 = FlatMapProjection.screenOffsetFlat(
        target: away, cameraCenter: pelham, zoom: 15,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      final z16 = FlatMapProjection.screenOffsetFlat(
        target: away, cameraCenter: pelham, zoom: 16,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      final d15 = 400 - z15.dy;
      final d16 = 400 - z16.dy;
      expect(d16 / d15, closeTo(2.0, 0.001));
    });

    test('matches the metres-per-pixel Mapbox actually renders at', () {
      // Mapbox serves 512 px tiles, so the world is 512 * 2^zoom pixels wide
      // and the equator resolution at zoom 0 is 40075017 / 512 = 78271.5
      // m/px — NOT the 156543 of the 256 px tile convention Google popularised.
      //
      // The two differ by exactly a factor of two, which is exactly one zoom
      // level, and a marker placed with the wrong one sits at twice the right
      // distance from centre while looking entirely plausible. That is the
      // failure this test exists to catch, and it caught it on the first run.
      const zoom = 16.0;
      const metres = 160.0;
      final target = LatLng(pelham.latitude + metres / 111320.0, pelham.longitude);
      final o = FlatMapProjection.screenOffsetFlat(
        target: target, cameraCenter: pelham, zoom: zoom,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      final pixelsUp = 400 - o.dy;
      const metresPerPixel = 78271.484 * 0.8362 / 65536; // cos(33.29°), 2^16
      final expected = metres / metresPerPixel;
      expect(pixelsUp, closeTo(expected, expected * 0.02));
    });

    test('declines tilted or rotated cameras instead of guessing', () {
      expect(
        FlatMapProjection.screenOffsetFlat(
          target: pelham, cameraCenter: pelham, zoom: 16,
          bearingDeg: 0, pitchDeg: 55, viewport: viewport,
        ),
        isNull,
      );
      expect(
        FlatMapProjection.screenOffsetFlat(
          target: pelham, cameraCenter: pelham, zoom: 16,
          bearingDeg: 90, pitchDeg: 0, viewport: viewport,
        ),
        isNull,
      );
    });

    test('takes the short way round the antimeridian', () {
      const justWest = LatLng(0, 179.99);
      const justEast = LatLng(0, -179.99);
      final o = FlatMapProjection.screenOffsetFlat(
        target: justEast, cameraCenter: justWest, zoom: 10,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      // Two hundredths of a degree apart, not a whole world.
      expect((o.dx - 200).abs(), lessThan(50));
    });

    test('survives nonsense input without returning a wrong pixel', () {
      expect(
        FlatMapProjection.screenOffsetFlat(
          target: pelham, cameraCenter: pelham, zoom: double.nan,
          bearingDeg: 0, pitchDeg: 0, viewport: viewport,
        ),
        isNull,
      );
      expect(
        FlatMapProjection.screenOffsetFlat(
          target: pelham, cameraCenter: pelham, zoom: 16,
          bearingDeg: 0, pitchDeg: 0, viewport: Size.zero,
        ),
        isNull,
      );
    });

    test('a driver far off screen is reported off screen, not clamped', () {
      const farAway = LatLng(34.5, -86.8097); // ~130 km north
      final o = FlatMapProjection.screenOffsetFlat(
        target: farAway, cameraCenter: pelham, zoom: 16,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      )!;
      expect(FlatMapProjection.isOnScreen(o, viewport), isFalse);
      expect(o.dy, lessThan(0));
    });

    test('a marker half off the edge still counts as on screen', () {
      expect(
        FlatMapProjection.isOnScreen(const Offset(-20, 400), viewport),
        isTrue,
      );
      expect(
        FlatMapProjection.isOnScreen(const Offset(-200, 400), viewport),
        isFalse,
      );
    });
  });
}
