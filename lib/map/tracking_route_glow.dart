import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// ═══════════════════════════════════════════════════════════════════
///  TrackingRouteGlow — light travelling along the rider's gold route
/// ═══════════════════════════════════════════════════════════════════
///
/// Owner design 2026-11-03: a soft, diffuse glow travels along the ACTIVE
/// gold route, over and over — before the pickup along the driver→pickup
/// approach line (car → pickup), after it along the remaining trip line
/// (car → destination). NOT a hard-edged dash (rejected: "un cuadrado
/// pasando"): a gradient, brightest in the middle (#FFFBEA core blending
/// into #FFE680) and fading smoothly to transparent on both sides over
/// ~18 % of the line, 2.4 s per pass, ease-in-out, then again from the
/// start. The gold line underneath is not touched.
///
/// How: the gold line is a PolylineAnnotation, which has no `line-progress`,
/// so the glow owns a GeoJSON source with `lineMetrics: true` carrying the
/// geometry the gold annotation shows, and a LineLayer placed right above
/// the gold line's layer (so below the pins and the car, which live in the
/// point managers on top of the style). Its `line-gradient` is an
/// `interpolate` over `line-progress` with a moving peak, advanced from a
/// vsync Ticker throttled to ~30 fps — one style write per frame, the
/// expression list being the only allocation.
///
/// Lifecycle (who owns what):
///   * [TrackingMapRoute] owns this and reports the line it has SETTLED on
///     screen (not while the progressive "water" draw is running).
///   * The rider screen gates it per frame by phase ([update]).
///   * It stops itself — no work — while the phase says no, while there is
///     no line (or a line too short to read as motion), while the app is in
///     the background, and for good when [isLive] turns false (map surface
///     revoked / screen gone): the map handle is dropped then.
///   * [reset] after a style reload (source and layer died with the style;
///     recreated on the next pass), [dispose] when the route component is
///     replaced or the screen goes away.

/// One pass, start of the line to its end.
const int kRouteGlowPassMs = 2400;

/// Half of the bright band, as a fraction of the glowing line's length —
/// the whole band (fully transparent edge to edge) is 18 % of the line.
const double kRouteGlowHalfWidth = 0.09;

/// Gradient writes are throttled to this — ~30 fps, never per vsync.
const int kRouteGlowFrameMs = 33;

/// The glow geometry follows the trimmed gold line at most this often.
/// The gold line itself is trimmed at 15 fps; mirroring every trim would
/// double the GeoJSON traffic for a shift nobody can see inside an 18 %
/// band (between pushes the car moves a few metres).
const int kRouteGlowGeometryMs = 500;

/// Below this the remaining line is too short for a pass to read as light
/// travelling — it would only blink at the car. The glow rests.
const double kRouteGlowMinLineM = 40;

const String kRouteGlowSourceId = 'rider-route-glow-src';
const String kRouteGlowLayerId = 'rider-route-glow';

/// Core of the glow (centre of the band) and its outer warm gold.
const int kRouteGlowCoreColor = 0xFFFFFBEA;
const int kRouteGlowOuterColor = 0xFFFFE680;

/// Peak opacity at the centre of the band (before the layer's own blur).
const double _kPeakAlpha = 0.95;

/// Stops on each side of the peak: 5 → 11 stops, every 0.2 half-widths.
const int _kBandStops = 5;

/// Colour lookup resolution across one half-width (multiple of
/// [_kBandStops] so every regular stop hits an exact entry).
const int _kLutSteps = 60;

/// Stops closer than this to 0 or 1 are dropped — the explicit 0.0 / 1.0
/// stops carry the value there, and interpolate stops must be strictly
/// ascending.
const double _kEdgeEps = 1e-4;

const List<Object> _kLinear = ['linear'];
const List<Object> _kLineProgress = ['line-progress'];

