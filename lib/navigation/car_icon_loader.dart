import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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

  // ═══════════════════════════════════════════════════════════════════
  //  MULTI-ANGLE SPRITE SYSTEM (8 directional sprites)
  // ═══════════════════════════════════════════════════════════════════

  /// The 8 view angles in degrees: 0, 45, 90, 135, 180, 225, 270, 315.
  /// Angle = (carHeading − cameraBearing + 360) % 360
  ///   0°  → rear   (car heading away from camera)
  ///  90°  → left side
  /// 180°  → front  (car heading towards camera)
  /// 270°  → right side
  static const List<int> _spriteAngles = [0, 45, 90, 135, 180, 225, 270, 315];

  /// Cached multi-angle sprites (8 BitmapDescriptors, index 0-7).
  static List<BitmapDescriptor>? _navSprites;

  /// Target marker size in logical pixels. Sprites are resized to this
  /// width (height scales proportionally) so they aren't oversized on the map.
  static const double _spriteTargetWidth = 40.0;

  /// Loads 8 directional PNG sprites from assets/images/car_sprites/.
  /// Files must be named: nav_car_0.png, nav_car_45.png, … nav_car_315.png
  /// Each image is decoded and resized to [_spriteTargetWidth] logical px
  /// (×devicePixelRatio) so it looks crisp but doesn't overwhelm the map.
  /// Returns null if any sprite is missing.
  static Future<List<BitmapDescriptor>?> loadNavCarSprites() async {
    if (_navSprites != null) return _navSprites;
    final sprites = <BitmapDescriptor>[];
    // Use 3× scale for crisp rendering on retina screens
    const double scale = 3.0;
    final int targetPx = (_spriteTargetWidth * scale).round();

    for (final angle in _spriteAngles) {
      try {
        final data = await rootBundle.load(
          'assets/images/car_sprites/nav_car_$angle.png',
        );
        final raw = data.buffer.asUint8List();
        if (raw.isEmpty) return null;

        // Decode → resize → re-encode to get a properly sized marker
        final codec = await ui.instantiateImageCodec(
          raw,
          targetWidth: targetPx,
        );
        final frame = await codec.getNextFrame();
        final resized = frame.image;
        final byteData =
            await resized.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        final resizedBytes = byteData.buffer.asUint8List();

        // ignore: deprecated_member_use
        sprites.add(BitmapDescriptor.fromBytes(resizedBytes));
      } catch (_) {
        return null; // sprite missing — caller should fall back
      }
    }
    _navSprites = sprites;
    return sprites;
  }

  /// Given the view angle (carHeading − cameraBearing), returns the
  /// appropriate sprite index (0–7). Snaps to nearest 45°.
  static int spriteIndexForAngle(double viewAngleDeg) {
    final a = ((viewAngleDeg % 360) + 360) % 360; // normalize 0–360
    final idx = ((a + 22.5) / 45).floor() % 8;
    return idx;
  }

  /// Convenience: returns the BitmapDescriptor for a given view angle.
  /// Returns null if sprites haven't been loaded.
  static BitmapDescriptor? spriteForViewAngle(double viewAngleDeg) {
    if (_navSprites == null || _navSprites!.length < 8) return null;
    return _navSprites![spriteIndexForAngle(viewAngleDeg)];
  }

  /// Returns raw PNG bytes for the navigation car icon.
  /// Loads from assets/images/car_sprites/nav_car.png if available,
  /// otherwise falls back to the Canvas renderer.
  static Future<Uint8List?> loadUberBytes() async {
    if (_bytesCache.containsKey('white')) return _bytesCache['white'];
    // Try loading the hand-crafted PNG asset first
    try {
      final data = await rootBundle.load('assets/images/car_sprites/nav_car.png');
      final bytes = data.buffer.asUint8List();
      if (bytes.isNotEmpty) {
        _bytesCache['white'] = bytes;
        return bytes;
      }
    } catch (_) {
      // Asset not found — fall back to Canvas renderer
    }
    final bytes = await _renderGmapsNavCarBytes();
    _bytesCache['white'] = bytes;
    return bytes;
  }

  /// Returns raw PNG bytes for a ride-specific icon.
  static Future<Uint8List?> loadForRideBytes(String rideName) async {
    final key = rideName.trim().toLowerCase();
    if (key.contains('suburba')) {
      if (_bytesCache.containsKey('suv_black')) return _bytesCache['suv_black'];
      final bytes = await _renderSuvBytes(_CarPalette.black);
      _bytesCache['suv_black'] = bytes;
      return bytes;
    }
    final cacheKey = key.contains('fusion') ? 'black' : 'white';
    if (_bytesCache.containsKey(cacheKey)) return _bytesCache[cacheKey];
    final palette = key.contains('fusion')
        ? _CarPalette.black
        : _CarPalette.whitePearl;
    final bytes = await _renderDetailedBytes(palette);
    _bytesCache[cacheKey] = bytes;
    return bytes;
  }

  static void invalidate() {
    _cache.clear();
    _bytesCache.clear();
    _cardCache.clear();
    _rotatedCache.clear();
    _rotatedCacheByType.clear();
  }

  // ── Pre-rotated icon for Apple Maps (no native rotation support) ──

  static final Map<String, Map<int, Uint8List>> _rotatedCacheByType = {};
  static final Map<int, Uint8List> _rotatedCache = {};
  static Uint8List? _baseForRotation;

  /// Returns car icon PNG bytes rotated by [degrees] (clockwise, 0 = north).
  /// Quantized to 5° increments and cached for performance.
  /// Uses default white pearl sedan.
  static Future<Uint8List> rotateBytes(double degrees) =>
      rotateBytesForRide(degrees, rideName: 'Camry');

  /// Returns ride-specific car icon PNG bytes rotated by [degrees].
  /// Supports Suburban (SUV), Fusion (black sedan), Camry (white sedan).
  static Future<Uint8List> rotateBytesForRide(
    double degrees, {
    String rideName = 'Camry',
  }) async {
    final key = rideName.trim().toLowerCase();
    final String typeKey;
    if (key.contains('suburba')) {
      typeKey = 'suv_black';
    } else if (key.contains('fusion')) {
      typeKey = 'black';
    } else {
      typeKey = 'white';
    }

    final q = ((degrees % 360) / 5).round() * 5;
    final cache = _rotatedCacheByType.putIfAbsent(typeKey, () => {});
    if (cache.containsKey(q)) return cache[q]!;

    // Get or generate base bytes for this car type
    final Uint8List base;
    if (typeKey == 'suv_black') {
      base =
          _bytesCache['suv_black'] ?? await _renderSuvBytes(_CarPalette.black);
    } else if (typeKey == 'black') {
      base =
          _bytesCache['black'] ?? await _renderDetailedBytes(_CarPalette.black);
    } else {
      base =
          _bytesCache['white'] ??
          await _renderDetailedBytes(_CarPalette.whitePearl);
    }

    if (q == 0) {
      cache[0] = base;
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

    cache[q] = bytes;
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

  /// Renders a Google-Maps-navigation-style car marker designed for 55° tilt.
  ///
  /// The image is intentionally tall (1:2.85 ratio) to compensate for the
  /// vertical compression caused by the map's 55° camera tilt — cos(55°)≈0.57.
  /// After tilt, proportions appear as a realistic ~1:1.6 SUV/crossover.
  ///
  /// 3D depth is conveyed through:
  /// - Strong lateral barrel gradient (dark edges → bright centre)
  /// - Front-to-rear lighting gradient (bright hood → darker rear)
  /// - Heavy ambient occlusion along all edges
  /// - Specular highlight on roof
  /// - High-contrast windshield/rear glass
  /// - Multi-layer drop shadow + white halo
  static Future<Uint8List> _renderGmapsNavCarBytes() async {
    // 28×80 logical @ 5× = 140×400 physical pixels.
    // Very tall so at 55° tilt it compresses to ~140×230 on screen.
    const double lw = 28.0, lh = 80.0;
    const double scale = 5.0;
    final int pw = (lw * scale).round();
    final int ph = (lh * scale).round();
    final double w = pw.toDouble();
    final double h = ph.toDouble();

    final rec = ui.PictureRecorder();
    final cvs = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w * 0.5;
    final cy = h * 0.47;

    // Body half-extents — wide and very tall
    final double bw = w * 0.38;
    final double bh = h * 0.42;
    final double front = cy - bh;
    final double rear = cy + bh;

    // ── 0. WHITE HALO (visible on dark map backgrounds) ──────────────
    cvs.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: bw * 3.2, height: bh * 2.6),
      Paint()
        ..color = const Color(0x22FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    // ── 1. DROP SHADOW (heavy, offset to rear) ───────────────────────
    cvs.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.18),
        width: bw * 2.3,
        height: bh * 2.0,
      ),
      Paint()
        ..color = const Color(0x70000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    cvs.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + bh * 0.08),
        width: bw * 1.8,
        height: bh * 1.7,
      ),
      Paint()
        ..color = const Color(0x50000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── 2. BODY PATH ─────────────────────────────────────────────────
    // Tapered front, widest at mid, slightly narrower rear — SUV shape.
    // The rear is proportionally wider than the front to enhance the
    // perspective illusion when the map tilts the image.
    final body = Path();
    body.moveTo(cx, front);
    // Front-right: narrow nose widens smoothly
    body.cubicTo(
      cx + bw * 0.40, front,
      cx + bw * 0.88, front + bh * 0.12,
      cx + bw * 0.94, front + bh * 0.35,
    );
    // Right side: gentle barrel
    body.cubicTo(
      cx + bw * 0.98, cy - bh * 0.05,
      cx + bw * 0.98, cy + bh * 0.15,
      cx + bw * 0.94, rear - bh * 0.15,
    );
    // Rear-right corner
    body.cubicTo(
      cx + bw * 0.88, rear - bh * 0.05,
      cx + bw * 0.55, rear,
      cx, rear,
    );
    // Rear-left corner (mirror)
    body.cubicTo(
      cx - bw * 0.55, rear,
      cx - bw * 0.88, rear - bh * 0.05,
      cx - bw * 0.94, rear - bh * 0.15,
    );
    // Left side: gentle barrel
    body.cubicTo(
      cx - bw * 0.98, cy + bh * 0.15,
      cx - bw * 0.98, cy - bh * 0.05,
      cx - bw * 0.94, front + bh * 0.35,
    );
    // Front-left
    body.cubicTo(
      cx - bw * 0.88, front + bh * 0.12,
      cx - bw * 0.40, front,
      cx, front,
    );
    body.close();

    // ── 3. BODY FILL — strong lateral barrel gradient ────────────────
    cvs.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw, cy),
          Offset(cx + bw, cy),
          const [
            Color(0xFF8A9098), // far left — dark
            Color(0xFFB8BEC8), // left quarter
            Color(0xFFF2F4F8), // center — bright white
            Color(0xFFB8BEC8), // right quarter
            Color(0xFF8A9098), // far right — dark
          ],
          [0.0, 0.20, 0.50, 0.80, 1.0],
        ),
    );

    // ── 4. FRONT-TO-REAR depth overlay ───────────────────────────────
    // Hood is brighter (catches light), rear is darker (in shadow)
    cvs.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, front),
          Offset(cx, rear),
          const [
            Color(0x30FFFFFF), // bright hood
            Color(0x10FFFFFF), // upper mid
            Color(0x00000000), // neutral mid
            Color(0x18000000), // lower — slightly darker
            Color(0x40000000), // rear — in shadow
          ],
          [0.0, 0.25, 0.45, 0.75, 1.0],
        ),
    );

    // ── 5. BODY OUTLINE ──────────────────────────────────────────────
    cvs.drawPath(
      body,
      Paint()
        ..color = const Color(0x50506080)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.016
        ..isAntiAlias = true,
    );

    // ── 6. HEAVY AMBIENT OCCLUSION ───────────────────────────────────
    cvs.save();
    cvs.clipPath(body);
    // Left AO
    cvs.drawRect(
      Rect.fromLTWH(cx - bw * 1.0, front, bw * 0.40, bh * 2.1),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw, cy),
          Offset(cx - bw * 0.60, cy),
          const [Color(0x50000000), Color(0x00000000)],
        ),
    );
    // Right AO
    cvs.drawRect(
      Rect.fromLTWH(cx + bw * 0.60, front, bw * 0.40, bh * 2.1),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx + bw * 0.60, cy),
          Offset(cx + bw, cy),
          const [Color(0x00000000), Color(0x50000000)],
        ),
    );
    // Rear AO
    cvs.drawRect(
      Rect.fromLTWH(cx - bw, rear - bh * 0.20, bw * 2, bh * 0.22),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, rear - bh * 0.20),
          Offset(cx, rear),
          const [Color(0x00000000), Color(0x50000000)],
        ),
    );
    // Front AO (subtle nose shadow)
    cvs.drawRect(
      Rect.fromLTWH(cx - bw, front, bw * 2, bh * 0.08),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, front),
          Offset(cx, front + bh * 0.08),
          const [Color(0x20000000), Color(0x00000000)],
        ),
    );
    cvs.restore();

    // ── 7. HOOD — bright front section ───────────────────────────────
    final hoodEnd = cy - bh * 0.32;
    cvs.save();
    cvs.clipPath(body);
    cvs.drawRect(
      Rect.fromLTWH(cx - bw * 0.80, front, bw * 1.60, hoodEnd - front),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, front + bh * 0.04),
          Offset(cx, hoodEnd),
          const [Color(0x38FFFFFF), Color(0x10FFFFFF)],
        ),
    );
    cvs.restore();
    // Hood centre crease
    cvs.drawLine(
      Offset(cx, front + bh * 0.06),
      Offset(cx, hoodEnd),
      Paint()
        ..color = const Color(0x30000000)
        ..strokeWidth = w * 0.014
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // ── 8. WINDSHIELD (very dark, high contrast) ─────────────────────
    final wsTop = cy - bh * 0.34;
    final wsBot = cy - bh * 0.12;
    final wsPath = Path()
      ..moveTo(cx - bw * 0.50, wsTop)
      ..lineTo(cx + bw * 0.50, wsTop)
      ..lineTo(cx + bw * 0.62, wsBot)
      ..lineTo(cx - bw * 0.62, wsBot)
      ..close();
    cvs.drawPath(
      wsPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, wsTop),
          Offset(cx, wsBot),
          const [
            Color(0xF0182838), // very dark top
            Color(0xE0253848), // slightly lighter bottom
          ],
        )
        ..isAntiAlias = true,
    );
    // Bright reflection strip across windshield
    final wsRefY = wsTop + (wsBot - wsTop) * 0.30;
    cvs.drawLine(
      Offset(cx - bw * 0.36, wsRefY),
      Offset(cx + bw * 0.36, wsRefY),
      Paint()
        ..color = const Color(0x44FFFFFF)
        ..strokeWidth = h * 0.008
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // ── 9. ROOF (bright, elevated look) ──────────────────────────────
    final roofBot = cy + bh * 0.12;
    final roofPath = Path()
      ..moveTo(cx - bw * 0.56, wsBot)
      ..lineTo(cx + bw * 0.56, wsBot)
      ..lineTo(cx + bw * 0.52, roofBot)
      ..lineTo(cx - bw * 0.52, roofBot)
      ..close();
    // Lateral gradient — edges darker for 3D curvature
    cvs.drawPath(
      roofPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - bw * 0.5, cy),
          Offset(cx + bw * 0.5, cy),
          const [
            Color(0xFFC8CCD4),
            Color(0xFFEAEDF4),
            Color(0xFFF8FAFE), // bright centre
            Color(0xFFEAEDF4),
            Color(0xFFC8CCD4),
          ],
          [0.0, 0.22, 0.50, 0.78, 1.0],
        )
        ..isAntiAlias = true,
    );
    // Specular roof highlight (oval bright spot)
    cvs.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy - bh * 0.02),
        width: bw * 0.55,
        height: bh * 0.10,
      ),
      Paint()
        ..color = const Color(0x38FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // ── 10. REAR GLASS (dark) ────────────────────────────────────────
    final rgTop = cy + bh * 0.12;
    final rgBot = cy + bh * 0.30;
    final rgPath = Path()
      ..moveTo(cx - bw * 0.50, rgTop)
      ..lineTo(cx + bw * 0.50, rgTop)
      ..lineTo(cx + bw * 0.44, rgBot)
      ..lineTo(cx - bw * 0.44, rgBot)
      ..close();
    cvs.drawPath(
      rgPath,
      Paint()
        ..color = const Color(0xD0203040)
        ..isAntiAlias = true,
    );

    // ── 11. SIDE MIRRORS ─────────────────────────────────────────────
    final mirY = wsBot + h * 0.005;
    for (final s in [-1.0, 1.0]) {
      cvs.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + s * bw * 0.96, mirY),
            width: bw * 0.20,
            height: bh * 0.06,
          ),
          Radius.circular(w * 0.010),
        ),
        Paint()
          ..color = const Color(0xFFD2D6DE)
          ..isAntiAlias = true,
      );
    }

    // ── 12. HEADLIGHTS (warm white glow) ─────────────────────────────
    final hlY = front + bh * 0.08;
    for (final s in [-1.0, 1.0]) {
      final hlX = cx + s * bw * 0.55;
      cvs.drawOval(
        Rect.fromCenter(center: Offset(hlX, hlY), width: bw * 0.38, height: bh * 0.06),
        Paint()
          ..color = const Color(0x40FFFDE0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      cvs.drawOval(
        Rect.fromCenter(center: Offset(hlX, hlY), width: bw * 0.24, height: bh * 0.04),
        Paint()..color = const Color(0xFFFFFBE8)..isAntiAlias = true,
      );
    }

    // ── 13. TAILLIGHTS (red glow) ────────────────────────────────────
    final tlY = rear - bh * 0.06;
    for (final s in [-1.0, 1.0]) {
      final tlX = cx + s * bw * 0.50;
      cvs.drawOval(
        Rect.fromCenter(center: Offset(tlX, tlY), width: bw * 0.34, height: bh * 0.05),
        Paint()
          ..color = const Color(0x50FF2020)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      cvs.drawOval(
        Rect.fromCenter(center: Offset(tlX, tlY), width: bw * 0.22, height: bh * 0.035),
        Paint()..color = const Color(0xFFE83030)..isAntiAlias = true,
      );
    }

    // ── 14. FENDER BODY LINES (strong, for 3D volume) ────────────────
    for (final s in [-1.0, 1.0]) {
      final fx = cx + s * bw * 0.75;
      // Bright specular line
      cvs.drawLine(
        Offset(fx, front + bh * 0.20),
        Offset(fx, rear - bh * 0.18),
        Paint()
          ..color = const Color(0x28FFFFFF)
          ..strokeWidth = w * 0.018
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
      // Dark line just outside the specular (shadow edge)
      cvs.drawLine(
        Offset(fx + s * w * 0.020, front + bh * 0.22),
        Offset(fx + s * w * 0.020, rear - bh * 0.20),
        Paint()
          ..color = const Color(0x18000000)
          ..strokeWidth = w * 0.012
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }

    // ── 15. FRONT BUMPER ─────────────────────────────────────────────
    cvs.drawLine(
      Offset(cx - bw * 0.50, front + bh * 0.03),
      Offset(cx + bw * 0.50, front + bh * 0.03),
      Paint()
        ..color = const Color(0x28000000)
        ..strokeWidth = w * 0.012
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // ── 16. REAR BUMPER LINE ─────────────────────────────────────────
    cvs.drawLine(
      Offset(cx - bw * 0.48, rear - bh * 0.02),
      Offset(cx + bw * 0.48, rear - bh * 0.02),
      Paint()
        ..color = const Color(0x30000000)
        ..strokeWidth = w * 0.010
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // ── ENCODE ───────────────────────────────────────────────────────
    final pic = rec.endRecording();
    final img = await pic.toImage(pw, ph);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Organic sedan body — tapered nose, wider at mid/rear (Google Maps style).
  /// Kept for backward compat — new code uses inline body path in renderer.
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

  /// Renders the detailed 3D car as raw PNG bytes.
  static Future<Uint8List> _renderDetailedBytes(_CarPalette p) async {
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
    return bytes!.buffer.asUint8List();
  }

  static Future<BitmapDescriptor> _render(_CarPalette p) async {
    final pixelBytes = await _renderDetailedBytes(p);
    final cacheKey = p == _CarPalette.whitePearl ? 'white' : 'black';
    _bytesCache[cacheKey] = pixelBytes;
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

  /// Renders the SUV as raw PNG bytes (used by iOS rotation and loadForRideBytes).
  static Future<Uint8List> _renderSuvBytes(_CarPalette p) async {
    const double lw = 24, lh = 40;
    const double scale = 3.0;
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
    final pixelBytes = bytes!.buffer.asUint8List();
    _bytesCache['suv_black'] = pixelBytes;
    return pixelBytes;
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
