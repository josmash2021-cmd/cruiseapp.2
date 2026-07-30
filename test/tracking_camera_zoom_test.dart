import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/tracking_map_camera.dart';
import 'package:cruise_app/models/lat_lng.dart';

/// Tests for the approach-camera framing math.
///
/// This decides how the rider watches their driver come to them: too wide
/// and the car crawls across a static map, too tight and the pickup pin
/// falls off screen. It is pure arithmetic derived from Mapbox's
/// metres-per-pixel relation, so it is worth pinning down rather than
/// trusting a device to reveal a unit slip.
void main() {
  // A typical phone viewport with the tracking cards accounted for.
  const screen = Size(390, 844);
  const topPad = 120.0; // safe area + status bar card
  const bottomPad = 200.0; // safe area + driver card

  // Pelham, AL — the area in the real screenshots.
  const pickup = LatLng(33.3, -86.8);

  /// A point [metres] north of [from]. 1 degree latitude ≈ 111320 m.
  LatLng northOf(LatLng from, double metres) =>
      LatLng(from.latitude + metres / 111320.0, from.longitude);

  double zoomAt(double metresAway) => zoomToFitSpan(
        northOf(pickup, metresAway),
        pickup,
        screen,
        topPad,
        bottomPad,
      );

  group('zoomToFitSpan', () {
    test('stays inside the clamp for every distance', () {
      for (final m in [5.0, 50.0, 200.0, 1000.0, 5000.0, 50000.0, 500000.0]) {
        final z = zoomAt(m);
        expect(z, inInclusiveRange(11.0, 17.0), reason: '$m m away → $z');
      }
    });

    test('tightens monotonically as the driver closes in', () {
      // The whole point of the change: the view must never open back up
      // while the driver is getting nearer.
      final distances = [4000.0, 2000.0, 1000.0, 500.0, 250.0, 120.0, 60.0];
      var previous = zoomAt(distances.first);
      for (final m in distances.skip(1)) {
        final z = zoomAt(m);
        expect(z, greaterThanOrEqualTo(previous),
            reason: 'zoom dropped going from further out to $m m');
        previous = z;
      }
    });

    test('is genuinely wide when the driver is far and close when near', () {
      // 5 km out should not be a street-level view...
      expect(zoomAt(5000), lessThan(14.0));
      // ...and 100 m out should be, or the rider cannot tell which street
      // the car is on — the complaint that started this.
      expect(zoomAt(100), greaterThan(15.5));
    });

    test('does not race to max zoom the instant the driver pulls up', () {
      // Span is floored, so converging points settle instead of snapping
      // to the tightest possible frame.
      expect(zoomAt(1.0), equals(zoomAt(0.0)));
    });

    test('identical points produce a finite, clamped zoom', () {
      final z = zoomToFitSpan(pickup, pickup, screen, topPad, bottomPad);
      expect(z.isFinite, isTrue);
      expect(z, inInclusiveRange(11.0, 17.0));
    });

    test('survives padding taller than the screen', () {
      // Cards taller than the viewport would otherwise divide by ~zero.
      final z = zoomToFitSpan(
        northOf(pickup, 500),
        pickup,
        screen,
        900,
        900,
      );
      expect(z.isFinite, isTrue);
      expect(z, inInclusiveRange(11.0, 17.0));
    });

    test('survives a zero-sized screen', () {
      final z = zoomToFitSpan(
        northOf(pickup, 500),
        pickup,
        Size.zero,
        0,
        0,
      );
      expect(z.isFinite, isTrue);
      expect(z, inInclusiveRange(11.0, 17.0));
    });

    test('east-west spans are framed like north-south ones', () {
      // Longitude degrees shrink with latitude; forgetting cos(lat) is the
      // classic slip here and would frame east-west trips far too tight.
      const metres = 1000.0;
      final northSouth = zoomAt(metres);
      final eastWest = zoomToFitSpan(
        LatLng(
          pickup.latitude,
          pickup.longitude +
              metres /
                  (111320.0 * 0.8355), // cos(33.3°) ≈ 0.8355
        ),
        pickup,
        screen,
        topPad,
        bottomPad,
      );
      // Same real-world distance → same framing, give or take the
      // difference between the viewport's width and height.
      expect((northSouth - eastWest).abs(), lessThan(1.5),
          reason: 'N-S $northSouth vs E-W $eastWest');
    });

    test('a wider viewport never frames tighter than a narrow one', () {
      final narrow = zoomToFitSpan(
          northOf(pickup, 800), pickup, const Size(320, 700), topPad, bottomPad);
      final wide = zoomToFitSpan(
          northOf(pickup, 800), pickup, const Size(430, 930), topPad, bottomPad);
      expect(wide, greaterThanOrEqualTo(narrow));
    });
  });

  /// The in-trip chase camera: the rider watching their own car drive.
  ///
  /// These two numbers have been widened twice in the name of legibility
  /// and reported as a bug both times — at a district-wide zoom, or with
  /// the car parked in the middle of the screen, the view is
  /// indistinguishable from the route overview and stops reading as
  /// following the car at all. They are pinned here on purpose.
  group('chase camera', () {
    test('never pulls back to an overview at any speed', () {
      for (final speed in [0.0, 1.0, 5.0, 12.0, 25.0, 40.0]) {
        final z = chaseZoomForSpeed(speed);
        expect(z, greaterThanOrEqualTo(16.0),
            reason: '$speed m/s → $z is overview-wide, not a chase');
        expect(z, lessThanOrEqualTo(17.5), reason: '$speed m/s → $z');
      }
    });

    test('widens monotonically with speed', () {
      final speeds = [0.0, 1.9, 2.0, 7.9, 8.0, 17.9, 18.0, 35.0];
      for (var i = 1; i < speeds.length; i++) {
        expect(chaseZoomForSpeed(speeds[i]),
            lessThanOrEqualTo(chaseZoomForSpeed(speeds[i - 1])),
            reason: '${speeds[i]} m/s must not be closer than ${speeds[i - 1]}');
      }
    });

    test('holds the car low on the screen, not in the middle', () {
      final y = chaseAnchorY(screen.height, topPad, bottomPad);
      expect(y / screen.height, greaterThan(0.55),
          reason: 'car parked at ${y / screen.height} of the screen');
      // And still clear of the driver card.
      expect(y, lessThanOrEqualTo(screen.height - bottomPad));
    });

    test('keeps the car clear of both cards on a short screen', () {
      const shortScreen = 600.0;
      final y = chaseAnchorY(shortScreen, 150, 260);
      expect(y, greaterThanOrEqualTo(150));
      expect(y, lessThanOrEqualTo(shortScreen - 260));
    });

    test('survives cards taller than the screen', () {
      final y = chaseAnchorY(500, 400, 400);
      expect(y.isFinite, isTrue);
      expect(y, inInclusiveRange(0, 500));
    });
  });
}
