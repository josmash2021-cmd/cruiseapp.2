import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'navatar_sprite_generator.dart';

/// Available Navatar car models — same set as Google Maps Navatars.
enum NavatarModel {
  sedan,
  suv,
  pickup,
  cityCar,
  sports,
  classic,
}

/// Extension to get asset folder name for each navatar model.
extension NavatarModelX on NavatarModel {
  String get assetName {
    switch (this) {
      case NavatarModel.sedan:
        return 'sedan';
      case NavatarModel.suv:
        return 'suv';
      case NavatarModel.pickup:
        return 'pickup';
      case NavatarModel.cityCar:
        return 'city_car';
      case NavatarModel.sports:
        return 'sports';
      case NavatarModel.classic:
        return 'classic';
    }
  }

  String get displayName {
    switch (this) {
      case NavatarModel.sedan:
        return 'Sedan';
      case NavatarModel.suv:
        return 'SUV';
      case NavatarModel.pickup:
        return 'Pickup Truck';
      case NavatarModel.cityCar:
        return 'City Car';
      case NavatarModel.sports:
        return 'Sports Car';
      case NavatarModel.classic:
        return 'Classic Sedan';
    }
  }

  /// Icon to show in the picker UI.
  IconData get icon {
    switch (this) {
      case NavatarModel.sedan:
        return Icons.directions_car;
      case NavatarModel.suv:
        return Icons.directions_car_filled;
      case NavatarModel.pickup:
        return Icons.local_shipping;
      case NavatarModel.cityCar:
        return Icons.electric_car;
      case NavatarModel.sports:
        return Icons.sports_score;
      case NavatarModel.classic:
        return Icons.directions_car_outlined;
    }
  }
}

/// Loads and manages 3D-style navigation car sprites (Navatars).
///
/// Each navatar has 8 directional sprites rendered from 3D models at
/// 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315° — same technique
/// Google Maps uses for its navigation car icons.
///
/// Sprites live in: `assets/images/navatars/{model}/navatar_{model}_{angle}.png`
///
/// Usage:
/// ```dart
/// // Load sprites for a specific car
/// await NavatarLoader.loadSprites(NavatarModel.sedan);
///
/// // Get the right sprite for the current heading
/// final icon = NavatarLoader.spriteForAngle(NavatarModel.sedan, viewAngle);
///
/// // For Apple Maps (needs raw bytes + manual rotation)
/// final bytes = await NavatarLoader.rotatedBytes(NavatarModel.suv, heading);
/// ```
class NavatarLoader {
  NavatarLoader._();

  // ── Constants ──────────────────────────────────────────────────────
  static const List<int> _angles = [0, 45, 90, 135, 180, 225, 270, 315];
  static const double _spriteTargetWidth = 48.0;
  static const double _spriteScale = 3.0;

  // ── Caches ─────────────────────────────────────────────────────────
  /// {modelName: [8 BitmapDescriptors]}
  static final Map<String, List<BitmapDescriptor>> _spriteCache = {};

  /// {modelName: [8 Uint8List PNG bytes]}
  static final Map<String, List<Uint8List>> _bytesCache = {};

  /// {modelName_angle: Uint8List} for pre-rotated Apple Maps icons
  static final Map<String, Uint8List> _rotatedCache = {};

  /// Currently selected navatar model.
  static NavatarModel _current = NavatarModel.sedan;

  /// Get/set the active navatar model.
  static NavatarModel get current => _current;
  static set current(NavatarModel model) {
    _current = model;
  }

  /// Clear all caches (call on memory warning or model change).
  static void invalidate() {
    _spriteCache.clear();
    _bytesCache.clear();
    _rotatedCache.clear();
  }

  // ── Loading ────────────────────────────────────────────────────────

  /// Loads 8 directional sprites for [model] from assets.
  /// Falls back to Canvas-generated 3D sprites if PNGs are missing.
  static Future<List<BitmapDescriptor>?> loadSprites(NavatarModel model) async {
    final key = model.assetName;
    if (_spriteCache.containsKey(key)) return _spriteCache[key];

    // Try loading PNG assets first
    final sprites = <BitmapDescriptor>[];
    final bytesList = <Uint8List>[];
    final int targetPx = (_spriteTargetWidth * _spriteScale).round();
    bool pngOk = true;

    for (final angle in _angles) {
      try {
        final path = 'assets/images/navatars/$key/navatar_${key}_$angle.png';
        final data = await rootBundle.load(path);
        final raw = data.buffer.asUint8List();
        if (raw.isEmpty) { pngOk = false; break; }

        final codec = await ui.instantiateImageCodec(
          raw,
          targetWidth: targetPx,
        );
        final frame = await codec.getNextFrame();
        final resized = frame.image;
        final byteData =
            await resized.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) { pngOk = false; break; }
        final resizedBytes = byteData.buffer.asUint8List();

        // ignore: deprecated_member_use
        sprites.add(BitmapDescriptor.fromBytes(resizedBytes));
        bytesList.add(resizedBytes);
      } catch (_) {
        pngOk = false;
        break;
      }
    }