/// The band's colour at normalized distance [x] from the peak
/// (0 = centre, 1 = edge of the band). Alpha follows cos² — zero slope at
/// the centre and at the edges, so there is no visible corner anywhere and
/// no hard end (the "square" the owner rejected). The hue goes from the
/// warm-white core to the outer gold; the transparent edge keeps the gold
/// hue (never transparent BLACK, which would darken the fade).
String _glowColorAt(double x) {
  final ax = x.abs().clamp(0.0, 1.0);
  final c = math.cos(math.pi * ax / 2);
  final alpha = ax >= 1.0 ? 0.0 : _kPeakAlpha * c * c;
  // Core → outer hue over the inner 60 % of the half-width (smoothstep).
  final s = (ax / 0.6).clamp(0.0, 1.0);
  final m = s * s * (3 - 2 * s);
  int ch(int shift) {
    final a = (kRouteGlowCoreColor >> shift) & 0xFF;
    final b = (kRouteGlowOuterColor >> shift) & 0xFF;
    return (a + (b - a) * m).round();
  }

  return 'rgba(${ch(16)},${ch(8)},${ch(0)},${alpha.toStringAsFixed(3)})';
}

/// Precomputed once: the per-frame expression reuses these strings.
final List<String> _kGlowLut = List<String>.unmodifiable(
  List<String>.generate(_kLutSteps + 1, (i) => _glowColorAt(i / _kLutSteps)),
);

String _lutAt(double x) {
  final ax = x.abs();
  if (ax >= 1.0) return _kGlowLut[_kLutSteps];
  return _kGlowLut[(ax * _kLutSteps).round()];
}

/// Peak position (in `line-progress` units) at pass progress [t] ∈ [0, 1].
///
/// Ease-in-out (sine). The peak starts one half-width BEFORE the line and
/// ends one half-width past it, so each pass fades in at the car and fades
/// out at the pin — and the restart is invisible, never a jump.
double routeGlowPeak(double t) {
  final tt = t.clamp(0.0, 1.0);
  final eased = 0.5 - 0.5 * math.cos(math.pi * tt);
  return -kRouteGlowHalfWidth + (1 + 2 * kRouteGlowHalfWidth) * eased;
}

/// `line-gradient` for a band centred at [peak]:
/// `['interpolate', ['linear'], ['line-progress'], 0, c0, …, 1, c1]`.
///
/// Stops are kept inside [0, 1] and strictly ascending; where the band is
/// cut by an end of the line, the 0.0 / 1.0 stop carries the band's colour
/// at that point so the cut is exact.
List<Object> routeGlowGradient(double peak) {
  const h = kRouteGlowHalfWidth;
  final out = <Object>[
    'interpolate',
    _kLinear,
    _kLineProgress,
    0.0,
    _lutAt((0.0 - peak) / h),
  ];
  for (var k = -_kBandStops; k <= _kBandStops; k++) {
    final pos = peak + k * h / _kBandStops;
    if (pos <= _kEdgeEps || pos >= 1.0 - _kEdgeEps) continue;
    out
      ..add(pos)
      ..add(_kGlowLut[(k.abs() * _kLutSteps) ~/ _kBandStops]);
  }
  out
    ..add(1.0)
    ..add(_lutAt((1.0 - peak) / h));
  return out;
}

/// A fully transparent gradient — what the layer holds while hidden, so a
/// stale band can never flash for a frame when it is shown again.
List<Object> routeGlowTransparentGradient() =>
    routeGlowGradient(-2 * kRouteGlowHalfWidth);

