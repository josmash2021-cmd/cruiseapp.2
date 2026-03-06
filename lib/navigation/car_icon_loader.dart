import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Compact 3D top-down car with closed roof, detailed doors,
/// properly placed lights, and strong shadows.
class _CarPalette {
  final Color body;
  final List<Color> barrelGrad;
  final List<Color> roofGrad;
  final Color outline;
  final Color mirrorBody;
  final Color mirrorArm;
  final Color bumperAccent;
  final Color crease;
  final Color fenderHighlight;
  final Color beltHighlight;
  final Color handleFill;
  const _CarPalette({
    required this.body,
    required this.barrelGrad,
    required this.roofGrad,
    required this.outline,
    required this.mirrorBody,
    required this.mirrorArm,
    required this.bumperAccent,
    required this.crease,
    required this.fenderHighlight,
    required this.beltHighlight,
    required this.handleFill,
  });

  static const whitePearl = _CarPalette(
    body: Color(0xFFE8EBF0),
    barrelGrad: [
      Color(0xFFAEB4BC),
      Color(0xFFC8CDD4),
      Color(0xFFE2E6EC),
      Color(0xFFF0F3F8),
      Color(0xFFE2E6EC),
      Color(0xFFC8CDD4),
      Color(0xFFAEB4BC),
    ],
    roofGrad: [
      Color(0xFFCCD0D8),
      Color(0xFFDEE2E8),
      Color(0xFFF0F3F8),
      Color(0xFFDEE2E8),
      Color(0xFFCCD0D8),
    ],
    outline: Color(0x30707070),
    mirrorBody: Color(0xFFDADEE4),
    mirrorArm: Color(0xFFD0D4DA),
    bumperAccent: Color(0xFFC0C5CC),
    crease: Color(0x12FFFFFF),
    fenderHighlight: Color(0x20FFFFFF),
    beltHighlight: Color(0x20FFFFFF),
    handleFill: Color(0x50FFFFFF),
  );

  static const black = _CarPalette(
    body: Color(0xFF1A1C20),
    barrelGrad: [
      Color(0xFF0E0F12),
      Color(0xFF1A1C20),
      Color(0xFF252830),
      Color(0xFF2E3038),
      Color(0xFF252830),
      Color(0xFF1A1C20),
      Color(0xFF0E0F12),
    ],
    roofGrad: [
      Color(0xFF141618),
      Color(0xFF1E2024),
      Color(0xFF282A30),
      Color(0xFF1E2024),
      Color(0xFF141618),
    ],
    outline: Color(0x40404040),
    mirrorBody: Color(0xFF2A2C32),
    mirrorArm: Color(0xFF222428),
    bumperAccent: Color(0xFF2A2E34),
    crease: Color(0x18FFFFFF),
    fenderHighlight: Color(0x14FFFFFF),
    beltHighlight: Color(0x14FFFFFF),
    handleFill: Color(0x30FFFFFF),
  );
}

class CarIconLoader {
  CarIconLoader._();

  static final Map<String, BitmapDescriptor> _cache = {};
  // Raw PNG bytes cache — used by Apple Maps on iOS (BitmapDescriptor is opaque).
  static final Map<String, Uint8List> _bytesCache = {};

  static Future<BitmapDescriptor> load() => loadUber();

  static Future<BitmapDescriptor> loadUber() async {
    if (_cache.containsKey('white')) return _cache['white']!;
    // Use the Google Maps–style nav car for the driver marker on both platforms.
    final bytes = await loadUberBytes();
    // ignore: deprecated_member_use
    final descriptor = BitmapDescriptor.fromBytes(bytes!);
    _cache['white'] = descriptor;
    return descriptor;
  }

  static Future<BitmapDescriptor> loadForVehicle(String rideName) =>
      loadForRide(rideName);

  static Future<BitmapDescriptor> loadForRide(String rideName) async {
    final key = rideName.trim().toLowerCase();
    if (key.contains('suburba')) {
      const cacheKey = 'suv_black';
      if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;
      _cache[cacheKey] = await _renderSuv(_CarPalette.black);
      return _cache[cacheKey]!;
    }
    final palette = key.contains('fusion')
        ? _CarPalette.black
        : _CarPalette.whitePearl;
    final cacheKey = key.contains('fusion') ? 'black' : 'white';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;
    _cache[cacheKey] = await _render(palette);
    return _cache[cacheKey]!;
  }

  static Future<BitmapDescriptor> loadDriverIcon() => loadUber();

  /// Returns raw PNG bytes for the uber (white sedan) icon.
  /// Used by apple_maps_flutter on iOS to create BitmapDescriptor.
  static Future<Uint8List?> loadUberBytes() async {
    if (_bytesCache.containsKey('white')) return _bytesCache['white'];
    // Build the Google Maps–style nav car directly (faster than going via loadUber)
    final bytes = await _renderGmapsNavCarBytes();
    _bytesCache['white'] = bytes;
    return bytes;
  }

  /// Returns raw PNG bytes for a ride-specific icon.
  static Future<Uint8List?> loadForRideBytes(String rideName) async {
    final key = rideName.trim().toLowerCase();
    if (key.contains('suburba')) {
      if (_bytesCache.containsKey('suv_black')) return _bytesCache['suv_black'];
      await loadForRide(rideName);
      return _bytesCache['suv_black'];
    }
    final cacheKey = key.contains('fusion') ? 'black' : 'white';
    if (_bytesCache.containsKey(cacheKey)) return _bytesCache[cacheKey];
    await loadForRide(rideName);
    return _bytesCache[cacheKey];
  }

  static void invalidate() {
    _cache.clear();
    _bytesCache.clear();
    _cardCache.clear();
    _rotatedCache.clear();
  }

  // ── Pre-rotated icon for Apple Maps (no native rotation support) ──

  /// Cache of rotated PNGs keyed by quantised angle.
  static final Map<int, Uint8List> _rotatedCache = {};

  /// The base (0°) icon bytes used for rotation.
  static Uint8List? _baseForRotation;

  /// Returns car icon PNG bytes rotated by [degrees] (clockwise, 0 = north).
  /// Quantized to 5° increments and cached for performance.
  static Future<Uint8List> rotateBytes(double degrees) async {
    final q = ((degrees % 360) / 5).round() * 5;
    if (_rotatedCache.containsKey(q)) return _rotatedCache[q]!;

    _baseForRotation ??= await _renderGmapsNavCarBytes();
    final base = _baseForRotation!;

    if (q == 0) {
      _rotatedCache[0] = base;
      return base;
    }

    final codec = await ui.instantiateImageCodec(base);
    final frame = await codec.getNextFrame();
    final src = frame.image;

    final dim = math.max(src.width, src.height).toDouble();
    final size = (dim * 1.42).ceilToDouble();
    final iSize = size.toInt();

    final rec = ui.PictureRecorder();
    final cvs = Canvas(rec, Rect.fromLTWH(0, 0, size, size));
    cvs.translate(size / 2, size / 2);
    cvs.rotate(q * math.pi / 180);
    cvs.drawImage(
      src,
      Offset(-src.width / 2, -src.height / 2),
      Paint()..filterQuality = FilterQuality.high,
    );
    final pic = rec.endRecording();
    final img = await pic.toImage(iSize, iSize);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List();

    _rotatedCache[q] = bytes;
    src.dispose();
    img.dispose();
    return bytes;
  }

  // =================================================================
  //  CARD IMAGE — same detailed car, no shadow, as PNG bytes
  // =================================================================

  static final Map<String, ui.Image> _cardCache = {};

  /// Returns a high-res ui.Image of the car for use in card thumbnails.
  /// No ground shadow / under-car shadow — clean for dark card backgrounds.
  static Future<ui.Image> renderCardImage(String rideName) async {
    final key = rideName.trim().toLowerCase();
    final String cacheKey;
    if (key.contains('suburba')) {
      cacheKey = 'card_suv';
    } else if (key.contains('fusion')) {
      cacheKey = 'card_fusion';
    } else {
      cacheKey = 'card_camry';
    }
    if (_cardCache.containsKey(cacheKey)) return _cardCache[cacheKey]!;

    final ui.Image img;
    if (key.contains('suburba')) {
      img = await _renderSuvCard(_CarPalette.black);
    } else if (key.contains('fusion')) {
      img = await _renderSedanCard(_CarPalette.black);
    } else {
      img = await _renderSedanCard(_CarPalette.whitePearl);
    }
    _cardCache[cacheKey] = img;
    return img;
  }

