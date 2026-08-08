import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the onTrip full-route framing fix (user spec 2026-08-08):
/// while the trip is running, the rider's camera must ALWAYS frame the
/// complete pickup→dropoff route, not the remaining car→dropoff leg.
///
/// The camera paths need a live Mapbox surface, so what a source test CAN
/// pin is the data discipline that keeps the frame honest:
///   1. `_tripFramePoints` frames `_tripRoutePts` (the immutable full-trip
///      polyline) with `_routePts` only as fallback.
///   2. The traffic refresh (every 2 min) replaces `_routePts` for the
///      erase/ETA but never touches the framing list `_tripRoutePts`.
///   3. `_applyReroutedPolyline` splices the drawn geometry without
///      touching `_tripRoutePts` either.
///   4. `updateFollowFrame`'s seed flyTo only marks `_followZoom/_followCenter`
///      as seeded after the flyTo actually went out — a failed flyTo un-seeds
///      so the next frame retries.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final view =
      File('lib/widgets/tracking/tracking_map_view.dart').readAsStringSync();
  final ctrl = File('lib/controllers/rider_tracking_controller.dart')
      .readAsStringSync();
  final cam =
      File('lib/map/tracking_map_camera.dart').readAsStringSync();

  group('_tripFramePoints frames the whole trip', () {
    test('uses _tripRoutePts with _routePts only as fallback', () {
      final fn = RegExp(r'List<LatLng> _tripFramePoints\(\) \{');
      final start = fn.firstMatch(view)!.end;
      final body = view.substring(start, start + 900);
      final trip = body.indexOf('_tripRoutePts');
      final fallback = body.indexOf('pts.addAll(_routePts)');
      expect(trip, isNonNegative,
          reason: '_tripFramePoints must read the full-trip polyline '
              '(_tripRoutePts) — framing _routePts collapses the box to '
              'car→dropoff after the first traffic refresh');
      expect(fallback, isNonNegative,
          reason: '_routePts stays as fallback for paths where the trip '
              'route never seeded');
      expect(trip, lessThan(fallback),
          reason: 'the trip-route branch must come before the fallback');
      expect(
          body.substring(trip, fallback).contains('_tripRoutePts.length >= 2'),
          isTrue,
          reason: 'the trip route is only used when it holds a real polyline');
    });
  });

  group('traffic refresh never touches the framing list', () {
    test('_startTrafficRefreshTimer does not assign _tripRoutePts', () {
      final fn = RegExp(r'void _startTrafficRefreshTimer\(\) \{');
      final start = fn.firstMatch(ctrl)!.end;
      // The whole timer body up to the next method declaration.
      final end = ctrl.indexOf(RegExp(r'\n  ///'), start);
      final body = ctrl.substring(start, end > start ? end : start + 2500);
      expect(body.contains('_routePts = result.points'), isTrue,
          reason: 'the refresh still updates the drawn/erase geometry');
      expect(body.contains('_tripRoutePts ='), isFalse,
          reason: 'reassigning _tripRoutePts to the remaining car→dropoff '
              'leg collapses the onTrip camera frame — this IS the bug');
    });
  });

  group('_applyReroutedPolyline never touches the framing list', () {
    test('splices _routePts only', () {
      final fn = RegExp(
          r'Future<void> _applyReroutedPolyline\(List<LatLng> spliced\) async \{');
      final start = fn.firstMatch(view)!.end;
      final end = view.indexOf(RegExp(r'\n  ///'), start);
      final body = view.substring(start, end > start ? end : start + 4000);
      expect(body.contains('_routePts = spliced'), isTrue,
          reason: 'the reroute still swaps the active drawn geometry');
      expect(body.contains('_tripRoutePts ='), isFalse,
          reason: 'the splice is car→dropoff — storing it as the trip route '
              'would collapse the onTrip frame');
    });
  });

  group('updateFollowFrame seed marks only after success', () {
    test('_followZoom/_followCenter are set after the flyTo call', () {
      final marker = cam.indexOf('if (_followZoom == null || _followCenter == null) {');
      expect(marker, isNonNegative, reason: 'seed block not found');
      final end = cam.indexOf('_followSettleUntil != null', marker);
      final block = cam.substring(marker, end > marker ? end : marker + 1500);
      final flyTo = block.indexOf('.flyTo(');
      final seeded = block.indexOf('_followZoom = _followTargetZoom');
      expect(flyTo, isNonNegative);
      expect(seeded, isNonNegative);
      expect(seeded, greaterThan(flyTo),
          reason: 'marking seeded BEFORE the flyTo went out leaves the '
              'framer believing it seeded when the flyTo actually failed');
      expect(block.contains('catchError'), isTrue);
      final catchAt = block.indexOf('catchError');
      final catchBody = block.substring(catchAt, seeded);
      expect(catchBody.contains('_followZoom = null'), isTrue,
          reason: 'a failed flyTo must un-seed so the next frame retries');
      expect(catchBody.contains('_followCenter = null'), isTrue,
          reason: 'a failed flyTo must un-seed so the next frame retries');
    });
  });
}
