import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/services/road_snap_service.dart';

/// Guardian for the driver-map road snap (user report 2026-09-27: zoomed
/// all the way in, the arrow sits off the road lines).
///
/// Two layers, both pinned here:
///   1. Whenever a route exists the snap has NO phase gate anymore — the
///      old enRouteToPickup/inTrip-only rule left the offer preview and
///      routeSummary floating on raw GPS.
///   2. While searching, the RoadSnapService matches the driver's own trace
///      to the street network (throttled, moving-only) and the projection
///      falls back to that line; offline/dispose reset it.
void main() {
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final svc =
      File('lib/services/road_snap_service.dart').readAsStringSync();

  group('route snap has no phase gate', () {
    test('the line is the route when it exists, the road line when not', () {
      expect(map.contains('final onRoute = _routePts.length >= 2;'), isTrue);
      expect(map.contains('final pts = onRoute ? _routePts : _roadLinePts;'),
          isTrue,
          reason: 'searching falls back to the matched road line — that is '
              'the whole fix');
      final fnStart = map.indexOf('LatLng _snapToRoute(LatLng raw) {');
      final fn = map.substring(fnStart, fnStart + 900);
      expect(fn.contains('_Phase.enRouteToPickup'), isFalse,
          reason: 'the phase gate is what left the offer preview and '
              'routeSummary unsnapped');
    });

    test('a source switch resets the segment bookkeeping and the trace', () {
      expect(map.contains('_snapOnRouteSrc != onRoute'), isTrue);
      expect(map.contains('_roadSnap.reset();'), isTrue,
          reason: 'a route appearing must kill the search trace');
    });
  });

  group('searching feed is gated and reset', () {
    test('the trace only feeds with no route, map alive, app in front', () {
      expect(
          ctrl.contains(
              'if (_routePts.length < 2 && _mapMounted && _appInForeground)'),
          isTrue,
          reason: 'covered/backgrounded screens must not burn matching '
              'calls — the arrow is not visible there');
    });

    test('offline and dispose forget the trace', () {
      final exitStart = ctrl.indexOf('Future<void> _exitOnlineMode()');
      final exitBlock = ctrl.substring(exitStart, exitStart + 1400);
      expect(exitBlock.contains('_roadSnap.reset();'), isTrue);
      expect(exitBlock.contains('_roadLinePts = const [];'), isTrue);
      final screen =
          File('lib/screens/driver/driver_online_screen.dart')
              .readAsStringSync();
      expect(screen.contains('_roadSnap.reset(); // in-flight'), isTrue);
    });
  });

  group('the service is throttled and moving-only', () {
    test('one call per 6 s and only when the trace spans ground', () {
      expect(svc.contains('_minInterval = Duration(seconds: 6)'), isTrue);
      expect(svc.contains('_minTraceSpanM = 12.0'), isTrue,
          reason: 'parked/crawling drivers are owned by the stationary '
              'freeze — matching calls are not free');
      expect(svc.contains('_traceMax = 10'), isTrue);
    });

    test('mapbox matching first, osrm fallback, tidy trace', () {
      expect(svc.contains('api.mapbox.com/matching/v5/mapbox/driving/'),
          isTrue);
      expect(svc.contains("'/match/v1/driving/"), isTrue);
      expect(svc.contains('tidy=true'), isTrue);
    });
  });

  group('match geometry parser', () {
    test('parses the shared matchings[0].geometry shape', () {
      final line = RoadSnapService.parseMatchGeometry(
          '{"matchings":[{"geometry":{"coordinates":[[-86.8,33.5],[-86.79,33.51],[-86.78,33.52]]}}]}');
      expect(line, isNotNull);
      expect(line!.length, 3);
      expect(line.first.latitude, 33.5);
      expect(line.first.longitude, -86.8);
      expect(line.last.latitude, 33.52);
    });

    test('rejects empty/malformed payloads instead of poisoning the line',
        () {
      expect(RoadSnapService.parseMatchGeometry('{}'), isNull);
      expect(RoadSnapService.parseMatchGeometry('{"matchings":[]}'), isNull);
      expect(
          RoadSnapService.parseMatchGeometry(
              '{"matchings":[{"geometry":{"coordinates":[]}}]}'),
          isNull);
      expect(RoadSnapService.parseMatchGeometry('not json'), isNull);
      // A single out-of-range pair must not kill the good ones.
      final line = RoadSnapService.parseMatchGeometry(
          '{"matchings":[{"geometry":{"coordinates":[[-86.8,33.5],[999,999],[-86.78,33.52]]}}]}');
      expect(line, isNotNull);
      expect(line!.length, 2);
    });
  });
}
