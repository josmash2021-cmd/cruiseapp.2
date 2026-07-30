import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';


/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapCar — Gestión del icono del carro del conductor
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapCar {
  TrackingMapCar({
    required this.map,
    required mapbox.PointAnnotationManager? carAnnotMgr,
  }) : _carAnnotMgr = carAnnotMgr;

  final mapbox.MapboxMap map;
  mapbox.PointAnnotationManager? _carAnnotMgr;

  mapbox.PointAnnotation? _carAnnot;
  Uint8List? _carPngBytes;
  bool _carAnnotCreating = false;
  bool _carPopDone = false;

  /// Pop-in animation timer. Held so [clear] can cancel it — see
  /// [_animateCarPopIn].
  Timer? _popInTimer;

  // ── Latest-wins write pipeline ───────────────────────────────────────
  //
  // Moving the car used to be a fixed 33 ms timer (30 fps hard ceiling)
  // firing writes with no backpressure — the worst of both: it could
  // never go faster on a good device, and on a slow one the writes still
  // piled into the platform channel where Mapbox drops them mid-flight
  // (project rule 25). Dropped flushes ARE the stutter the old comment
  // blamed on awaiting.
  //
  // Instead: at most ONE write in flight, and the newest position always
  // wins. A fast channel runs at the ticker's own 60 fps; a slow one
  // self-throttles and still renders the FRESHEST position rather than a
  // stale queued one.
  bool _writeInFlight = false;
  LatLng? _pendingPos;
  double? _pendingBearing;

  LatLng _driverPos = const LatLng(0, 0);
  final LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;

  final _kCarAnnotScale = 0.55;

  /// Carga el icono del carro según el tipo de viaje.
  ///
  /// Idempotent and safe to call from anywhere: [updatePosition] calls it
  /// itself when the bytes are missing. That matters because the only
  /// caller used to be a single `Future.delayed(500ms)` fired from
  /// initState — if the Mapbox map took longer than half a second to come
  /// up (cold start regularly takes 1–2 s) this object did not exist yet,
  /// the call was skipped, and nothing ever retried. `_carPngBytes` stayed
  /// null, every updatePosition bailed at the null check, and the rider
  /// watched an empty map for the whole trip. A timing race decided
  /// whether the car was visible at all.
  Future<void> loadCarIcon(String rideName) async {
    if (_carPngBytes != null || _iconLoading) return;
    _iconLoading = true;
    try {
      await _loadCarIconInner(rideName);
    } finally {
      _iconLoading = false;
    }
  }

  bool _iconLoading = false;

  Future<void> _loadCarIconInner(String rideName) async {
    final rideNameLower = rideName.toLowerCase();
    String carAsset;

    if (rideNameLower.contains('vip') || rideNameLower.contains('suv') ||
        rideNameLower.contains('suburban') || rideNameLower.contains('luxury')) {
      carAsset = 'assets/images/car_suv.png';
    } else if (rideNameLower.contains('sedan') || rideNameLower.contains('premium') ||
        rideNameLower.contains('fusion')) {
      carAsset = 'assets/images/car_sedan.png';
    } else {
      carAsset = 'assets/images/car_economy.png';
    }

    debugPrint('[TrackingMapCar] rideName="$rideNameLower" → asset=$carAsset');

    try {
      final raw = await rootBundle.load(carAsset);
      _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      debugPrint('[TrackingMapCar] loaded ${_carPngBytes!.length} PNG bytes');
    } catch (e) {
      debugPrint('[TrackingMapCar] FAILED to load $carAsset: $e');
      try {
        final raw = await rootBundle.load('assets/images/car_economy.png');
        _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      } catch (e) {
        debugPrint('[TrackingMapCar] Fallback car load failed: $e');
      }
    }
  }

  /// Actualiza el manager de anotaciones (útil cuando se recrea el mapa)
  void setAnnotManager(mapbox.PointAnnotationManager? mgr) {
    _carAnnotMgr = mgr;
    // Reset annotation since manager changed
    _carAnnot = null;
    _carAnnotCreating = false;
  }

  /// Actualiza la posición del carro en el mapa.
  ///
  /// [rideName] lets this self-heal: if the icon never loaded, it starts
  /// the load instead of silently doing nothing forever.
  Future<void> updatePosition(
    LatLng pos, {
    double bearing = 0,
    String? rideName,
  }) async {
    _driverPos = pos;
    _driverBearing = bearing;

    // Skip if no valid position
    if (pos.latitude == 0 && pos.longitude == 0) return;

    if (_carAnnotCreating) return;
    if (_carPngBytes == null) {
      // No icon yet — kick off the load (idempotent) and draw on a later
      // frame. Never just return and hope someone else loads it.
      if (rideName != null) unawaited(loadCarIcon(rideName));
      return;
    }

    final mgr = _carAnnotMgr;
    if (mgr == null) return;

    if (_carAnnot == null) {
      _carAnnotCreating = true;
      try {
        _carAnnot = await mgr.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            image: _carPngBytes,
            iconSize: _carPopDone ? _kCarAnnotScale : 0.01,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconRotate: bearing,
            iconOffset: [0, 0],
          ),
        );
        // Pop-in animation on first creation
        if (!_carPopDone) {
          _carPopDone = true;
          _animateCarPopIn(mgr);
        }
      } catch (e) {
        debugPrint('[TrackingMapCar] Failed to create car annotation: $e');
      } finally {
        _carAnnotCreating = false;
      }
    } else {
      // Hand the frame to the pipeline; it decides when it can go out.
      _pendingPos = pos;
      _pendingBearing = bearing;
      if (_writeInFlight) return; // in-flight write will pick up the newest
      _flushCarWrite(mgr);
    }
  }

  /// Send the newest pending car frame, then immediately send whatever
  /// arrived while it was travelling. Frames produced during a write are
  /// coalesced — only the last one is ever sent, so the marker can never
  /// fall behind the animation.
  void _flushCarWrite(mapbox.PointAnnotationManager mgr) {
    final pos = _pendingPos;
    final bearing = _pendingBearing;
    final annot = _carAnnot;
    if (pos == null || annot == null) return;
    _pendingPos = null;
    _pendingBearing = null;

    annot.geometry = mapbox.Point(
      coordinates: mapbox.Position(pos.longitude, pos.latitude),
    );
    if (bearing != null) annot.iconRotate = bearing;

    _writeInFlight = true;
    try {
      mgr.update(annot).then((_) {
        _writeInFlight = false;
        // A newer frame landed mid-write — send it now, no waiting for
        // the next tick.
        if (_pendingPos != null) _flushCarWrite(mgr);
      }).catchError((e) {
        debugPrint('[TrackingMapCar] Failed to update car annotation: $e');
        _writeInFlight = false;
        _carAnnot = null; // stale handle — recreated on the next position
      });
    } catch (e) {
      debugPrint('[TrackingMapCar] Failed to update car annotation: $e');
      _writeInFlight = false;
      _carAnnot = null;
    }
  }

  /// Pop-in animation for the car marker: 0.01 → 0.77 → 0.50 → 0.55 over 400ms
  void _animateCarPopIn(mapbox.PointAnnotationManager mgr) {
    if (_carAnnot == null) return;

    final startTime = DateTime.now();
    const durationMs = 400;

    // Held so clear() can kill it. Untracked, this timer outlived the
    // screen: leave tracking within 400 ms of the car appearing and it
    // kept firing mgr.update() against a map that was being torn down.
    _popInTimer?.cancel();
    _popInTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      // updatePosition() nulls _carAnnot when a write fails, so it can
      // vanish mid-animation.
      final annot = _carAnnot;
      if (annot == null) {
        timer.cancel();
        _popInTimer = null;
        return;
      }
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / durationMs).clamp(0.0, 1.0);

      double scale;
      if (t < 0.35) {
        scale = 0.01 + (_kCarAnnotScale * 1.4 - 0.01) * (t / 0.35);
      } else if (t < 0.65) {
        scale = _kCarAnnotScale * 1.4 + (_kCarAnnotScale * 0.9 - _kCarAnnotScale * 1.4) * ((t - 0.35) / 0.3);
      } else {
        scale = _kCarAnnotScale * 0.9 + (_kCarAnnotScale - _kCarAnnotScale * 0.9) * ((t - 0.65) / 0.35);
      }

      try {
        mgr.update(annot..iconSize = scale);
      } catch (_) {}

      if (t >= 1.0) {
        timer.cancel();
        _popInTimer = null;
      }
    });
  }

  /// Limpia la anotación del carro
  Future<void> clear() async {
    // Always first: the pop-in timer must die even when there is no
    // annotation left to delete, or it keeps ticking after teardown.
    _popInTimer?.cancel();
    _popInTimer = null;
    final mgr = _carAnnotMgr;
    if (mgr == null || _carAnnot == null) return;
    try {
      await mgr.delete(_carAnnot!);
      _carAnnot = null;
      _carPopDone = false;
    } catch (e) {
      debugPrint('[TrackingMapCar] Failed to delete car annotation: $e');
    }
  }

  /// Reset para cuando se destruye y recrea el mapa
  void reset() {
    _carAnnot = null;
    _carAnnotCreating = false;
    _carPopDone = false;
    // The hidden flag belonged to the annotation that just died with the
    // map surface. Left set, setHidden(true) would see nothing to do while
    // the freshly created annotation is fully opaque underneath the overlay
    // — two cars, a few frames apart. This happens on every style reload,
    // which is what iOS does when the rider comes back from another app.
    _hidden = false;
  }

  /// Redimensiona un PNG para usar como icono de mapa
  Future<Uint8List> _resizePngForMap(Uint8List pngBytes, {int maxDim = 160}) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;

    final scale = maxDim / math.max(img.width, img.height);
    final newW = (img.width * scale).round().clamp(1, maxDim);
    final newH = (img.height * scale).round().clamp(1, maxDim);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(newW, newH);
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    picture.dispose();
    img.dispose();
    return byteData!.buffer.asUint8List();
  }

  // Getters
  LatLng get driverPos => _driverPos;
  LatLng get animPos => _animPos;
  double get driverBearing => _driverBearing;
  bool get hasIcon => _carPngBytes != null;

  /// The rendered car, for anyone drawing it outside the map.
  ///
  /// While the chase camera holds the car at a fixed point of the screen it
  /// can be painted by Flutter instead of shipped over the platform channel
  /// — the channel is the reason the marker advances ten or fifteen times a
  /// second under a map rendering at sixty. Same bytes either way, so the
  /// two drawings are the same car.
  Uint8List? get carBytes => _carPngBytes;

  /// The scale the annotation settles at, so an overlay can match its size.
  double get carScale => _kCarAnnotScale;

  /// Hide or show the native annotation without destroying it.
  ///
  /// Kept alive and kept current underneath the overlay rather than deleted,
  /// so the instant the chase stops owning the screen it is already in the
  /// right place with nothing to rebuild.
  Future<void> setHidden(bool hidden) async {
    final annot = _carAnnot;
    final mgr = _carAnnotMgr;
    if (annot == null || mgr == null) return;
    if (_hidden == hidden) return;
    _hidden = hidden;
    try {
      annot.iconOpacity = hidden ? 0.0 : 1.0;
      await mgr.update(annot);
    } catch (_) {
      // Left to the next position write, which reasserts it.
    }
  }

  bool _hidden = false;
  bool get hasAnnotation => _carAnnot != null;
}