class TrackingRouteGlow with WidgetsBindingObserver {
  TrackingRouteGlow({
    required mapbox.MapboxMap map,
    required TickerProvider vsync,
    required bool Function() isLive,
    required List<mapbox.Position>? Function() line,
    required String? Function() anchorLayerId,
  })  : _map = map,
        _vsync = vsync,
        _isLive = isLive,
        _line = line,
        _anchorLayerId = anchorLayerId {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Nulled on [dispose] — no late continuation can write into a map this
  /// glow no longer belongs to.
  mapbox.MapboxMap? _map;
  final TickerProvider _vsync;

  /// `mounted && identical(screen._map, thisMap)` — false once the surface
  /// is revoked (the screen nulls `_map`) or the screen is gone.
  final bool Function() _isLive;

  /// The line the gold annotation shows right now, or null when there is
  /// none settled (being drawn, swapped, cleared).
  final List<mapbox.Position>? Function() _line;

  /// Layer id of the gold line's PolylineAnnotationManager.
  final String? Function() _anchorLayerId;

  Ticker? _ticker;
  bool _disposed = false;

  /// The phase rule's verdict, last frame.
  bool _wanted = false;

  /// App in the background — the ticker is stopped until it resumes.
  bool _suspended = false;

  /// Bumped by [reset]/[dispose]: async results that belong to an older
  /// style (or a dead glow) are dropped instead of flipping flags.
  int _gen = 0;

  bool _layerReady = false;
  bool _creating = false;

  /// Whether the layer is currently `visibility: visible`.
  bool _shown = false;

  /// A gradient write is still crossing the platform channel — skip the
  /// frame rather than queue writes behind it.
  bool _writeBusy = false;
  bool _pushBusy = false;

  /// What the source holds: identity of the list plus a cheap fingerprint
  /// (the erase rebuilds the list every 66 ms even with the car parked).
  List<mapbox.Position>? _pushedLine;
  int _pushedLen = -1;
  double _pushedLng = double.nan;
  double _pushedLat = double.nan;

  int _passStartMs = -1;
  int _lastWriteMs = -1000000;
  int _lastPushMs = -1000000;

  /// Wall clock for the retry throttles (start / create), which run outside
  /// the ticker.
  final Stopwatch _clock = Stopwatch()..start();
  int _nextStartTryMs = 0;
  int _nextCreateTryMs = 0;

  bool get isRunning => _ticker?.isActive ?? false;
  bool get isDisposed => _disposed;

  /// Per frame from the rider screen: [allowed] is the phase rule (approach
  /// line before the pickup, trip line after it). Cheap when nothing
  /// changes; starts the ticker when everything lines up (re-checked at
  /// most twice a second while waiting).
  void update({required bool allowed}) {
    if (_disposed) return;
    if (!_isLive()) {
      // Surface revoked or screen gone: never touch that map again.
      dispose();
      return;
    }
    if (!allowed) {
      if (_wanted) {
        _wanted = false;
        _halt();
      }
      return;
    }
    _wanted = true;
    if (_suspended || isRunning) return;
    final now = _clock.elapsedMilliseconds;
    if (now < _nextStartTryMs) return;
    _nextStartTryMs = now + 500;
    final line = _line();
    if (line == null || !_atLeastMeters(line, kRouteGlowMinLineM)) return;
    _start();
  }

  /// The gold line was REPLACED (re-route cross-fade): follow it on the
  /// next frame instead of at the next geometry slot.
  void lineReplaced() {
    _lastPushMs = -1000000;
    _pushedLen = -1;
  }

  /// Style reloaded: the source and the layer died with the old style.
  /// Flags only — nothing to remove; the next pass recreates them.
  void reset() {
    _gen++;
    _ticker?.stop();
    _layerReady = false;
    _creating = false;
    _shown = false;
    _writeBusy = false;
    _pushBusy = false;
    _pushedLine = null;
    _pushedLen = -1;
    _passStartMs = -1;
    _nextCreateTryMs = 0;
    _nextStartTryMs = 0;
  }

  /// Stops and disposes the ticker, unregisters the lifecycle observer and
  /// drops the map handle. With [hide], a glow that is on screen and whose
  /// map is still live is hidden first (the trip is being cleaned up, the
  /// map stays). Synchronous: safe to call from the screen's dispose()
  /// before `super.dispose()` (TickerProviderStateMixin asserts no ticker
  /// is still active there).
  void dispose({bool hide = false}) {
    if (_disposed) return;
    final m = _map;
    if (hide && _shown && m != null && _isLive()) {
      unawaited(m.style
          .setStyleLayerProperty(kRouteGlowLayerId, 'visibility', 'none')
          .catchError((Object _) {}));
    }
    _disposed = true;
    _gen++;
    _ticker?.dispose();
    _ticker = null;
    _map = null;
    _shown = false;
    _layerReady = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      // update() restarts it on the next frame.
      _suspended = false;
      _nextStartTryMs = 0;
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _suspended = true;
      _ticker?.stop();
      _passStartMs = -1;
    }
  }

  // ── internals ──

  void _start() {
    final t = _ticker ??= _vsync.createTicker(_onTick);
    // A fresh Ticker run restarts `elapsed` at zero.
    _passStartMs = -1;
    _lastWriteMs = -1000000;
    if (!t.isActive) t.start();
  }