    if (pngOk && sprites.length == 8) {
      _spriteCache[key] = sprites;
      _bytesCache[key] = bytesList;
      return sprites;
    }

    // Fallback: generate 3D sprites with Canvas
    return _generateAndCache(key);
  }

  /// Generate 3D sprites via Canvas when PNG assets are unavailable.
  static Future<List<BitmapDescriptor>?> _generateAndCache(String key) async {
    try {
      final genBytes = await NavatarSpriteGenerator.generateAll();
      if (genBytes.length != 8) return null;
      final genSprites = <BitmapDescriptor>[];
      for (final b in genBytes) {
        // ignore: deprecated_member_use
        genSprites.add(BitmapDescriptor.fromBytes(b));
      }
      _spriteCache[key] = genSprites;
      _bytesCache[key] = genBytes;
      return genSprites;
    } catch (_) {
      return null;
    }
  }

  /// Loads sprites for the currently selected navatar.
  static Future<List<BitmapDescriptor>?> loadCurrentSprites() =>
      loadSprites(_current);

  /// Preloads all navatar models so switching is instant.
  static Future<void> preloadAll() async {
    for (final model in NavatarModel.values) {
      await loadSprites(model);
    }
  }

  // ── Sprite Selection ───────────────────────────────────────────────

  /// Returns the sprite index (0–7) for a given view angle.
  /// viewAngle = (carHeading − cameraBearing + 360) % 360
  static int indexForAngle(double viewAngleDeg) {
    final a = ((viewAngleDeg % 360) + 360) % 360;
    return ((a + 22.5) / 45).floor() % 8;
  }

  /// Returns the BitmapDescriptor for [model] at [viewAngleDeg].
  /// Returns null if sprites haven't been loaded.
  static BitmapDescriptor? spriteForAngle(
    NavatarModel model,
    double viewAngleDeg,
  ) {
    final sprites = _spriteCache[model.assetName];
    if (sprites == null || sprites.length < 8) return null;
    return sprites[indexForAngle(viewAngleDeg)];
  }

  /// Returns sprite for the currently selected model.
  static BitmapDescriptor? currentSpriteForAngle(double viewAngleDeg) =>
      spriteForAngle(_current, viewAngleDeg);

  // ── Raw Bytes (for Apple Maps / custom rendering) ──────────────────

  /// Returns raw PNG bytes for [model] at [viewAngleDeg].
  static Uint8List? bytesForAngle(NavatarModel model, double viewAngleDeg) {
    final bytes = _bytesCache[model.assetName];
    if (bytes == null || bytes.length < 8) return null;
    return bytes[indexForAngle(viewAngleDeg)];
  }

  /// Returns rotated PNG bytes for Apple Maps (no native marker rotation).
  /// Quantized to 5° increments and cached.
  static Future<Uint8List?> rotatedBytes(
    NavatarModel model,
    double degrees,
  ) async {
    final key = model.assetName;
    final q = ((degrees % 360) / 5).round() * 5;
    final cacheKey = '${key}_$q';

    if (_rotatedCache.containsKey(cacheKey)) return _rotatedCache[cacheKey];

    // Use the 0° (rear view) sprite as base for rotation
    final baseBytes = _bytesCache[key];
    if (baseBytes == null || baseBytes.isEmpty) {
      // Try loading first
      await loadSprites(model);
      final loaded = _bytesCache[key];
      if (loaded == null || loaded.isEmpty) return null;
    }

    final base = _bytesCache[key]![0]; // 0° = rear view
    if (q == 0) {
      _rotatedCache[cacheKey] = base;
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

    _rotatedCache[cacheKey] = bytes;
    src.dispose();
    img.dispose();
    return bytes;
  }

  // ── Picker Helper ──────────────────────────────────────────────────

  /// Returns preview image bytes for the picker UI (front-angled view).
  /// Uses the 180° sprite (front-facing).
  static Uint8List? previewBytes(NavatarModel model) {
    final bytes = _bytesCache[model.assetName];
    if (bytes == null || bytes.length < 8) return null;
    return bytes[4]; // index 4 = 180° = front view
  }
}
