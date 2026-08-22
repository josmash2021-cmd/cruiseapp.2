import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the in-app turn-by-turn navigation (DriverNavView) and its
/// integration into the trip-accept screen.
///
/// Pure source-grep (same style as driver_scheduled_neu_guard_test.dart):
/// the feature needs GPS, a live trip and a native map, so what a unit test
/// CAN pin is that the load-bearing pieces are wired where they belong:
///   1. Web-booking bookkeeping lines never reach the driver as
///      "passenger instructions".
///   2. The expansion into navigation animates a StaticMapSnapshot and never
///      resizes the live MapWidget (a PlatformView cannot be relaid out —
///      that resize is the crash path).
///   3. The rider figure is a pickup-leg-only element: the slide to pick up
///      flips the leg and the figure goes with it.
///   4. A rider with Location Sharing off (privacy_location == false)
///      publishes nothing.
void main() {
  final accept =
      File('lib/screens/driver/driver_trip_accept_screen.dart')
          .readAsStringSync();
  final nav = File('lib/screens/driver/driver_nav_view.dart')
      .readAsStringSync();
  final riderMap =
      File('lib/widgets/tracking/tracking_map_view.dart').readAsStringSync();

  group('web booking filter', () {
    final start = accept.indexOf('String get _passengerInstructions');
    final block = start >= 0 ? accept.substring(start, start + 1200) : '';

    test('_passengerInstructions drops "Web booking" lines', () {
      expect(block, isNotEmpty,
          reason: '_passengerInstructions getter not found');
      expect(block, contains("startsWith('web booking')"));
    });

    test('the filter is case-insensitive', () {
      expect(block, contains('.toLowerCase()'));
    });

    test('real passenger instructions still pass', () {
      // The Wait started: filter predates this feature — both must stay.
      expect(block, contains("startsWith('Wait started:')"));
    });
  });

  group('nav expansion', () {
    test('animates a StaticMapSnapshot from the mini map rect', () {
      final start = accept.indexOf('Future<void> _enterNavMode');
      final block =
          start >= 0 ? accept.substring(start, start + 1600) : '';
      expect(block, isNotEmpty, reason: '_enterNavMode not found');
      expect(block, contains('_miniMapKey'));
      expect(accept, contains('StaticMapSnapshot('));
    });

    test('the live MapWidget is never resized by the expansion', () {
      // The overlay animates a Rect over an IMAGE: the expansion block must
      // carry the snapshot and no MapWidget (a PlatformView cannot be
      // relaid out mid-flight — that resize is the crash path).
      final start = accept.indexOf('// ── Expansion snapshot');
      final block =
          start >= 0 ? accept.substring(start, start + 1800) : '';
      expect(block, isNotEmpty, reason: 'expansion overlay not found');
      expect(block, contains('StaticMapSnapshot('));
      expect(block, contains('Positioned.fromRect'));
      expect(block, isNot(contains('MapWidget')));
      // Nav mounts its own full-screen map under its own coordinator owner.
      expect(nav, contains("'DriverTripNav-"));
      expect(nav, contains('MapSurfaceCoordinator.instance.acquire('));
    });

    test('the preview releases the surface before nav mounts', () {
      final start = accept.indexOf('Future<void> _enterNavMode');
      final block =
          start >= 0 ? accept.substring(start, start + 1600) : '';
      final release = block.indexOf('release(_mapSurfaceOwner)');
      final navOn = block.indexOf('_navMode = true');
      expect(release, greaterThan(-1));
      expect(navOn, greaterThan(release),
          reason:
              'The preview must let go of the surface before the nav view mounts — two live MapWidgets crash iOS.');
    });
  });

  group('rider figure', () {
    test('is gated on the pickup leg', () {
      final start = nav.indexOf('Future<void> _updateRiderAnnotation');
      final block = start >= 0 ? nav.substring(start, start + 700) : '';
      expect(block, isNotEmpty);
      expect(block, contains('if (!widget.toPickup) return;'));
    });

    test('the leg flip (slide to pick up) deletes the annotation', () {
      final start = nav.indexOf('void didUpdateWidget');
      final block = start >= 0 ? nav.substring(start, start + 900) : '';
      expect(block, contains('oldWidget.toPickup != widget.toPickup'));
      expect(block, contains('mgr.delete(annot)'));
    });
  });

  group('rider publishing privacy', () {
    test('honors the privacy_location toggle', () {
      final start = riderMap.indexOf('_startRiderLocationSharing');
      final block =
          start >= 0 ? riderMap.substring(start, start + 1400) : '';
      expect(block, isNotEmpty,
          reason: '_startRiderLocationSharing not found');
      expect(block, contains("getBool('privacy_location')"));
    });

    test('publishes through the socket relay with the fix capture time', () {
      expect(riderMap, contains('SocketService.sendRiderLocation('));
      expect(riderMap, contains('capturedAtMs'));
    });

    test('stops publishing once the pickup window closes', () {
      expect(riderMap, contains('_stopRiderLocationSharing()'));
      expect(riderMap, contains('_TrackPhase.arriving'));
      expect(riderMap, contains('_TrackPhase.arrived'));
    });
  });
}