  /// Sedan card image — no shadows
  static Future<ui.Image> _renderSedanCard(_CarPalette p) async {
    const double lw = 20, lh = 36;
    const double scale = 8.0;
    final int pw = (lw * scale).toInt();
    final int ph = (lh * scale).toInt();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final cy = h * 0.46;
    final bw = w * 0.30;
    final bh = h * 0.38;

    // Skip _groundShadow and _underCarShadow
    final body = _bodyPath(cx, cy, bw, bh);
    _paintBody(c, body, cx, cy, bw, bh, p);
    _bodyAO(c, body, cx, cy, bw, bh);
    _fenderCurves(c, cx, cy, bw, bh, p);
    _doorPanels(c, cx, cy, bw, bh);
    _doorHandles(c, cx, cy, bw, bh, p);
    _beltLine(c, cx, cy, bw, bh, p);
    _windshield(c, cx, cy, bw, bh);
    _rearGlass(c, cx, cy, bw, bh);
    _sideWindows(c, cx, cy, bw, bh);
    _closedRoof(c, cx, cy, bw, bh, p);
    _headlights(c, cx, cy, bw, bh);
    _taillights(c, cx, cy, bw, bh);
    _frontBumper(c, cx, cy, bw, bh, p);
    _rearBumper(c, cx, cy, bw, bh);
    _mirrors(c, cx, cy, bw, bh, p);
    _hoodCrease(c, cx, cy, bw, bh, p);

    final pic = rec.endRecording();
    return pic.toImage(pw, ph);
  }

  /// SUV card image — no shadows
  static Future<ui.Image> _renderSuvCard(_CarPalette p) async {
    const double lw = 24, lh = 40;
    const double scale = 8.0;
    final int pw = (lw * scale).toInt();
    final int ph = (lh * scale).toInt();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final cy = h * 0.46;
    final bw = w * 0.32;
    final bh = h * 0.40;

    // Skip _suvGroundShadow and _suvUnderCarShadow
    final body = _suvBodyPath(cx, cy, bw, bh);
    _paintBody(c, body, cx, cy, bw, bh, p);
    _bodyAO(c, body, cx, cy, bw, bh);
    _suvFenderCurves(c, cx, cy, bw, bh, p);
    _suvDoorPanels(c, cx, cy, bw, bh);
    _suvDoorHandles(c, cx, cy, bw, bh, p);
    _beltLine(c, cx, cy, bw, bh, p);
    _suvWindshield(c, cx, cy, bw, bh);
    _suvRearGlass(c, cx, cy, bw, bh);
    _suvSideWindows(c, cx, cy, bw, bh);
    _suvClosedRoof(c, cx, cy, bw, bh, p);
    _suvRoofRails(c, cx, cy, bw, bh, p);
    _suvHeadlights(c, cx, cy, bw, bh);
    _suvTaillights(c, cx, cy, bw, bh);
    _suvFrontBumper(c, cx, cy, bw, bh, p);
    _suvRearBumper(c, cx, cy, bw, bh);
    _suvMirrors(c, cx, cy, bw, bh, p);
    _suvHoodCrease(c, cx, cy, bw, bh, p);

    final pic = rec.endRecording();
    return pic.toImage(pw, ph);
  }

  // =================================================================
  //  RENDERER — small 3D closed-roof car
  // =================================================================
  //  GOOGLE-MAPS-STYLE NAVIGATION CAR — used for the live driver marker
  // =================================================================

