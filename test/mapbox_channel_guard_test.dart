import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Mapbox channel-error crash cluster.
///
/// One live Mapbox surface is multiplexed through MapSurfaceCoordinator;
/// when it is revoked every pigeon handle dies and any later write rejects
/// with PlatformException(channel-error). Unhandled, those rejections land
/// in the zone as FATAL crashes. The guard pins:
///   1. The root fix — onRevoke nulls every map/annotation handle (mirror of
///      driver_online_controller._releaseMapSurface), so post-revoke writes
///      hit Dart null instead of a dead native channel.
///   2. Defense-in-depth — every bare `_mapCtrl?.flyTo/setCamera` in the
///      ride-request controller/map carries a catchError on the same
///      statement (async rejections are NOT caught by sync try/catch).
///   3. The same for `ctrl.setCamera(` in driver_trip_accept_screen.
///   4. _resetCinematic stops each AnimationController inside try/catch —
///      a disposed-but-not-nulled controller throws on stop().
///
/// Sections read the source directly: the crashing paths need a live Mapbox
/// surface, so what a unit test CAN pin is that the guards stay wired.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The text of the statement that starts at [at]: up to the first `;`.
  String statementOf(String src, int at) {
    final end = src.indexOf(';', at);
    return src.substring(at, end == -1 ? src.length : end);
  }

  group('root fix: onRevoke releases every handle', () {
    final src = File('lib/screens/ride_request_screen.dart').readAsStringSync();

    test('onRevoke nulls _mapCtrl and the annotation handles', () {
      final at = src.indexOf('onRevoke: () async {');
      expect(at, isNonNegative, reason: 'onRevoke not found');
      final block = src.substring(at, at + 1400);
      for (final handle in [
        '_mapCtrl = null',
        '_polylineAnnotMgr = null',
        '_pointAnnotMgr = null',
        '_pickupAnnot = null',
        '_dropoffAnnot = null',
        '_routeAnnot = null',
      ]) {
        expect(block.contains(handle), isTrue,
            reason: 'onRevoke no longer nulls "$handle" — post-revoke writes '
                'poke a dead native channel (the root crash)');
      }
    });
  });

  group('no bare camera writes in ride_request', () {
    for (final entry in {
      'lib/screens/ride_request_controller.dart': 'controller',
      'lib/screens/ride_request_map.dart': 'map',
    }.entries) {
      final src = File(entry.key).readAsStringSync();

      test('${entry.value}: every _mapCtrl?.flyTo/setCamera handles the rejection', () {
        final bare = RegExp(r'_mapCtrl\?\.(flyTo|setCamera)\(');
        for (final m in bare.allMatches(src)) {
          final stmt = statementOf(src, m.start);
          // Sites already routed through a wrapper that awaits the future
          // (e.g. _pushCamera) are protected by design — whitelist them.
          if (stmt.contains('await ')) continue;
          expect(stmt.contains('catchError'), isTrue,
              reason: 'bare ${m.group(0)} at offset ${m.start} in ${entry.key} '
                  'rejects async into the zone on a revoked surface — add '
                  '.catchError((Object _) {})');
        }
      });
    }
  });

  group('driver_trip_accept setCamera handles the rejection', () {
    final src =
        File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();

    test('every unawaited ctrl.setCamera carries catchError', () {
      final bare = RegExp(r'[^.\w]ctrl\.setCamera\(');
      for (final m in bare.allMatches(src)) {
        final stmt = statementOf(src, m.start);
        if (stmt.contains('await ')) continue;
        expect(stmt.contains('catchError'), isTrue,
            reason: 'bare ctrl.setCamera at offset ${m.start} rejects async '
                'on a dead surface — add .catchError((Object _) {})');
      }
    });
  });

  group('_resetCinematic stops are crash-proof', () {
    final src = File('lib/screens/ride_request_map.dart').readAsStringSync();

    test('every controller stop() runs inside try/catch', () {
      final at = src.indexOf('void _resetCinematic() {');
      expect(at, isNonNegative, reason: '_resetCinematic not found');
      final body = src.substring(at, at + 1200);
      final stops = RegExp(r'(_\w+(?:Ctrl|Ticker))\?\.stop\(\);');
      for (final m in stops.allMatches(body)) {
        final before = body.substring(0, m.start);
        final lineStart = before.lastIndexOf('\n') + 1;
        final prefix = before.substring(lineStart);
        expect(prefix.contains('try'), isTrue,
            reason: '${m.group(1)}?.stop() is not wrapped — a disposed '
                'controller throws on stop() (null check crash)');
      }
    });
  });
}