  /// Stop the ticker and hide the band. Used for every "not now".
  void _halt() {
    _ticker?.stop();
    _passStartMs = -1;
    if (_shown) {
      _shown = false;
      unawaited(_hide());
    }
  }

  void _onTick(Duration elapsed) {
    if (_disposed) return;
    if (!_isLive()) {
      dispose();
      return;
    }
    final line = _line();
    if (line == null) {
      _halt();
      return;
    }
    if (!_layerReady) {
      unawaited(_ensureLayer(line));
      return;
    }
    final ms = elapsed.inMilliseconds;
    if (_writeBusy || ms - _lastWriteMs < kRouteGlowFrameMs) return;

    if (_passStartMs < 0 || ms - _passStartMs >= kRouteGlowPassMs) {
      // New pass — the line has been trimmed behind the car since the
      // last one; rest when what is left is too short to travel along.
      if (!_atLeastMeters(line, kRouteGlowMinLineM)) {
        _halt();
        return;
      }
      _passStartMs = ms;
      _maybePush(line, ms, force: true);
      if (!_shown) _show();
    } else {
      _maybePush(line, ms, force: false);
    }

    _lastWriteMs = ms;
    _writeGradient(
        routeGlowGradient(routeGlowPeak((ms - _passStartMs) / kRouteGlowPassMs)));
  }

  /// Keep the glow on the geometry the gold annotation shows: the approach
  /// and the trip line are trimmed behind the car, re-routes splice them.
  void _maybePush(List<mapbox.Position> line, int ms, {required bool force}) {
    if (_pushBusy) return;
    if (identical(line, _pushedLine)) return;
    if (!force && ms - _lastPushMs < kRouteGlowGeometryMs) return;
    final first = line.isEmpty ? null : line.first;
    final fLng = first?.lng.toDouble() ?? double.nan;
    final fLat = first?.lat.toDouble() ?? double.nan;
    if (line.length == _pushedLen && fLng == _pushedLng && fLat == _pushedLat) {
      // Same geometry rebuilt (car parked) — nothing to send.
      _pushedLine = line;
      return;
    }
    final m = _map;
    if (m == null) return;
    final gen = _gen;
    _pushBusy = true;
    _lastPushMs = ms;
    _pushedLine = line;
    _pushedLen = line.length;
    _pushedLng = fLng;
    _pushedLat = fLat;
    m.style
        .setStyleSourceProperty(kRouteGlowSourceId, 'data', _lineJson(line))
        .catchError((Object e) {
      if (gen != _gen) return;
      debugPrint('[TrackingRouteGlow] geometry push failed: $e');
      // Source gone (style swapped under us): rebuild on the next tick.
      _pushedLine = null;
      _pushedLen = -1;
      _layerReady = false;
    }).whenComplete(() {
      if (gen == _gen) _pushBusy = false;
    });
  }

  void _writeGradient(List<Object> expr) {
    final m = _map;
    if (m == null) return;
    final gen = _gen;
    _writeBusy = true;
    m.style
        .setStyleLayerProperty(kRouteGlowLayerId, 'line-gradient', expr)
        .catchError((Object e) {
      if (gen != _gen) return;
      debugPrint('[TrackingRouteGlow] gradient write failed: $e');
      _layerReady = false;
    }).whenComplete(() {
      if (gen == _gen) _writeBusy = false;
    });
  }

  /// Transparent first, visible second — the channel is FIFO, so whatever
  /// band the layer held when it was hidden never shows for a frame.
  void _show() {
    final m = _map;
    if (m == null) return;
    _shown = true;
    final style = m.style;
    unawaited(style
        .setStyleLayerProperty(
            kRouteGlowLayerId, 'line-gradient', routeGlowTransparentGradient())
        .catchError((Object _) {}));
    unawaited(style
        .setStyleLayerProperty(kRouteGlowLayerId, 'visibility', 'visible')
        .catchError((Object _) {}));
  }

