import 'dart:math' as math;
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

  group('screenOffsetHeading (bearing-aware flat projection, 2026-10-10)', () {
    test('bearing zero is exactly the flat case', () {
      const north = LatLng(33.2957, -86.8097);
      final flat = FlatMapProjection.screenOffsetFlat(
        target: north, cameraCenter: pelham, zoom: 15,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      );
      final rotated = FlatMapProjection.screenOffsetHeading(
        target: north, cameraCenter: pelham, zoom: 15,
        bearingDeg: 0, pitchDeg: 0, viewport: viewport,
      );
      expect(rotated, flat);
    });

    test('at bearing 90 (camera facing east), east is up and north is left',
        () {
      const east = LatLng(33.2857, -86.7997);
      const north = LatLng(33.2957, -86.8097);
      final e = FlatMapProjection.screenOffsetHeading(
        target: east, cameraCenter: pelham, zoom: 15,
        bearingDeg: 90, pitchDeg: 0, viewport: viewport,
      )!;
      final n = FlatMapProjection.screenOffsetHeading(
        target: north, cameraCenter: pelham, zoom: 15,
        bearingDeg: 90, pitchDeg: 0, viewport: viewport,
      )!;
      expect(e.dy, lessThan(400), reason: 'east of centre lands screen-up');
      expect(e.dx, closeTo(200, 0.001));
      expect(n.dx, lessThan(200), reason: 'north of centre lands screen-left');
      expect(n.dy, closeTo(400, 0.001));
    });

    test('rotation preserves the distance from centre', () {
      const away = LatLng(33.3057, -86.7897); // diagonal, ~2 km NE
      const centre = Offset(200, 400);
      double dist(Offset o) => (o - centre).distance;
      for (final b in [0.0, 47.0, 123.0, 269.0]) {
        final o = FlatMapProjection.screenOffsetHeading(
          target: away, cameraCenter: pelham, zoom: 15,
          bearingDeg: b, pitchDeg: 0, viewport: viewport,
        )!;
        expect(dist(o), closeTo(dist(FlatMapProjection.screenOffsetHeading(
          target: away, cameraCenter: pelham, zoom: 15,
          bearingDeg: 0, pitchDeg: 0, viewport: viewport,
        )!), 0.001), reason: 'rotation is rigid — bearing $b°');
      }
    });

    test('still declines a tilted camera instead of guessing', () {
      expect(
        FlatMapProjection.screenOffsetHeading(
          target: pelham, cameraCenter: pelham, zoom: 16,
          bearingDeg: 30, pitchDeg: 55, viewport: viewport,
        ),
        isNull,
      );
    });
  });

  // Owner report 2026-11-02, "no se ve la ruta completa": the offer route
  // ran down under the offer card. The fit is now our own arithmetic.
  group('fitFlat', () {
    const phone = Size(390, 844);
    const top = 111.0, bottom = 522.0, side = 60.0;
    // The test trip in the screenshot: driver north of Pelham, pickup on
    // Pelham Park Blvd, a stop on Pelham Pkwy, drop-off at the amphitheater.
    const route = [
      LatLng(33.3432, -86.7838),
      LatLng(33.2905, -86.8012),
      LatLng(33.2961, -86.7965),
      LatLng(33.3329, -86.7431),
    ];

    Offset at(LatLng p, ({LatLng center, double zoom}) fit) =>
        FlatMapProjection.screenOffsetFlat(
          target: p,
          cameraCenter: fit.center,
          zoom: fit.zoom,
          bearingDeg: 0,
          pitchDeg: 0,
          viewport: phone,
        )!;

    test('every point lands inside the window above the card', () {
      final fit = FlatMapProjection.fitFlat(
        points: route,
        viewport: phone,
        top: top,
        left: side,
        bottom: bottom,
        right: side,
        maxZoom: 15.5,
      )!;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in route) {
        final o = at(p, fit);
        expect(o.dx, inInclusiveRange(side - 0.5, phone.width - side + 0.5));
        expect(o.dy,
            inInclusiveRange(top - 0.5, phone.height - bottom + 0.5));
        minY = math.min(minY, o.dy);
        maxY = math.max(maxY, o.dy);
      }
      // Centred in the window, not in the screen.
      expect((minY + maxY) / 2,
          closeTo(top + (phone.height - top - bottom) / 2, 0.5));
    });

    test('the tighter side fills the window — no needless zoom-out', () {
      final fit = FlatMapProjection.fitFlat(
        points: route,
        viewport: phone,
        top: top,
        left: side,
        bottom: bottom,
        right: side,
      )!;
      final xs = [for (final p in route) at(p, fit).dx];
      final ys = [for (final p in route) at(p, fit).dy];
      final spanX = xs.reduce(math.max) - xs.reduce(math.min);
      final spanY = ys.reduce(math.max) - ys.reduce(math.min);
      final fillsX = (spanX - (phone.width - 2 * side)).abs() < 0.5;
      final fillsY = (spanY - (phone.height - top - bottom)).abs() < 0.5;
      expect(fillsX || fillsY, isTrue);
    });

    test('two points a block apart stop at the cap, centred in the window',
        () {
      const a = LatLng(33.2900, -86.8000);
      const b = LatLng(33.2902, -86.8001);
      final fit = FlatMapProjection.fitFlat(
        points: const [a, b],
        viewport: phone,
        top: top,
        bottom: bottom,
        maxZoom: 15.5,
      )!;
      expect(fit.zoom, 15.5);
      final mid = (at(a, fit) + at(b, fit)) / 2;
      expect(mid.dx, closeTo(phone.width / 2, 0.5));
      expect(mid.dy, closeTo(top + (phone.height - top - bottom) / 2, 0.5));
    });

    test('no room or a broken point gives no camera', () {
      expect(
          FlatMapProjection.fitFlat(
              points: route, viewport: phone, top: 500, bottom: 400),
          isNull);
      expect(
          FlatMapProjection.fitFlat(
              points: const [LatLng(double.nan, -86.8)], viewport: phone),
          isNull);
    });
  });
}
