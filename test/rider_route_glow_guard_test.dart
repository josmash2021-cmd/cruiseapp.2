import 'dart:io';

import 'package:cruise_app/map/tracking_route_glow.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardian for the glow that travels along the rider's active gold route
/// (owner design 2026-11-03): before the pickup along the driver→pickup
/// approach line, after it along the remaining trip line; a soft gradient
/// (warm-white #FFFBEA core into #FFE680, transparent on both sides, ~18 %
/// of the line) — NOT a hard-edged dash ("un cuadrado pasando" was
/// rejected) — 2.4 s per pass, ease-in-out, looping.
///
/// The map needs a live Mapbox surface, so the pure pieces (the gradient
/// expression and the peak curve) are tested for real and the wiring is
/// pinned at source level.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  /// Body of the first declaration matching [head], up to [maxLen] chars.
  String bodyOf(String src, String head, {int maxLen = 2000}) {
    final at = src.indexOf(head);
    expect(at, isNonNegative, reason: 'missing: $head');
    return src.substring(at, (at + maxLen).clamp(0, src.length));
  }

  double alphaOf(Object color) {
    final m = RegExp(r'rgba\((\d+),(\d+),(\d+),([\d.]+)\)')
        .firstMatch(color as String)!;
    return double.parse(m.group(4)!);
  }

  group('gradient expression (pure)', () {
    test('interpolate over line-progress, stops strictly ascending in [0,1]',
        () {
      for (var t = 0.0; t <= 1.0001; t += 0.02) {
        final expr = routeGlowGradient(routeGlowPeak(t));
        expect(expr[0], 'interpolate');
        expect(expr[1], ['linear']);
        expect(expr[2], ['line-progress']);
        final stops = <double>[];
        for (var i = 3; i < expr.length; i += 2) {
          stops.add(expr[i] as double);
          expect(expr[i + 1], isA<String>());
        }
        expect(stops.first, 0.0);
        expect(stops.last, 1.0);
        for (var i = 1; i < stops.length; i++) {
          expect(stops[i], greaterThan(stops[i - 1]),
              reason: 'interpolate stops must be strictly ascending (t=$t)');
        }
      }
    });

    test('a soft band: brightest in the middle, transparent at both sides',
        () {
      final expr = routeGlowGradient(0.5);
      final pos = <double>[];
      final alpha = <double>[];
      for (var i = 3; i < expr.length; i += 2) {
        pos.add(expr[i] as double);
        alpha.add(alphaOf(expr[i + 1]));
      }
      final peakIdx = alpha.indexOf(alpha.reduce((a, b) => a > b ? a : b));
      expect(pos[peakIdx], closeTo(0.5, 1e-9));
      // Monotonic fade on both sides — no plateau, no hard step.
      for (var i = 1; i <= peakIdx; i++) {
        expect(alpha[i], greaterThanOrEqualTo(alpha[i - 1]));
      }
      for (var i = peakIdx + 1; i < alpha.length; i++) {
        expect(alpha[i], lessThanOrEqualTo(alpha[i - 1]));
      }
      // At least 9 stops across the band: a gradient, never a dash.
      final lit = [for (var i = 0; i < pos.length; i++) if (alpha[i] > 0) i];
      expect(lit.length, greaterThanOrEqualTo(9));
      // Fully transparent outside the band; the band is 15–20 % wide.
      final firstClear = pos[lit.first - 1];
      final lastClear = pos[lit.last + 1];
      expect(lastClear - firstClear, inInclusiveRange(0.15, 0.20));
      expect(alpha.first, 0.0);
      expect(alpha.last, 0.0);
    });

    test('warm-white core into #FFE680; the fade never goes through black',
        () {
      final expr = routeGlowGradient(0.5);
      final colors = [for (var i = 4; i < expr.length; i += 2) expr[i] as String];
      expect(colors, contains(startsWith('rgba(255,251,234,'))); // #FFFBEA
      expect(colors, contains(startsWith('rgba(255,230,128,'))); // #FFE680
      for (final c in colors) {
        expect(c.startsWith('rgba(0,0,0'), isFalse,
            reason: 'transparent black darkens the fade');
      }
    });

    test('each pass enters before the line and leaves past it, ease-in-out',
        () {
      expect(routeGlowPeak(0), closeTo(-kRouteGlowHalfWidth, 1e-9));
      expect(routeGlowPeak(1), closeTo(1 + kRouteGlowHalfWidth, 1e-9));
      // Nothing visible at the loop seam — the restart is not a jump.
      for (final t in [0.0, 1.0]) {
        final e = routeGlowGradient(routeGlowPeak(t));
        for (var i = 4; i < e.length; i += 2) {
          expect(alphaOf(e[i]), lessThan(0.01));
        }
      }
      // Slow – fast – slow, symmetric.
      final a = routeGlowPeak(0.1) - routeGlowPeak(0.0);
      final b = routeGlowPeak(0.55) - routeGlowPeak(0.45);
      final c = routeGlowPeak(1.0) - routeGlowPeak(0.9);
      expect(b, greaterThan(a * 3));
      expect(a, closeTo(c, 1e-9));
    });

    test('timing constants: ~2.4 s per pass, ≤30 fps writes', () {
      expect(kRouteGlowPassMs, 2400);
      expect(kRouteGlowFrameMs, greaterThanOrEqualTo(33));
      expect(kRouteGlowHalfWidth * 2, inInclusiveRange(0.15, 0.20));
      expect(kRouteGlowCoreColor, 0xFFFFFBEA);
      expect(kRouteGlowOuterColor, 0xFFFFE680);
    });
  });

  group('glow component (source)', () {
    final glow = read('lib/map/tracking_route_glow.dart');

    test('own GeoJSON source with lineMetrics + a line-gradient layer', () {
      expect(glow, contains('lineMetrics: true'));
      expect(glow, contains("'line-gradient'"));
      expect(glow, contains("['line-progress']"));
      expect(glow, contains('lineGradientExpression:'));
      // Above the gold line's layer (so below the pin/car managers).
      expect(glow, contains('LayerPosition(above: anchor)'));
    });

    test('one throttled write per frame, never stacked behind a pending one',
        () {
      final tick = bodyOf(glow, 'void _onTick(Duration elapsed) {');
      expect(tick, contains('_writeBusy'));
      expect(tick, contains('kRouteGlowFrameMs'));
      expect(tick, contains('kRouteGlowPassMs'));
    });

    test('the ticker is disposed, the observer removed, the map dropped', () {
      final dispose = bodyOf(glow, 'void dispose({bool hide = false}) {');
      expect(dispose, contains('_ticker?.dispose();'));
      expect(dispose, contains('_ticker = null;'));
      expect(dispose, contains('removeObserver(this)'));
      expect(dispose, contains('_map = null;'));
      expect(glow, contains('WidgetsBinding.instance.addObserver(this)'));
    });

    test('stops when the surface dies, in background, and when idle', () {
      final tick = bodyOf(glow, 'void _onTick(Duration elapsed) {');
      expect(tick, contains('if (!_isLive())'));
      expect(tick, contains('_halt();'));
      final upd = bodyOf(glow, 'void update({required bool allowed}) {');
      expect(upd, contains('if (!_isLive())'));
      expect(upd, contains('_suspended'));
      final life = bodyOf(glow, 'void didChangeAppLifecycleState(');
      expect(life, contains('AppLifecycleState.paused'));
      expect(life, contains('_ticker?.stop();'));
    });

    test('style reload drops the handles; the layer is rebuilt later', () {
      final reset = bodyOf(glow, 'void reset() {', maxLen: 600);
      expect(reset, contains('_layerReady = false;'));
      expect(reset, contains('_gen++;'));
    });
  });

  group('wiring', () {
    final route = read('lib/map/tracking_map_route.dart');
    final view = read('lib/widgets/tracking/tracking_map_view.dart');
    final ctrl = read('lib/controllers/rider_tracking_controller.dart');

    test('the glow follows exactly what the gold line shows', () {
      // Settled only when the progressive draw lands, never mid-draw.
      final draw = bodyOf(route, 'void startAnimatedRouteDraw(', maxLen: 4500);
      final unsettle = draw.indexOf('_lineSettled = false;');
      final settle = draw.indexOf('_lineSettled = true;');
      expect(unsettle, isNonNegative);
      expect(settle, greaterThan(unsettle));
      // Trimmed behind the car → the glow geometry follows.
      expect(bodyOf(route, 'Future<void> eraseRouteBehindCar(', maxLen: 2800),
          contains('_drawnCoords = validRemaining;'));
      // Re-route splice.
      expect(bodyOf(route, 'Future<void> crossFadeTo(', maxLen: 3500),
          contains('_glow?.lineReplaced();'));
      // Route swap that will be redrawn (approach → trip at pickup).
      expect(bodyOf(route, 'void setActiveRoute(', maxLen: 500),
          contains('_lineSettled = false;'));
      // Style reload.
      expect(bodyOf(route, 'void reset() {', maxLen: 600),
          contains('_glow?.reset();'));
    });

    test('both phases: approach before pickup, trip line after', () {
      final rule = bodyOf(view, 'bool _routeGlowAllowed() {', maxLen: 600);
      expect(rule, contains('_TrackPhase.onTrip'));
      expect(rule, contains('_TrackPhase.nearDestination'));
      expect(rule, contains('_TrackPhase.arriving'));
      expect(rule, contains('_TrackPhase.arrived'));
      expect(rule, contains('_approachRouteFetched'));
      expect(rule, contains('identical(_routePts, _tripRoutePts)'));
      final sync = bodyOf(view, 'void _syncRouteGlow() {', maxLen: 200);
      expect(sync, contains('if (kIsWeb) return;'));
      expect(ctrl, contains('_syncRouteGlow();'));
      final interp = bodyOf(ctrl, 'void _interpolate(Duration elapsed) {',
          maxLen: 3000);
      expect(interp, contains('_syncRouteGlow();'));
    });

    test('attached per map, live only while that map is the screen map', () {
      final created = bodyOf(view, 'onMapCreated: (ctrl) async {',
          maxLen: 5000);
      final dispose = created.indexOf('_mapRoute?.disposeGlow();');
      final make = created.indexOf('_mapRoute = TrackingMapRoute(');
      final attach = created.indexOf('_mapRoute!.attachGlow(');
      expect(dispose, isNonNegative);
      expect(make, greaterThan(dispose));
      expect(attach, greaterThan(make));
      expect(created, contains('identical(_map, ctrl)'));
    });

    test('screen dispose stops the glow ticker before super.dispose()', () {
      // dispose() calls _cleanupMapAnnotations() unawaited, right before
      // super.dispose(): only its synchronous prefix runs in time, so the
      // glow must go before the first await.
      final clean = bodyOf(view, 'Future<void> _cleanupMapAnnotations() async {',
          maxLen: 1200);
      final glow = clean.indexOf('_mapRoute?.disposeGlow();');
      final firstAwait = clean.indexOf('await ');
      expect(glow, isNonNegative);
      expect(glow, lessThan(firstAwait));
    });
  });
}
