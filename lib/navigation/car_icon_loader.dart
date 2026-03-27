import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'navatar_loader.dart';

part '../assets/car_icon_data.dart';
part 'car_renderers.dart';

class CarIconLoader {
  CarIconLoader._();

  static final Map<String, Uint8List> _bytesCache = {};

  static Future<Uint8List?> load() => loadUberBytes();

  static Future<Uint8List?> loadForVehicle(String rideName) =>
      loadForRideBytes(rideName);

  static Future<Uint8List?> loadDriverIcon() => loadUberBytes();

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

  /// Cached multi-angle sprites as raw bytes (index 0-7).
  static List<Uint8List>? _navSprites;

  /// Target marker size in logical pixels. Sprites are resized to this
  /// width (height scales proportionally) so they aren't oversized on the map.
  static const double _spriteTargetWidth = 40.0;

  /// Loads 8 directional PNG sprites for the navigation car marker.
  /// Uses different car images based on ride type.
  static Future<List<Uint8List>?> loadNavCarSprites({String rideType = 'sedan'}) async {
    if (_navSprites != null) return _navSprites;

    final bytes = await loadUberBytes(rideType: rideType);
    if (bytes == null) return null;

    // Use the same image for all 8 angles (rotation handled by Mapbox)
    _navSprites = List.generate(8, (_) => bytes);
    return _navSprites;
  }

  /// Given the view angle (carHeading − cameraBearing), returns the
  /// appropriate sprite index (0–7). Snaps to nearest 45°.
  static int spriteIndexForAngle(double viewAngleDeg) {
    final a = ((viewAngleDeg % 360) + 360) % 360; // normalize 0–360
    final idx = ((a + 22.5) / 45).floor() % 8;
    return idx;
  }

  /// Returns the sprite bytes for a given view angle.
  /// Returns null if sprites haven't been loaded.
  static Uint8List? spriteForViewAngle(double viewAngleDeg) {
    if (_navSprites == null || _navSprites!.length < 8) return null;
    return _navSprites![spriteIndexForAngle(viewAngleDeg)];
  }

  /// Returns raw PNG bytes for a 3D animated vehicle marker.
  /// Uses Canvas renderer with 3D shading and depth effects.
  /// SUV -> 3D black SUV, Comfort -> 3D white sedan, Sedan -> 3D black sedan
  static Future<Uint8List?> loadUberBytes({String rideType = 'sedan'}) async {
    final key = rideType.toLowerCase().trim();
    String cacheKey;
    _CarPalette palette;
    bool isSuv = false;
    
    if (key.contains('suv') || key.contains('suburban')) {
      cacheKey = 'suv_black';
      palette = _CarPalette.black;
      isSuv = true;
    } else if (key.contains('comfort') || key.contains('white')) {
      cacheKey = 'white';
      palette = _CarPalette.whitePearl;
    } else {
      // sedan, fusion, default
      cacheKey = 'black';
      palette = _CarPalette.black;
    }
    
    if (_bytesCache.containsKey(cacheKey)) return _bytesCache[cacheKey];
    
    // Use 3D Canvas renderer instead of static PNG
    Uint8List bytes;
    if (isSuv) {
      bytes = await _renderSuvBytes(palette);
    } else {
      bytes = await _renderDetailedBytes(palette);
    }
    _bytesCache[cacheKey] = bytes;
    return bytes;
  }

  /// Returns raw PNG bytes for a ride-specific icon.
  /// SUV -> 3D black SUV render
  /// Comfort -> 3D white sedan render  
  /// Sedan -> 3D black sedan render
  static Future<Uint8List?> loadForRideBytes(String rideName) async {
    final key = rideName.trim().toLowerCase();
    if (key.contains('suv') || key.contains('suburban')) {
      return loadUberBytes(rideType: 'suv');
    } else if (key.contains('comfort')) {
      return loadUberBytes(rideType: 'comfort');
    } else {
      return loadUberBytes(rideType: 'sedan');
    }
  }

  static void invalidate() {
    _bytesCache.clear();
    _cardCache.clear();
    _rotatedCache.clear();
    _rotatedCacheByType.clear();
    _navSprites = null;
    NavatarLoader.invalidate();
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
  /// Supports SUV (black), Comfort (white), Sedan (black).
  static Future<Uint8List> rotateBytesForRide(
    double degrees, {
    String rideName = 'sedan',
  }) async {
    final key = rideName.trim().toLowerCase();
    final String typeKey;
    if (key.contains('suv') || key.contains('suburban')) {
      typeKey = 'suv_black';
    } else if (key.contains('comfort')) {
      typeKey = 'white';
    } else {
      typeKey = 'black';
    }

    final q = ((degrees % 360) / 5).round() * 5;
    final cache = _rotatedCacheByType.putIfAbsent(typeKey, () => {});
    if (cache.containsKey(q)) return cache[q]!;

    // Get base bytes for this car type
    Uint8List? base;
    if (typeKey == 'suv_black') {
      base = _bytesCache['suv_black'] ?? await loadUberBytes(rideType: 'suv');
    } else if (typeKey == 'white') {
      base = _bytesCache['white'] ?? await loadUberBytes(rideType: 'comfort');
    } else {
      base = _bytesCache['black'] ?? await loadUberBytes(rideType: 'sedan');
    }
    if (base == null) throw Exception('Failed to load car icon');

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
  /// Supports SUV (black), Comfort (white), Sedan (black).
  static Future<ui.Image> renderCardImage(String rideName) async {
    final key = rideName.trim().toLowerCase();
    final String cacheKey;
    String rideType;
    if (key.contains('suv') || key.contains('suburban')) {
      cacheKey = 'card_suv';
      rideType = 'suv';
    } else if (key.contains('comfort')) {
      cacheKey = 'card_comfort';
      rideType = 'comfort';
    } else {
      cacheKey = 'card_sedan';
      rideType = 'sedan';
    }
    if (_cardCache.containsKey(cacheKey)) return _cardCache[cacheKey]!;

    // Load the appropriate PNG and decode to ui.Image
    final bytes = await loadUberBytes(rideType: rideType);
    if (bytes == null) throw Exception('Failed to load car image');

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    _cardCache[cacheKey] = img;
    return img;
  }
}
