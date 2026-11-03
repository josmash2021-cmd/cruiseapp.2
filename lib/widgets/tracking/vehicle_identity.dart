import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ota_image.dart';

/// The car the rider is looking for, the same everywhere it shows — the trip
/// sheet and the driver-arrived screen (owner 2026-11-03: "placa, color del
/// carro… y el carro como en el sheet"): a small color square + make and
/// model, the category's car render, the plate — whole, never cut.

/// The category's render, the same one the vehicle picker showed.
String vehicleRenderAsset({required String rideName, required String model}) {
  final rn = rideName.toLowerCase();
  final m = model.toLowerCase();
  // Electric Pro's own render; every Image.asset of it falls back to the
  // compact SUV on older bundles (OTA rule 2026-10-13) — see VehicleRender.
  if (rn.contains('electric')) return 'assets/images/car_electric.png';
  if (rn.contains('vip') ||
      rn.contains('black') ||
      rn.contains('suv') ||
      rn.contains('suburban') ||
      m.contains('suburban')) {
    return 'assets/images/cruisert1.png';
  }
  if (rn.contains('sedan') ||
      rn.contains('premium') ||
      rn.contains('camry') ||
      m.contains('camry')) {
    return 'assets/images/cruisert2.png';
  }
  // comfort / fusion and anything unrecognised — the picker sends the
  // Fusion here too, so both screens show the rider the same car.
  return 'assets/images/cruisert3.png';
}

const Map<String, Color> _kVehicleSwatches = {
  'black': Color(0xFF000000), 'negro': Color(0xFF000000),
  'white': Color(0xFFFFFFFF), 'blanco': Color(0xFFFFFFFF),
  'silver': Color(0xFFC0C0C0), 'plata': Color(0xFFC0C0C0),
  'plateado': Color(0xFFC0C0C0),
  'gray': Color(0xFF7D7D7D), 'grey': Color(0xFF7D7D7D),
  'gris': Color(0xFF7D7D7D),
  'red': Color(0xFFC62828), 'rojo': Color(0xFFC62828),
  'blue': Color(0xFF1E4FA3), 'azul': Color(0xFF1E4FA3),
  'navy': Color(0xFF1B2A4A), 'dark blue': Color(0xFF1B2A4A),
  'green': Color(0xFF2E7D32), 'verde': Color(0xFF2E7D32),
  'beige': Color(0xFFD9C7A3), 'champagne': Color(0xFFE5D3B3),
  'brown': Color(0xFF6D4C41), 'marrón': Color(0xFF6D4C41),
  'marron': Color(0xFF6D4C41), 'café': Color(0xFF6D4C41),
  'cafe': Color(0xFF6D4C41),
  'gold': Color(0xFFC9A227), 'dorado': Color(0xFFC9A227),
  'yellow': Color(0xFFF2C200), 'amarillo': Color(0xFFF2C200),
  'orange': Color(0xFFEF6C00), 'naranja': Color(0xFFEF6C00),
  'maroon': Color(0xFF6A1B1A), 'burgundy': Color(0xFF6A1B1A),
  'vino': Color(0xFF6A1B1A),
  'purple': Color(0xFF5E35B1), 'morado': Color(0xFF5E35B1),
};

/// The car's color as a square (owner 2026-11-03: "el color será un
/// cuadrito"), from the color word the driver registered (EN or ES). Null
/// when the word is not one we know — the word is shown instead.
Color? vehicleSwatchColor(String name) {
  final n = name.trim().toLowerCase();
  if (n.isEmpty) return null;
  return _kVehicleSwatches[n] ?? _kVehicleSwatches[n.split(RegExp(r'\s+')).last];
}

/// Splits a leading color off a one-string description ("Black Chevrolet
/// Suburban" → ("Black", "Chevrolet Suburban")); an unknown first word keeps
/// the whole text with no color.
(String, String) splitVehicleColor(String desc) {
  final t = desc.trim();
  final lower = t.toLowerCase();
  String? hit;
  for (final name in _kVehicleSwatches.keys) {
    if (lower.startsWith('$name ') && (hit == null || name.length > hit.length)) {
      hit = name;
    }
  }
  if (hit == null) return ('', t);
  return (t.substring(0, hit.length), t.substring(hit.length).trim());
}

/// The category's car on a soft ground shadow (the trip sheet's look).
class VehicleRender extends StatelessWidget {
  const VehicleRender({
    super.key,
    required this.asset,
    this.width = 92,
    this.height = 34,
  });

  final String asset;
  final double width;
  final double height;

  /// The electric PNG is not in older bundles (Shorebird patches carry no
  /// new assets): it tries the backend-hosted copy (/static), then the
  /// compact SUV bundled since release; every other asset falls to [icon].
  Widget _fallback(Widget icon) {
    if (!asset.endsWith('car_electric.png')) return icon;
    return otaImageFallback(
      'car_electric.png',
      Image.asset(
        'assets/images/cruisert_compact.png',
        width: double.infinity,
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => icon,
      ),
      width: double.infinity,
      height: height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = height;
    return SizedBox(
      width: width,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 6,
            right: 6,
            bottom: h * 0.04,
            height: h * 0.24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, 2),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: Image.asset(
                asset,
                width: double.infinity,
                height: h,
                fit: BoxFit.contain,
                color: Colors.black.withValues(alpha: 0.5),
                colorBlendMode: BlendMode.srcIn,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          Image.asset(
            asset,
            width: double.infinity,
            height: h,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _fallback(
              Icon(
                Icons.directions_car_rounded,
                color: const Color(0xFFFFD700).withValues(alpha: 0.5),
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Color square + "Chevrolet Suburban" (no color word when the square says
/// it), the car render, the plate chip — right-aligned, as wide as the words
/// need up to [maxWidth]; the words wrap to two lines rather than being cut,
/// and a long plate scales down rather than being cut.
class VehicleIdentityColumn extends StatelessWidget {
  const VehicleIdentityColumn({
    super.key,
    required this.colorWord,
    required this.name,
    required this.plate,
    required this.asset,
    this.minWidth = 92,
    this.maxWidth = 165,
    this.renderWidth = 92,
    this.renderHeight = 34,
  });

  final String colorWord;
  final String name;
  final String plate;
  final String asset;
  final double minWidth;
  final double maxWidth;
  final double renderWidth;
  final double renderHeight;

  @override
  Widget build(BuildContext context) {
    final swatch = vehicleSwatchColor(colorWord);
    final label = [
      if (swatch == null) colorWord,
      name,
    ].where((v) => v.trim().isNotEmpty).join(' ');
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (swatch != null) ...[
                  Container(
                    key: const ValueKey('vehicle-color-swatch'),
                    margin: const EdgeInsets.only(top: 2),
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: swatch,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.4)),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 3),
          VehicleRender(asset: asset, width: renderWidth, height: renderHeight),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(5),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                plate.trim().isNotEmpty ? plate.toUpperCase() : '---',
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