  /// Renders a clean Google-Maps-style top-down navigation car.
  /// White pearl body, prominent dark windshield, drop shadow, headlights &
  /// taillights — the same visual language as the Google Maps nav car icon.
  static Future<Uint8List> _renderGmapsNavCarBytes() async {
    // 22×44 logical units @ 4× → 88×176 physical pixels (Retina-ready)
    const double lw = 22.0, lh = 44.0;
    const double scale = 4.0;
    final int pw = (lw * scale).round();
    final int ph = (lh * scale).round();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final cvs = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w * 0.5;
    final cy = h * 0.50;

    // ── 1. Soft drop-shadow ──────────────────────────────────────────
    cvs.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + h * 0.04),
        width: w * 0.82,
        height: h * 0.88,
      ),
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // ── 2. Body path (organic sedan silhouette) ──────────────────────
    final body = _gmapsBodyPath(cx, cy, w, h);

    // Pearl-white lateral gradient
    cvs.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - w * 0.42, cy),
          Offset(cx + w * 0.42, cy),
          const [
            Color(0xFFBFC4CC), // side in shadow
            Color(0xFFD8DCE4),
            Color(0xFFF2F4F8), // centre highlight
            Color(0xFFD8DCE4),
            Color(0xFFBFC4CC),
          ],
          [0.0, 0.22, 0.50, 0.78, 1.0],
        ),
    );

    // Thin body outline
    cvs.drawPath(
      body,
      Paint()
        ..color = const Color(0x50505870)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.028
        ..isAntiAlias = true,
    );

    // ── 3. Windshield (front, ~28 % from nose) ──────────────────────
    final wsTop = cy - h * 0.305;
    final wsMid = cy - h * 0.135;
    final wsPath = Path()
      ..moveTo(cx - w * 0.215, wsTop + h * 0.020)
      ..lineTo(cx + w * 0.215, wsTop + h * 0.020)
      ..lineTo(cx + w * 0.252, wsMid)
      ..lineTo(cx - w * 0.252, wsMid)
      ..close();
    cvs.drawPath(
      wsPath,
      Paint()
        ..color = const Color(0xD42B3D52)
        ..isAntiAlias = true,
    );

    // Glass inner highlight strip
    cvs.drawRect(
      Rect.fromLTWH(cx - w * 0.17, wsTop + h * 0.030, w * 0.34, h * 0.022),
      Paint()
        ..color = const Color(0x22FFFFFF)
        ..isAntiAlias = true,
    );

    // ── 4. Roof panel (between windshield & rear glass) ──────────────
    final roofY1 = wsTop + h * 0.020;
    final roofY2 = cy + h * 0.135;
    cvs.drawRect(
      Rect.fromLTWH(cx - w * 0.215, roofY1, w * 0.430, roofY2 - roofY1),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, roofY1),
          Offset(cx, roofY2),
          const [Color(0xFFDCE0E8), Color(0xFFF0F3F8), Color(0xFFDCE0E8)],
          [0.0, 0.50, 1.0],
        ),
    );

    // ── 5. Rear glass ────────────────────────────────────────────────
    final rgTop = cy + h * 0.135;
    final rgBot = cy + h * 0.290;
    final rgPath = Path()
      ..moveTo(cx - w * 0.220, rgTop)
      ..lineTo(cx + w * 0.220, rgTop)
      ..lineTo(cx + w * 0.195, rgBot)
      ..lineTo(cx - w * 0.195, rgBot)
      ..close();
    cvs.drawPath(
      rgPath,
      Paint()
        ..color = const Color(0xBB2B3D52)
        ..isAntiAlias = true,
    );

    // ── 6. Side mirrors ──────────────────────────────────────────────
    final mirY = wsMid - h * 0.028;
    // Left
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - w * 0.430, mirY, w * 0.070, h * 0.050),
        Radius.circular(w * 0.014),
      ),
      Paint()
        ..color = const Color(0xFFCDD1D8)
        ..isAntiAlias = true,
    );
    // Right
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx + w * 0.360, mirY, w * 0.070, h * 0.050),
        Radius.circular(w * 0.014),
      ),
      Paint()
        ..color = const Color(0xFFCDD1D8)
        ..isAntiAlias = true,
    );

    // ── 7. Headlights (front) ───────────────────────────────────────
    final hlY = cy - h * 0.415;
    for (final sx in [-0.200, 0.200]) {
      cvs.drawOval(
        Rect.fromCenter(
          center: Offset(cx + w * sx, hlY),
          width: w * 0.175,
          height: h * 0.046,
        ),
        Paint()
          ..color = const Color(0xFFFFF9E0)
          ..isAntiAlias = true,
      );
    }

    // ── 8. Taillights (rear) ────────────────────────────────────────
    final tlY = cy + h * 0.415;
    for (final sx in [-0.195, 0.195]) {
      cvs.drawOval(
        Rect.fromCenter(
          center: Offset(cx + w * sx, tlY),
          width: w * 0.165,
          height: h * 0.040,
        ),
        Paint()
          ..color = const Color(0xFFFF3030)
          ..isAntiAlias = true,
      );
    }

    // ── 9. Hood crease / centre line ────────────────────────────────
    final creaseTop = cy - h * 0.450;
    final creaseMid = wsTop + h * 0.010;
    cvs.drawLine(
      Offset(cx, creaseTop),
      Offset(cx, creaseMid),
      Paint()
        ..color = const Color(0x30000000)
        ..strokeWidth = w * 0.018
        ..isAntiAlias = true,
    );

    final pic = rec.endRecording();
    final img = await pic.toImage(pw, ph);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Organic sedan body — tapered nose, wider at mid/rear (Google Maps style).
  static Path _gmapsBodyPath(double cx, double cy, double w, double h) {
    final path = Path();
    final front = cy - h * 0.450;
    final rear = cy + h * 0.450;
    path.moveTo(cx, front);
    path.cubicTo(
      cx + w * 0.165,
      front,
      cx + w * 0.400,
      front + h * 0.120,
      cx + w * 0.415,
      cy - h * 0.050,
    );
    path.cubicTo(
      cx + w * 0.420,
      cy + h * 0.110,
      cx + w * 0.380,
      rear - h * 0.100,
      cx + w * 0.130,
      rear,
    );
    path.lineTo(cx - w * 0.130, rear);
    path.cubicTo(
      cx - w * 0.380,
      rear - h * 0.100,
      cx - w * 0.420,
      cy + h * 0.110,
      cx - w * 0.415,
      cy - h * 0.050,
    );
    path.cubicTo(
      cx - w * 0.400,
      front + h * 0.120,
      cx - w * 0.165,
      front,
      cx,
      front,
    );
    path.close();
    return path;
  }

  // =================================================================
  //  LEGACY RENDERER — used only by card thumbnails (not the map marker)
  // =================================================================

  static Future<BitmapDescriptor> _render(_CarPalette p) async {
    // Delegate to the new Google-Maps-style nav car for the white sedan.
    // Black palette (Fusion) keeps legacy renderer for card thumbnails.
    if (p == _CarPalette.whitePearl) {
      final bytes = await _renderGmapsNavCarBytes();
      _bytesCache['white'] = bytes;
      // ignore: deprecated_member_use
      return BitmapDescriptor.fromBytes(bytes);
    }

    // Black sedan (Fusion) — legacy detailed renderer
    const double lw = 20, lh = 36;
    const double scale = 3.0;
    final int pw = (lw * scale).toInt();
    final int ph = (lh * scale).toInt();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final cy = h * 0.46;
    final bw = w * 0.30;
    final bh = h * 0.38;

    final body = _bodyPath(cx, cy, bw, bh);
    _paintBody(c, body, cx, cy, bw, bh, p);
    _bodyAO(c, body, cx, cy, bw, bh);
    _fenderCurves(c, cx, cy, bw, bh, p);
    _doorPanels(c, cx, cy, bw, bh);
    _doorHandles(c, cx, cy, bw, bh, p);
    _beltLine(c, cx, cy, bw, bh, p);
    _windshield(c, cx, cy, bw, bh);
    _rearGlass(c, cx, cy, bw, bh);
    _sideWindows(c, cx, cy, bw, bh);
    _closedRoof(c, cx, cy, bw, bh, p);
    _headlights(c, cx, cy, bw, bh);
    _taillights(c, cx, cy, bw, bh);
    _frontBumper(c, cx, cy, bw, bh, p);
    _rearBumper(c, cx, cy, bw, bh);
    _mirrors(c, cx, cy, bw, bh, p);
    _hoodCrease(c, cx, cy, bw, bh, p);

    final pic = rec.endRecording();
    final img = await pic.toImage(pw, ph);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;

    final pixelBytes = bytes.buffer.asUint8List();
    _bytesCache['black'] = pixelBytes;
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(pixelBytes);
  }

  // =================================================================
  //  SUV RENDERER — wider, boxier, with roof rails
  // =================================================================

  static Future<BitmapDescriptor> _renderSuv(_CarPalette p) async {
    // SUV is wider and slightly taller than sedan
    const double lw = 24, lh = 40;
    const double scale = 3.0; // smaller for Android 9 fromBytes
    final int pw = (lw * scale).toInt();
    final int ph = (lh * scale).toInt();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final cy = h * 0.46;

    final bw = w * 0.32; // wider than sedan (0.30)
    final bh = h * 0.40; // taller than sedan (0.38)

    // Render layers bottom-to-top (no ground/under-car shadow)
    final body = _suvBodyPath(cx, cy, bw, bh);
    _paintBody(c, body, cx, cy, bw, bh, p);
    _bodyAO(c, body, cx, cy, bw, bh);
    _suvFenderCurves(c, cx, cy, bw, bh, p);
    _suvDoorPanels(c, cx, cy, bw, bh);
    _suvDoorHandles(c, cx, cy, bw, bh, p);
    _beltLine(c, cx, cy, bw, bh, p);
    _suvWindshield(c, cx, cy, bw, bh);
    _suvRearGlass(c, cx, cy, bw, bh);
    _suvSideWindows(c, cx, cy, bw, bh);
    _suvClosedRoof(c, cx, cy, bw, bh, p);
    _suvRoofRails(c, cx, cy, bw, bh, p);
    _suvHeadlights(c, cx, cy, bw, bh);
    _suvTaillights(c, cx, cy, bw, bh);
    _suvFrontBumper(c, cx, cy, bw, bh, p);
    _suvRearBumper(c, cx, cy, bw, bh);
    _suvMirrors(c, cx, cy, bw, bh, p);
    _suvHoodCrease(c, cx, cy, bw, bh, p);

    final pic = rec.endRecording();
    final img = await pic.toImage(pw, ph);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;

    final pixelBytes = bytes.buffer.asUint8List();
    _bytesCache['suv_black'] = pixelBytes; // SUV marker is always black
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(pixelBytes);
  }

  // ── SUV Ground shadow ──────────────────────────────────────────────

  static void _suvGroundShadow(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bw * 0.04, cy + bh * 0.18),
        width: bw * 2.90,
        height: bh * 2.40,
      ),
      Paint()
        ..color = const Color(0x34000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bw * 0.02, cy + bh * 0.12),
        width: bw * 2.40,
        height: bh * 2.05,
      ),
      Paint()
        ..color = const Color(0x2A000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.08),
        width: bw * 1.95,
        height: bh * 1.75,
      ),
      Paint()
        ..color = const Color(0x22000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
  }

  // ── SUV Under-car darkness ─────────────────────────────────────────

  static void _suvUnderCarShadow(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.04),
        width: bw * 1.60,
        height: bh * 1.50,
      ),
      Paint()
        ..color = const Color(0x32000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  // ── SUV Body path (boxy, wide, squared) ────────────────────────────

  static Path _suvBodyPath(double cx, double cy, double bw, double bh) {
    final p = Path();

    // Front nose — semi-oval rounded SUV front
    p.moveTo(cx - bw * 0.74, cy - bh * 0.94);
    p.cubicTo(
      cx - bw * 0.35,
      cy - bh * 1.02,
      cx + bw * 0.35,
      cy - bh * 1.02,
      cx + bw * 0.74,
      cy - bh * 0.94,
    );
    // Right front fender — semi-oval corner
    p.cubicTo(
      cx + bw * 0.94,
      cy - bh * 0.88,
      cx + bw * 1.05,
      cy - bh * 0.58,
      cx + bw * 1.04,
      cy - bh * 0.14,
    );
    // Right side — gently curved
    p.cubicTo(
      cx + bw * 1.03,
      cy + bh * 0.10,
      cx + bw * 1.03,
      cy + bh * 0.30,
      cx + bw * 1.04,
      cy + bh * 0.48,
    );
    // Right rear — semi-oval corner
    p.cubicTo(
      cx + bw * 1.05,
      cy + bh * 0.68,
      cx + bw * 0.94,
      cy + bh * 0.90,
      cx + bw * 0.72,
      cy + bh * 0.97,
    );
    // Rear — wide, slightly curved
    p.cubicTo(
      cx + bw * 0.38,
      cy + bh * 1.01,
      cx - bw * 0.38,
      cy + bh * 1.01,
      cx - bw * 0.72,
      cy + bh * 0.97,
    );
    // Left rear — semi-oval corner
    p.cubicTo(
      cx - bw * 0.94,
      cy + bh * 0.90,
      cx - bw * 1.05,
      cy + bh * 0.68,
      cx - bw * 1.04,
      cy + bh * 0.48,
    );
    // Left side — gently curved
    p.cubicTo(
      cx - bw * 1.03,
      cy + bh * 0.30,
      cx - bw * 1.03,
      cy + bh * 0.10,
      cx - bw * 1.04,
      cy - bh * 0.14,
    );
    // Left front fender — semi-oval corner
    p.cubicTo(
      cx - bw * 1.05,
      cy - bh * 0.58,
      cx - bw * 0.94,
      cy - bh * 0.88,
      cx - bw * 0.74,
      cy - bh * 0.94,
    );

    p.close();
    return p;
  }

  // ── SUV Fender curves ──────────────────────────────────────────────

  static void _suvFenderCurves(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      // Front fender arch — boxier
      final ff = Path()
        ..moveTo(cx + s * bw * 0.84, cy - bh * 0.92)
        ..cubicTo(
          cx + s * bw * 1.02,
          cy - bh * 0.82,
          cx + s * bw * 1.08,
          cy - bh * 0.52,
          cx + s * bw * 1.04,
          cy - bh * 0.20,
        );
      c.drawPath(
        ff,
        Paint()
          ..color = p.fenderHighlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      c.drawPath(
        ff,
        Paint()
          ..color = const Color(0x10000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );

      // Rear fender arch — boxier
      final rf = Path()
        ..moveTo(cx + s * bw * 1.02, cy + bh * 0.40)
        ..cubicTo(
          cx + s * bw * 1.05,
          cy + bh * 0.62,
          cx + s * bw * 0.88,
          cy + bh * 0.90,
          cx + s * bw * 0.50,
          cy + bh * 0.98,
        );
      c.drawPath(
        rf,
        Paint()
          ..color = p.fenderHighlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      c.drawPath(
        rf,
        Paint()
          ..color = const Color(0x0C000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );
    }
  }

  // ── SUV Door panels (3 rows: front, rear, cargo) ───────────────────

  static void _suvDoorPanels(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    for (final s in [-1.0, 1.0]) {
      final x = cx + s * bw;

      // Front door outline
      final fd = Path()
        ..moveTo(x * 0.97 + cx * 0.03, cy - bh * 0.40)
        ..lineTo(x * 0.96 + cx * 0.04, cy - bh * 0.04)
        ..lineTo(x * 0.95 + cx * 0.05, cy - bh * 0.04);
      c.drawPath(
        fd,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );

      // Rear door outline
      final rd = Path()
        ..moveTo(x * 0.96 + cx * 0.04, cy - bh * 0.04)
        ..lineTo(x * 0.96 + cx * 0.04, cy + bh * 0.32)
        ..lineTo(x * 0.95 + cx * 0.05, cy + bh * 0.32);
      c.drawPath(
        rd,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );

      // Cargo area divider line
      c.drawLine(
        Offset(cx + s * bw * 0.90, cy + bh * 0.38),
        Offset(cx + s * bw * 0.92, cy + bh * 0.38),
        Paint()
          ..color = const Color(0x16000000)
          ..strokeWidth = 2.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
          ..isAntiAlias = true,
      );

      // Door crease shadow
      c.drawLine(
        Offset(cx + s * bw * 0.92, cy - bh * 0.36),
        Offset(cx + s * bw * 0.90, cy + bh * 0.36),
        Paint()
          ..color = const Color(0x14000000)
          ..strokeWidth = 2.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
          ..isAntiAlias = true,
      );

      // B-pillar
      c.drawLine(
        Offset(cx + s * bw * 0.92, cy - bh * 0.08),
        Offset(cx + s * bw * 0.94, cy + bh * 0.02),
        Paint()
          ..color = const Color(0xFFBEC3CA)
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      c.drawLine(
        Offset(cx + s * bw * 0.92, cy - bh * 0.08),
        Offset(cx + s * bw * 0.94, cy + bh * 0.02),
        Paint()
          ..color = const Color(0x18000000)
          ..strokeWidth = 5.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );

      // C-pillar (between rear window and cargo)
      c.drawLine(
        Offset(cx + s * bw * 0.88, cy + bh * 0.26),
        Offset(cx + s * bw * 0.90, cy + bh * 0.34),
        Paint()
          ..color = const Color(0xFFBEC3CA)
          ..strokeWidth = 2.8
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      c.drawLine(
        Offset(cx + s * bw * 0.88, cy + bh * 0.26),
        Offset(cx + s * bw * 0.90, cy + bh * 0.34),
        Paint()
          ..color = const Color(0x14000000)
          ..strokeWidth = 4.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
  }

  // ── SUV Door handles ───────────────────────────────────────────────

  static void _suvDoorHandles(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      final hx = cx + s * bw * 0.96;

      // Front handle
      final fh = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hx, cy - bh * 0.18),
          width: bw * 0.03,
          height: bh * 0.06,
        ),
        Radius.circular(bw * 0.015),
      );
      c.drawRRect(fh, Paint()..color = p.handleFill);

      // Rear handle
      final rh = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hx, cy + bh * 0.14),
          width: bw * 0.03,
          height: bh * 0.06,
        ),
        Radius.circular(bw * 0.015),
      );
      c.drawRRect(rh, Paint()..color = p.handleFill);
    }
  }

  // ── SUV Windshield (taller, more upright) ──────────────────────────

  static void _suvWindshield(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final ws = Path();
    final wsTop = cy - bh * 0.50;
    final wsBot = cy - bh * 0.18;
    final wsTopW = bw * 0.56;
    final wsBotW = bw * 0.82;

    ws.moveTo(cx - wsTopW, wsTop);
    ws.cubicTo(
      cx - wsTopW * 0.4,
      wsTop - bh * 0.03,
      cx + wsTopW * 0.4,
      wsTop - bh * 0.03,
      cx + wsTopW,
      wsTop,
    );
    ws.lineTo(cx + wsBotW, wsBot);
    ws.cubicTo(
      cx + wsBotW * 0.3,
      wsBot + bh * 0.02,
      cx - wsBotW * 0.3,
      wsBot + bh * 0.02,
      cx - wsBotW,
      wsBot,
    );
    ws.close();

    c.drawPath(ws, Paint()..color = const Color(0xFF0A0C10));

    c.save();
    c.clipPath(ws);
    c.drawRect(
      Rect.fromLTWH(
        cx - wsBotW,
        wsTop - bh * 0.05,
        wsBotW * 2,
        wsBot - wsTop + bh * 0.1,
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, wsTop),
          Offset(cx, wsBot),
          [
            const Color(0xFF141618),
            const Color(0xFF080A0C),
            const Color(0xFF101214),
          ],
          [0.0, 0.5, 1.0],
        ),
    );

    // Reflection streak
    final ref = Path()
      ..moveTo(cx - wsTopW * 0.75, wsTop + (wsBot - wsTop) * 0.12)
      ..lineTo(cx - wsTopW * 0.20, wsTop + (wsBot - wsTop) * 0.08)
      ..lineTo(cx + wsBotW * 0.15, wsBot - (wsBot - wsTop) * 0.18)
      ..lineTo(cx - wsBotW * 0.35, wsBot - (wsBot - wsTop) * 0.12)
      ..close();
    c.drawPath(
      ref,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - wsTopW, wsTop),
          Offset(cx + wsBotW * 0.15, wsBot),
          [
            const Color(0x00FFFFFF),
            const Color(0x30FFFFFF),
            const Color(0x12FFFFFF),
            const Color(0x00FFFFFF),
          ],
          [0.0, 0.28, 0.62, 1.0],
        ),
    );
    c.restore();

    // Chrome frame
    c.drawPath(
      ws,
      Paint()
        ..color = const Color(0x38AAAAAA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..isAntiAlias = true,
    );

    // Shadow below
    c.drawLine(
      Offset(cx - wsBotW * 0.9, wsBot + 1),
      Offset(cx + wsBotW * 0.9, wsBot + 1),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 3.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }

  // ── SUV Rear glass (wider, more upright) ───────────────────────────

  static void _suvRearGlass(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final rg = Path();
    final rgTop = cy + bh * 0.54;
    final rgBot = cy + bh * 0.72;
    final rgTopW = bw * 0.66;
    final rgBotW = bw * 0.48;

    rg.moveTo(cx - rgTopW, rgTop);
    rg.cubicTo(
      cx - rgTopW * 0.3,
      rgTop - bh * 0.02,
      cx + rgTopW * 0.3,
      rgTop - bh * 0.02,
      cx + rgTopW,
      rgTop,
    );
    rg.lineTo(cx + rgBotW, rgBot);
    rg.cubicTo(
      cx + rgBotW * 0.3,
      rgBot + bh * 0.03,
      cx - rgBotW * 0.3,
      rgBot + bh * 0.03,
      cx - rgBotW,
      rgBot,
    );
    rg.close();

    c.drawPath(rg, Paint()..color = const Color(0xFF0A0C10));

    c.save();
    c.clipPath(rg);
    c.drawLine(
      Offset(cx + rgTopW * 0.3, rgTop + (rgBot - rgTop) * 0.22),
      Offset(cx + rgBotW * 0.05, rgBot - (rgBot - rgTop) * 0.22),
      Paint()
        ..color = const Color(0x1AFFFFFF)
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.restore();

    c.drawPath(
      rg,
      Paint()
        ..color = const Color(0x30AAAAAA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );
  }

  // ── SUV Side windows (3 windows: front, rear, cargo quarter) ───────

  static void _suvSideWindows(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    for (final s in [-1.0, 1.0]) {
      // Front side window — taller
      final fw = Path()
        ..moveTo(cx + s * bw * 0.78, cy - bh * 0.36)
        ..lineTo(cx + s * bw * 0.94, cy - bh * 0.32)
        ..lineTo(cx + s * bw * 0.96, cy - bh * 0.06)
        ..lineTo(cx + s * bw * 0.80, cy - bh * 0.08)
        ..close();
      c.drawPath(fw, Paint()..color = const Color(0xFF080A0E));

      // Rear side window — taller
      final rw = Path()
        ..moveTo(cx + s * bw * 0.80, cy + bh * 0.02)
        ..lineTo(cx + s * bw * 0.96, cy + bh * 0.04)
        ..lineTo(cx + s * bw * 0.94, cy + bh * 0.28)
        ..lineTo(cx + s * bw * 0.78, cy + bh * 0.26)
        ..close();
      c.drawPath(rw, Paint()..color = const Color(0xFF080A0E));

      // Cargo quarter window — pushed further back
      final qw = Path()
        ..moveTo(cx + s * bw * 0.78, cy + bh * 0.34)
        ..lineTo(cx + s * bw * 0.92, cy + bh * 0.36)
        ..lineTo(cx + s * bw * 0.90, cy + bh * 0.50)
        ..lineTo(cx + s * bw * 0.76, cy + bh * 0.48)
        ..close();
      c.drawPath(qw, Paint()..color = const Color(0xFF080A0E));

      // Window trims
      for (final wp in [fw, rw, qw]) {
        c.drawPath(
          wp,
          Paint()
            ..color = const Color(0x18888888)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6
            ..isAntiAlias = true,
        );
      }
    }
  }

  // ── SUV Closed roof (wider, longer) ────────────────────────────────

  static void _suvClosedRoof(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    final roof = RRect.fromRectAndCorners(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.10),
        width: bw * 1.70,
        height: bh * 0.72,
      ),
      topLeft: Radius.circular(bw * 0.26),
      topRight: Radius.circular(bw * 0.26),
      bottomLeft: Radius.circular(bw * 0.20),
      bottomRight: Radius.circular(bw * 0.20),
    );

    c.drawRRect(
      roof,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw * 0.78, cy),
          Offset(cx + bw * 0.78, cy),
          p.roofGrad,
          [0.0, 0.20, 0.50, 0.80, 1.0],
        ),
    );

    c.drawRRect(
      roof,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, cy - bh * 0.18),
          Offset(cx, cy + bh * 0.22),
          [const Color(0x22FFFFFF), const Color(0x00FFFFFF)],
          [0.0, 1.0],
        ),
    );

    c.drawRRect(
      roof,
      Paint()
        ..color = const Color(0x1C888888)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..isAntiAlias = true,
    );

    for (final s in [-1.0, 1.0]) {
      c.drawLine(
        Offset(cx + s * bw * 0.76, cy - bh * 0.14),
        Offset(cx + s * bw * 0.76, cy + bh * 0.20),
        Paint()
          ..color = const Color(0x10000000)
          ..strokeWidth = 3.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );
    }
  }

  // ── SUV Roof rails (chrome, characteristic SUV detail) ─────────────

  static void _suvRoofRails(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      final rx = cx + s * bw * 0.72;

      // Main rail bar
      c.drawLine(
        Offset(rx, cy - bh * 0.20),
        Offset(rx, cy + bh * 0.26),
        Paint()
          ..color = const Color(0xFF9A9EA6)
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );

      // Rail highlight
      c.drawLine(
        Offset(rx - s * 0.5, cy - bh * 0.18),
        Offset(rx - s * 0.5, cy + bh * 0.24),
        Paint()
          ..color = const Color(0x30FFFFFF)
          ..strokeWidth = 0.8
          ..isAntiAlias = true,
      );

      // Rail shadow
      c.drawLine(
        Offset(rx + s * 0.5, cy - bh * 0.18),
        Offset(rx + s * 0.5, cy + bh * 0.24),
        Paint()
          ..color = const Color(0x18000000)
          ..strokeWidth = 1.2
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
          ..isAntiAlias = true,
      );

      // Support posts
      for (final py in [-0.14, 0.06, 0.20]) {
        c.drawLine(
          Offset(rx, cy + bh * py),
          Offset(rx + s * bw * 0.06, cy + bh * py),
          Paint()
            ..color = const Color(0xFF8A8E96)
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true,
        );
      }
    }
  }

  // ── SUV Headlights (wider, more aggressive) ────────────────────────

  static void _suvHeadlights(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final hlY = cy - bh * 0.92;

    for (final s in [-1.0, 1.0]) {
      final hlx = cx + s * bw * 0.58;

      // Housing — oval following SUV front contour
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.58,
          height: bh * 0.085,
        ),
        Paint()..color = const Color(0xFFCDD2DA),
      );
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.58,
          height: bh * 0.085,
        ),
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..isAntiAlias = true,
      );

      // LED element — oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.44,
          height: bh * 0.052,
        ),
        Paint()..color = const Color(0xFFF5F0D8),
      );

      // Bright core — small oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.26,
          height: bh * 0.026,
        ),
        Paint()..color = const Color(0xFFFFFFF0),
      );

      // Warm glow halo
      c.drawCircle(
        Offset(hlx, hlY),
        bw * 0.24,
        Paint()
          ..color = const Color(0x18FFFDE0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
  }

  // ── SUV Taillights (wider, squarer) ────────────────────────────────

  static void _suvTaillights(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final tlY = cy + bh * 0.90;

    for (final s in [-1.0, 1.0]) {
      final tlx = cx + s * bw * 0.60;

      // Housing — oval following SUV rear contour
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.54,
          height: bh * 0.078,
        ),
        Paint()..color = const Color(0xFF6A1010),
      );

      // LED strip — oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.42,
          height: bh * 0.048,
        ),
        Paint()..color = const Color(0xFFE82222),
      );

      // Core glow — small oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.24,
          height: bh * 0.024,
        ),
        Paint()..color = const Color(0xFFFF4848),
      );

      // Red glow halo
      c.drawCircle(
        Offset(tlx, tlY),
        bw * 0.22,
        Paint()
          ..color = const Color(0x24FF2020)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    // Rear light bar
    c.drawLine(
      Offset(cx - bw * 0.38, tlY),
      Offset(cx + bw * 0.38, tlY),
      Paint()
        ..color = const Color(0x50E82222)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  // ── SUV Front bumper (wider, more aggressive) ──────────────────────

  static void _suvFrontBumper(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    // Air intake — wider
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - bh * 0.97),
          width: bw * 0.70,
          height: bh * 0.028,
        ),
        Radius.circular(bh * 0.012),
      ),
      Paint()..color = p.bumperAccent,
    );

    // Chrome accent
    c.drawLine(
      Offset(cx - bw * 0.62, cy - bh * 0.99),
      Offset(cx + bw * 0.62, cy - bh * 0.99),
      Paint()
        ..color = const Color(0x30FFFFFF)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    c.drawLine(
      Offset(cx - bw * 0.76, cy - bh * 0.92),
      Offset(cx + bw * 0.76, cy - bh * 0.92),
      Paint()
        ..color = const Color(0x10000000)
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );
  }

  // ── SUV Rear bumper ────────────────────────────────────────────────

  static void _suvRearBumper(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    c.drawLine(
      Offset(cx - bw * 0.42, cy + bh * 0.93),
      Offset(cx + bw * 0.42, cy + bh * 0.93),
      Paint()
        ..color = const Color(0x1CFFFFFF)
        ..strokeWidth = 0.8
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    c.drawLine(
      Offset(cx - bw * 0.55, cy + bh * 0.97),
      Offset(cx + bw * 0.55, cy + bh * 0.97),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
        ..isAntiAlias = true,
    );
  }

  // ── SUV Mirrors (larger) ───────────────────────────────────────────

  static void _suvMirrors(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      final mx = cx + s * bw * 1.18;
      final my = cy - bh * 0.24;

      c.drawLine(
        Offset(cx + s * bw * 1.00, my + bh * 0.01),
        Offset(mx, my),
        Paint()
          ..color = p.mirrorArm
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );

      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my),
          width: bw * 0.22,
          height: bw * 0.15,
        ),
        Paint()..color = p.mirrorBody,
      );
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx + s * bw * 0.02, my),
          width: bw * 0.14,
          height: bw * 0.09,
        ),
        Paint()..color = const Color(0xFF1A1E28),
      );
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my + bw * 0.04),
          width: bw * 0.24,
          height: bw * 0.12,
        ),
        Paint()
          ..color = const Color(0x14000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my),
          width: bw * 0.22,
          height: bw * 0.15,
        ),
        Paint()
          ..color = const Color(0x20888888)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..isAntiAlias = true,
      );
    }
  }

  // ── SUV Hood crease ────────────────────────────────────────────────

  static void _suvHoodCrease(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    c.drawLine(
      Offset(cx, cy - bh * 0.95),
      Offset(cx, cy - bh * 0.46),
      Paint()
        ..color = p.crease
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    for (final s in [-1.0, 1.0]) {
      c.drawLine(
        Offset(cx + s * 1.5, cy - bh * 0.93),
        Offset(cx + s * 1.5, cy - bh * 0.48),
        Paint()
          ..color = const Color(0x08000000)
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );
    }
  }

  // ── Ground shadow (multi-layer for realism) ───────────────────────

  static void _groundShadow(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    // Outermost diffuse shadow
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bw * 0.04, cy + bh * 0.18),
        width: bw * 2.80,
        height: bh * 2.35,
      ),
      Paint()
        ..color = const Color(0x32000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
    // Mid shadow
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx + bw * 0.02, cy + bh * 0.12),
        width: bw * 2.30,
        height: bh * 2.00,
      ),
      Paint()
        ..color = const Color(0x28000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    // Tight contact
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.08),
        width: bw * 1.85,
        height: bh * 1.70,
      ),
      Paint()
        ..color = const Color(0x20000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
  }

  // ── Under-car darkness ────────────────────────────────────────────

  static void _underCarShadow(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    c.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.04),
        width: bw * 1.50,
        height: bh * 1.40,
      ),
      Paint()
        ..color = const Color(0x30000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  // ── Body path (compact sedan) ─────────────────────────────────────

  static Path _bodyPath(double cx, double cy, double bw, double bh) {
    final p = Path();

    // Front nose — slightly rounded front corners
    p.moveTo(cx - bw * 0.72, cy - bh * 0.92);
    p.cubicTo(
      cx - bw * 0.40,
      cy - bh * 1.00,
      cx + bw * 0.40,
      cy - bh * 1.00,
      cx + bw * 0.72,
      cy - bh * 0.92,
    );
    // Right front fender — slight oval at corner
    p.cubicTo(
      cx + bw * 0.92,
      cy - bh * 0.88,
      cx + bw * 1.04,
      cy - bh * 0.54,
      cx + bw * 1.02,
      cy - bh * 0.12,
    );
    // Right waist
    p.cubicTo(
      cx + bw * 0.98,
      cy + bh * 0.08,
      cx + bw * 0.97,
      cy + bh * 0.22,
      cx + bw * 1.02,
      cy + bh * 0.42,
    );
    // Right rear — more squared
    p.cubicTo(
      cx + bw * 1.04,
      cy + bh * 0.64,
      cx + bw * 0.96,
      cy + bh * 0.88,
      cx + bw * 0.68,
      cy + bh * 0.95,
    );
    // Rear — flat/wide
    p.cubicTo(
      cx + bw * 0.38,
      cy + bh * 0.99,
      cx - bw * 0.38,
      cy + bh * 0.99,
      cx - bw * 0.68,
      cy + bh * 0.95,
    );
    // Left rear — more squared
    p.cubicTo(
      cx - bw * 0.96,
      cy + bh * 0.88,
      cx - bw * 1.04,
      cy + bh * 0.64,
      cx - bw * 1.02,
      cy + bh * 0.42,
    );
    // Left waist
    p.cubicTo(
      cx - bw * 0.97,
      cy + bh * 0.22,
      cx - bw * 0.98,
      cy + bh * 0.08,
      cx - bw * 1.02,
      cy - bh * 0.12,
    );
    // Left front fender — slight oval at corner
    p.cubicTo(
      cx - bw * 1.04,
      cy - bh * 0.54,
      cx - bw * 0.92,
      cy - bh * 0.88,
      cx - bw * 0.72,
      cy - bh * 0.92,
    );

    p.close();
    return p;
  }

  // ── White pearl paint ─────────────────────────────────────────────

  static void _paintBody(
    Canvas c,
    Path body,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    c.drawPath(body, Paint()..color = p.body);

    c.save();
    c.clipPath(body);
    final r = Rect.fromCenter(
      center: Offset(cx, cy),
      width: bw * 2.3,
      height: bh * 2.3,
    );

    // Left-right barrel shading
    c.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw * 1.05, cy),
          Offset(cx + bw * 1.05, cy),
          p.barrelGrad,
          [0.0, 0.10, 0.30, 0.50, 0.70, 0.90, 1.0],
        ),
    );

    // Hood-to-trunk gradient
    c.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, cy - bh),
          Offset(cx, cy + bh),
          [
            const Color(0x20FFFFFF),
            const Color(0x0CFFFFFF),
            const Color(0x00000000),
            const Color(0x10000000),
            const Color(0x1A000000),
          ],
          [0.0, 0.18, 0.42, 0.72, 1.0],
        ),
    );

    // Diagonal specular streak (sunlight on hood)
    final spec = Path()
      ..moveTo(cx - bw * 0.50, cy - bh * 0.96)
      ..lineTo(cx - bw * 0.05, cy - bh * 0.96)
      ..lineTo(cx + bw * 0.40, cy - bh * 0.15)
      ..lineTo(cx - bw * 0.05, cy - bh * 0.15)
      ..close();
    c.drawPath(
      spec,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw * 0.3, cy - bh),
          Offset(cx + bw * 0.2, cy - bh * 0.15),
          [
            const Color(0x00FFFFFF),
            const Color(0x25FFFFFF),
            const Color(0x0CFFFFFF),
            const Color(0x00FFFFFF),
          ],
          [0.0, 0.3, 0.65, 1.0],
        ),
    );

    c.restore();

    // Body outline
    c.drawPath(
      body,
      Paint()
        ..color = p.outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );
  }

  // ── Ambient occlusion ─────────────────────────────────────────────

  static void _bodyAO(
    Canvas c,
    Path body,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    c.save();
    c.clipPath(body);
    // Inner shadow around perimeter
    for (var i = 0; i < 3; i++) {
      c.drawPath(
        body,
        Paint()
          ..color = const Color(0x0C000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (bw * 0.12) * (3 - i)
          ..maskFilter = MaskFilter.blur(BlurStyle.inner, 3.0 + i * 2)
          ..isAntiAlias = true,
      );
    }
    c.restore();
  }

  // ── Fender curves (highlight arches) ──────────────────────────────

  static void _fenderCurves(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      // Front fender arch (matches squared front)
      final ff = Path()
        ..moveTo(cx + s * bw * 0.78, cy - bh * 0.90)
        ..cubicTo(
          cx + s * bw * 0.98,
          cy - bh * 0.80,
          cx + s * bw * 1.06,
          cy - bh * 0.50,
          cx + s * bw * 1.02,
          cy - bh * 0.18,
        );
      c.drawPath(
        ff,
        Paint()
          ..color = p.fenderHighlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      // Shadow side of fender
      c.drawPath(
        ff,
        Paint()
          ..color = const Color(0x10000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );

      // Rear fender arch (matches rounder rear)
      final rf = Path()
        ..moveTo(cx + s * bw * 1.00, cy + bh * 0.35)
        ..cubicTo(
          cx + s * bw * 1.03,
          cy + bh * 0.58,
          cx + s * bw * 0.80,
          cy + bh * 0.88,
          cx + s * bw * 0.42,
          cy + bh * 0.97,
        );
      c.drawPath(
        rf,
        Paint()
          ..color = p.fenderHighlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      c.drawPath(
        rf,
        Paint()
          ..color = const Color(0x0C000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );
    }
  }

  // ── Door panels (detailed with shadow insets) ─────────────────────

  static void _doorPanels(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    for (final s in [-1.0, 1.0]) {
      final x = cx + s * bw;

      // Front door outline
      final fd = Path()
        ..moveTo(x * 0.97 + cx * 0.03, cy - bh * 0.38)
        ..lineTo(x * 0.96 + cx * 0.04, cy - bh * 0.02)
        ..lineTo(x * 0.95 + cx * 0.05, cy - bh * 0.02);
      c.drawPath(
        fd,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );

      // Rear door outline
      final rd = Path()
        ..moveTo(x * 0.96 + cx * 0.04, cy - bh * 0.02)
        ..lineTo(x * 0.96 + cx * 0.04, cy + bh * 0.35)
        ..lineTo(x * 0.95 + cx * 0.05, cy + bh * 0.35);
      c.drawPath(
        rd,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );

      // Door crease shadow (darker inset line)
      c.drawLine(
        Offset(cx + s * bw * 0.90, cy - bh * 0.34),
        Offset(cx + s * bw * 0.88, cy + bh * 0.32),
        Paint()
          ..color = const Color(0x14000000)
          ..strokeWidth = 2.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
          ..isAntiAlias = true,
      );

      // B-pillar (vertical divider between front/rear doors)
      c.drawLine(
        Offset(cx + s * bw * 0.90, cy - bh * 0.06),
        Offset(cx + s * bw * 0.92, cy + bh * 0.04),
        Paint()
          ..color = const Color(0xFFBEC3CA)
          ..strokeWidth = 3.0
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      // B-pillar shadow
      c.drawLine(
        Offset(cx + s * bw * 0.90, cy - bh * 0.06),
        Offset(cx + s * bw * 0.92, cy + bh * 0.04),
        Paint()
          ..color = const Color(0x18000000)
          ..strokeWidth = 5.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );

      // Door lower shadow (bottom edge of each door)
      c.drawLine(
        Offset(cx + s * bw * 0.82, cy + bh * 0.36),
        Offset(cx + s * bw * 0.96, cy + bh * 0.36),
        Paint()
          ..color = const Color(0x12000000)
          ..strokeWidth = 2.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
          ..isAntiAlias = true,
      );
    }
  }

  // ── Door handles (chrome) ─────────────────────────────────────────

  static void _doorHandles(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      final hx = cx + s * bw * 0.94;

      // Front handle
      final fh = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hx, cy - bh * 0.16),
          width: bw * 0.03,
          height: bh * 0.065,
        ),
        Radius.circular(bw * 0.015),
      );
      c.drawRRect(fh, Paint()..color = p.handleFill);
      c.drawRRect(
        fh,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..isAntiAlias = true,
      );

      // Rear handle
      final rh = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hx, cy + bh * 0.16),
          width: bw * 0.03,
          height: bh * 0.065,
        ),
        Radius.circular(bw * 0.015),
      );
      c.drawRRect(rh, Paint()..color = p.handleFill);
      c.drawRRect(
        rh,
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..isAntiAlias = true,
      );
    }
  }

  // ── Belt line (chrome strip along side) ───────────────────────────

  static void _beltLine(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      c.drawLine(
        Offset(cx + s * bw * 0.85, cy - bh * 0.38),
        Offset(cx + s * bw * 0.90, cy + bh * 0.34),
        Paint()
          ..color = p.beltHighlight
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
  }

  // ── Windshield (dark glass, properly sized) ───────────────────────

  static void _windshield(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final ws = Path();
    final wsTop = cy - bh * 0.42;
    final wsBot = cy - bh * 0.10;
    final wsTopW = bw * 0.52;
    final wsBotW = bw * 0.78;

    ws.moveTo(cx - wsTopW, wsTop);
    ws.cubicTo(
      cx - wsTopW * 0.4,
      wsTop - bh * 0.04,
      cx + wsTopW * 0.4,
      wsTop - bh * 0.04,
      cx + wsTopW,
      wsTop,
    );
    ws.lineTo(cx + wsBotW, wsBot);
    ws.cubicTo(
      cx + wsBotW * 0.3,
      wsBot + bh * 0.02,
      cx - wsBotW * 0.3,
      wsBot + bh * 0.02,
      cx - wsBotW,
      wsBot,
    );
    ws.close();

    // Very dark black glass
    c.drawPath(ws, Paint()..color = const Color(0xFF0A0C10));

    c.save();
    c.clipPath(ws);

    // Glass depth
    c.drawRect(
      Rect.fromLTWH(
        cx - wsBotW,
        wsTop - bh * 0.05,
        wsBotW * 2,
        wsBot - wsTop + bh * 0.1,
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, wsTop),
          Offset(cx, wsBot),
          [
            const Color(0xFF141618),
            const Color(0xFF080A0C),
            const Color(0xFF101214),
          ],
          [0.0, 0.5, 1.0],
        ),
    );

    // Bright reflection streak
    final ref = Path()
      ..moveTo(cx - wsTopW * 0.75, wsTop + (wsBot - wsTop) * 0.12)
      ..lineTo(cx - wsTopW * 0.20, wsTop + (wsBot - wsTop) * 0.08)
      ..lineTo(cx + wsBotW * 0.15, wsBot - (wsBot - wsTop) * 0.18)
      ..lineTo(cx - wsBotW * 0.35, wsBot - (wsBot - wsTop) * 0.12)
      ..close();
    c.drawPath(
      ref,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - wsTopW, wsTop),
          Offset(cx + wsBotW * 0.15, wsBot),
          [
            const Color(0x00FFFFFF),
            const Color(0x30FFFFFF),
            const Color(0x12FFFFFF),
            const Color(0x00FFFFFF),
          ],
          [0.0, 0.28, 0.62, 1.0],
        ),
    );
    c.restore();

    // Chrome frame
    c.drawPath(
      ws,
      Paint()
        ..color = const Color(0x38AAAAAA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..isAntiAlias = true,
    );

    // Shadow below windshield
    c.drawLine(
      Offset(cx - wsBotW * 0.9, wsBot + 1),
      Offset(cx + wsBotW * 0.9, wsBot + 1),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 3.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }

  // ── Rear glass ────────────────────────────────────────────────────

  static void _rearGlass(Canvas c, double cx, double cy, double bw, double bh) {
    final rg = Path();
    final rgTop = cy + bh * 0.38;
    final rgBot = cy + bh * 0.56;
    final rgTopW = bw * 0.62;
    final rgBotW = bw * 0.42;

    rg.moveTo(cx - rgTopW, rgTop);
    rg.cubicTo(
      cx - rgTopW * 0.3,
      rgTop - bh * 0.02,
      cx + rgTopW * 0.3,
      rgTop - bh * 0.02,
      cx + rgTopW,
      rgTop,
    );
    rg.lineTo(cx + rgBotW, rgBot);
    rg.cubicTo(
      cx + rgBotW * 0.3,
      rgBot + bh * 0.03,
      cx - rgBotW * 0.3,
      rgBot + bh * 0.03,
      cx - rgBotW,
      rgBot,
    );
    rg.close();

    c.drawPath(rg, Paint()..color = const Color(0xFF0A0C10));

    c.save();
    c.clipPath(rg);
    c.drawLine(
      Offset(cx + rgTopW * 0.3, rgTop + (rgBot - rgTop) * 0.22),
      Offset(cx + rgBotW * 0.05, rgBot - (rgBot - rgTop) * 0.22),
      Paint()
        ..color = const Color(0x1AFFFFFF)
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.restore();

    c.drawPath(
      rg,
      Paint()
        ..color = const Color(0x30AAAAAA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );

    // Shadow above rear glass
    c.drawLine(
      Offset(cx - rgTopW * 0.85, rgTop - 1),
      Offset(cx + rgTopW * 0.85, rgTop - 1),
      Paint()
        ..color = const Color(0x12000000)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
        ..isAntiAlias = true,
    );
  }

  // ── Side windows ──────────────────────────────────────────────────

  static void _sideWindows(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    for (final s in [-1.0, 1.0]) {
      // Front side window — bigger
      final fw = Path()
        ..moveTo(cx + s * bw * 0.78, cy - bh * 0.32)
        ..lineTo(cx + s * bw * 0.90, cy - bh * 0.28)
        ..lineTo(cx + s * bw * 0.92, cy - bh * 0.06)
        ..lineTo(cx + s * bw * 0.80, cy - bh * 0.08)
        ..close();
      c.drawPath(fw, Paint()..color = const Color(0xFF080A0E));

      // Rear side window — bigger
      final rw = Path()
        ..moveTo(cx + s * bw * 0.80, cy + bh * 0.04)
        ..lineTo(cx + s * bw * 0.92, cy + bh * 0.06)
        ..lineTo(cx + s * bw * 0.90, cy + bh * 0.24)
        ..lineTo(cx + s * bw * 0.78, cy + bh * 0.22)
        ..close();
      c.drawPath(rw, Paint()..color = const Color(0xFF080A0E));

      // Window trims
      for (final wp in [fw, rw]) {
        c.drawPath(
          wp,
          Paint()
            ..color = const Color(0x18888888)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6
            ..isAntiAlias = true,
        );
      }

      // Shadow at window sill
      c.drawLine(
        Offset(cx + s * bw * 0.84, cy + bh * 0.22),
        Offset(cx + s * bw * 0.90, cy + bh * 0.22),
        Paint()
          ..color = const Color(0x14000000)
          ..strokeWidth = 2.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
          ..isAntiAlias = true,
      );
    }
  }

  // ── Closed roof (solid, no sunroof hole) ──────────────────────────

  static void _closedRoof(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    // Full roof — covers the entire cabin area (bigger)
    final roof = RRect.fromRectAndCorners(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.01),
        width: bw * 1.58,
        height: bh * 0.40,
      ),
      topLeft: Radius.circular(bw * 0.30),
      topRight: Radius.circular(bw * 0.30),
      bottomLeft: Radius.circular(bw * 0.24),
      bottomRight: Radius.circular(bw * 0.24),
    );

    // Roof matching body color
    c.drawRRect(
      roof,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw * 0.75, cy),
          Offset(cx + bw * 0.75, cy),
          p.roofGrad,
          [0.0, 0.20, 0.50, 0.80, 1.0],
        ),
    );

    // Top-down light reflection (broad)
    c.drawRRect(
      roof,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, cy - bh * 0.14),
          Offset(cx, cy + bh * 0.17),
          [const Color(0x22FFFFFF), const Color(0x00FFFFFF)],
          [0.0, 1.0],
        ),
    );

    // Roof edge trim
    c.drawRRect(
      roof,
      Paint()
        ..color = const Color(0x1C888888)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..isAntiAlias = true,
    );

    // Roof shadow on sides
    for (final s in [-1.0, 1.0]) {
      c.drawLine(
        Offset(cx + s * bw * 0.74, cy - bh * 0.10),
        Offset(cx + s * bw * 0.74, cy + bh * 0.14),
        Paint()
          ..color = const Color(0x10000000)
          ..strokeWidth = 3.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
          ..isAntiAlias = true,
      );
    }
  }

  // ── Headlights (properly integrated into body curve) ──────────────

  static void _headlights(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final hlY = cy - bh * 0.90;

    for (final s in [-1.0, 1.0]) {
      final hlx = cx + s * bw * 0.56;

      // Housing — oval following front body curve
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.54,
          height: bh * 0.080,
        ),
        Paint()..color = const Color(0xFFCDD2DA),
      );
      // Housing inner shadow
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.54,
          height: bh * 0.080,
        ),
        Paint()
          ..color = const Color(0x18000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..isAntiAlias = true,
      );

      // LED element — warm white oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.40,
          height: bh * 0.048,
        ),
        Paint()..color = const Color(0xFFF5F0D8),
      );

      // Bright core — small oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(hlx, hlY),
          width: bw * 0.22,
          height: bh * 0.024,
        ),
        Paint()..color = const Color(0xFFFFFFF0),
      );

      // Warm glow halo
      c.drawCircle(
        Offset(hlx, hlY),
        bw * 0.22,
        Paint()
          ..color = const Color(0x18FFFDE0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
  }

  // ── Taillights (red LED, adapted to rear curve) ───────────────────

  static void _taillights(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    final tlY = cy + bh * 0.88;

    for (final s in [-1.0, 1.0]) {
      final tlx = cx + s * bw * 0.56;

      // Housing — oval following rear body curve
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.50,
          height: bh * 0.072,
        ),
        Paint()..color = const Color(0xFF6A1010),
      );

      // LED strip — oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.38,
          height: bh * 0.042,
        ),
        Paint()..color = const Color(0xFFE82222),
      );

      // Core glow — small oval
      c.drawOval(
        Rect.fromCenter(
          center: Offset(tlx, tlY),
          width: bw * 0.20,
          height: bh * 0.022,
        ),
        Paint()..color = const Color(0xFFFF4848),
      );

      // Red glow halo
      c.drawCircle(
        Offset(tlx, tlY),
        bw * 0.20,
        Paint()
          ..color = const Color(0x24FF2020)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    // Rear light bar connector
    c.drawLine(
      Offset(cx - bw * 0.34, tlY),
      Offset(cx + bw * 0.34, tlY),
      Paint()
        ..color = const Color(0x50E82222)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  // ── Front bumper ──────────────────────────────────────────────────

  static void _frontBumper(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    // Air intake — wider for squared front
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - bh * 0.96),
          width: bw * 0.60,
          height: bh * 0.025,
        ),
        Radius.circular(bh * 0.012),
      ),
      Paint()..color = p.bumperAccent,
    );

    // Bumper chrome accent
    c.drawLine(
      Offset(cx - bw * 0.55, cy - bh * 0.98),
      Offset(cx + bw * 0.55, cy - bh * 0.98),
      Paint()
        ..color = const Color(0x30FFFFFF)
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Bumper bottom shadow
    c.drawLine(
      Offset(cx - bw * 0.68, cy - bh * 0.90),
      Offset(cx + bw * 0.68, cy - bh * 0.90),
      Paint()
        ..color = const Color(0x10000000)
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );
  }

  // ── Rear bumper ───────────────────────────────────────────────────

  static void _rearBumper(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
  ) {
    // Chrome strip
    c.drawLine(
      Offset(cx - bw * 0.38, tlY(cy, bh) + bh * 0.035),
      Offset(cx + bw * 0.38, tlY(cy, bh) + bh * 0.035),
      Paint()
        ..color = const Color(0x1CFFFFFF)
        ..strokeWidth = 0.8
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Bumper shadow
    c.drawLine(
      Offset(cx - bw * 0.48, cy + bh * 0.96),
      Offset(cx + bw * 0.48, cy + bh * 0.96),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
        ..isAntiAlias = true,
    );
  }

  static double tlY(double cy, double bh) => cy + bh * 0.88;

  // ── Side mirrors ──────────────────────────────────────────────────

  static void _mirrors(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    for (final s in [-1.0, 1.0]) {
      final mx = cx + s * bw * 1.16;
      final my = cy - bh * 0.22;

      // Arm
      c.drawLine(
        Offset(cx + s * bw * 0.98, my + bh * 0.01),
        Offset(mx, my),
        Paint()
          ..color = p.mirrorArm
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );

      // Mirror body
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my),
          width: bw * 0.20,
          height: bw * 0.14,
        ),
        Paint()..color = p.mirrorBody,
      );
      // Mirror glass
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx + s * bw * 0.02, my),
          width: bw * 0.12,
          height: bw * 0.08,
        ),
        Paint()..color = const Color(0xFF1A1E28),
      );
      // Mirror shadow
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my + bw * 0.04),
          width: bw * 0.22,
          height: bw * 0.10,
        ),
        Paint()
          ..color = const Color(0x14000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      // Mirror edge
      c.drawOval(
        Rect.fromCenter(
          center: Offset(mx, my),
          width: bw * 0.20,
          height: bw * 0.14,
        ),
        Paint()
          ..color = const Color(0x20888888)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..isAntiAlias = true,
      );
    }
  }

  // ── Hood crease ───────────────────────────────────────────────────

  static void _hoodCrease(
    Canvas c,
    double cx,
    double cy,
    double bw,
    double bh,
    _CarPalette p,
  ) {
    c.drawLine(
      Offset(cx, cy - bh * 0.94),
      Offset(cx, cy - bh * 0.44),
      Paint()
        ..color = p.crease
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    // Shadow beside crease
    for (final s in [-1.0, 1.0]) {
      c.drawLine(
        Offset(cx + s * 1.5, cy - bh * 0.92),
        Offset(cx + s * 1.5, cy - bh * 0.46),
        Paint()
          ..color = const Color(0x08000000)
          ..strokeWidth = 1.0
          ..isAntiAlias = true,
      );
    }
  }
}
