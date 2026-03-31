import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../smart_map_pin.dart';

/// Unified golden teardrop map pin renderer with consistent styling across all screens.
/// Creates classic golden drop-shaped pins with 3D glossy shine, ground shadow,
/// and smart white Material icons inside the circular head.

/// Pin icon types for different location contexts
enum CircularPinIcon { 
  dot,        // Simple dot (pickup location)
  flag,       // Flag marker (dropoff location)
  person,     // Person icon (rider location)
  home,       // House icon (home address)
  store,      // Store/shop icon (commercial location)
  airplane,   // Airplane icon (airport)
}

/// Detects the appropriate icon from an address label
CircularPinIcon detectCircularPinIcon(String label) {
  final l = label.toLowerCase();
  
  // Airport detection
  if (l.contains('airport') ||
      l.contains('terminal') ||
      RegExp(
        r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b',
      ).hasMatch(l)) {
    return CircularPinIcon.airplane;
  }
  
  // Commercial location detection
  if (l.contains('store') ||
      l.contains('shop') ||
      l.contains('mall') ||
      l.contains('plaza') ||
      l.contains('market') ||
      l.contains('center') ||
      l.contains('restaurant') ||
      l.contains('hotel') ||
      l.contains('bar') ||
      l.contains('café') ||
      l.contains('cafe') ||
      l.contains('gym') ||
      l.contains('salon') ||
      l.contains('office') ||
      l.contains('hospital') ||
      l.contains('clinic') ||
      l.contains('bank') ||
      l.contains('pharmacy')) {
    return CircularPinIcon.store;
  }
  
  // Residential address detection (street number + street type)
  if (RegExp(r'^\d+\s').hasMatch(l) &&
      RegExp(
        r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b',
      ).hasMatch(l)) {
    return CircularPinIcon.home;
  }
  
  return CircularPinIcon.flag;
}

/// Maps the legacy [CircularPinIcon] enum to Material [IconData].
IconData _iconDataFor(CircularPinIcon icon) {
  switch (icon) {
    case CircularPinIcon.dot:      return Icons.my_location;
    case CircularPinIcon.flag:     return Icons.location_on;
    case CircularPinIcon.person:   return Icons.person;
    case CircularPinIcon.home:     return Icons.home;
    case CircularPinIcon.store:    return Icons.storefront;
    case CircularPinIcon.airplane: return Icons.flight_takeoff;
  }
}

/// Renders a teardrop map pin as PNG bytes.
/// 
/// [icon] — icon type to render inside the pin head
/// [isPickup] — true → emerald green (pickup), false → bold red (dropoff)
/// [radius] — base radius; final pin width = radius * 2 + 16
/// 
/// Results are cached by (icon, isPickup, radius) key for performance.
Future<Uint8List> renderCircularPinBytes({
  CircularPinIcon icon = CircularPinIcon.dot,
  bool isPickup = true,
  double radius = 44.0,
}) async {
  final pinSize = (radius * 2 + 16).roundToDouble();
  return buildGoldenPinBytes(
    icon: _iconDataFor(icon),
    size: pinSize,
    isPickup: isPickup,
  );
}

/// Widget wrapper for the golden pin (for use in Stack overlays)
class CircularMapPin extends StatelessWidget {
  final CircularPinIcon icon;
  final bool isPickup;
  final double size;

  const CircularMapPin({
    super.key,
    this.icon = CircularPinIcon.dot,
    this.isPickup = true,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: buildGoldenPinBytes(
        icon: _iconDataFor(icon),
        size: size,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox(width: size, height: size * 1.3);
        }
        return Image.memory(
          snapshot.data!,
          width: size,
          height: size * 1.3,
          fit: BoxFit.contain,
        );
      },
    );
  }
}