  /// Hiding has to land (a frozen band on a line that moved on is worse
  /// than no glow), so one retry. A failure usually means the layer is
  /// already gone with its style — nothing left to hide then.
  Future<void> _hide() async {
    final gen = _gen;
    for (var attempt = 0; attempt < 2; attempt++) {
      final m = _map;
      if (m == null || gen != _gen || _shown) return;
      try {
        await m.style
            .setStyleLayerProperty(kRouteGlowLayerId, 'visibility', 'none');
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  Future<void> _ensureLayer(List<mapbox.Position> line) async {
    if (_creating || _disposed) return;
    if (_clock.elapsedMilliseconds < _nextCreateTryMs) return;
    final m = _map;
    if (m == null) return;
    _creating = true;
    final gen = _gen;
    final style = m.style;
    try {
      final json = _lineJson(line);
      if (await style.styleSourceExists(kRouteGlowSourceId)) {
        await style.setStyleSourceProperty(kRouteGlowSourceId, 'data', json);
      } else {
        await style.addSource(mapbox.GeoJsonSource(
          id: kRouteGlowSourceId,
          data: json,
          // What makes `line-progress` exist at all.
          lineMetrics: true,
        ));
      }
      if (gen != _gen || _disposed) return;
      if (!await style.styleLayerExists(kRouteGlowLayerId)) {
        if (gen != _gen || _disposed) return;
        // Right above the gold line = below 'road-label' with it, and
        // below the pin/car managers, which sit on top of the style.
        final anchor = _anchorLayerId();
        var placed = false;
        if (anchor != null) {
          try {
            await style.addLayerAt(
                _buildLayer(), mapbox.LayerPosition(above: anchor));
            placed = true;
          } catch (_) {}
        }
        if (!placed) {
          await style.addLayerAt(
              _buildLayer(), mapbox.LayerPosition(below: 'road-label'));
        }
      }
      if (gen != _gen || _disposed) return;
      _pushedLine = line;
      _pushedLen = line.length;
      _pushedLng = line.isEmpty ? double.nan : line.first.lng.toDouble();
      _pushedLat = line.isEmpty ? double.nan : line.first.lat.toDouble();
      _layerReady = true;
      // Created hidden; the first pass shows it (transparent first).
      _shown = false;
    } catch (e) {
      if (gen == _gen) {
        debugPrint('[TrackingRouteGlow] layer create failed: $e');
        _nextCreateTryMs = _clock.elapsedMilliseconds + 2000;
      }
    } finally {
      if (gen == _gen) _creating = false;
    }
  }

  mapbox.LineLayer _buildLayer() => mapbox.LineLayer(
        id: kRouteGlowLayerId,
        sourceId: kRouteGlowSourceId,
        visibility: mapbox.Visibility.NONE,
        lineCap: mapbox.LineCap.ROUND,
        lineJoin: mapbox.LineJoin.ROUND,
        // Wider than the 4 px gold line and heavily blurred: a soft halo
        // whose brightest part sits on the line, never a hard-edged stroke.
        lineWidth: 12.0,
        lineBlur: 7.0,
        lineGradientExpression: routeGlowTransparentGradient(),
      );

  static String _lineJson(List<mapbox.Position> coords) {
    final b = StringBuffer(
        '{"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[');
    var first = true;
    for (final p in coords) {
      final lng = p.lng.toDouble();
      final lat = p.lat.toDouble();
      if (!lng.isFinite || !lat.isFinite) continue;
      if (!first) b.write(',');
      first = false;
      b
        ..write('[')
        ..write(lng)
        ..write(',')
        ..write(lat)
        ..write(']');
    }
    b.write(']}}');
    return b.toString();
  }

  /// Whether [coords] runs at least [meters] (stops counting once it does).
  static bool _atLeastMeters(List<mapbox.Position> coords, double meters) {
    var sum = 0.0;
    for (var i = 1; i < coords.length; i++) {
      final lat0 = coords[i - 1].lat.toDouble();
      final dLat = (coords[i].lat.toDouble() - lat0) * 111320.0;
      final dLng = (coords[i].lng.toDouble() - coords[i - 1].lng.toDouble()) *
          111320.0 *
          math.cos(lat0 * math.pi / 180);
      sum += math.sqrt(dLat * dLat + dLng * dLng);
      if (sum >= meters) return true;
    }
    return false;
  }
}
