import 'package:flutter/material.dart';

/// How a vehicle tier looks, in one place.
///
/// Standard / Compact / Premium / Black. The backend decides which tier a
/// car earns (`backend/services/vehicle_tiers.py`); this decides what the
/// rider and the driver see when it does.
///
/// It exists because the mapping was written twice — once in the rider's
/// ride picker and once on the driver's vehicle page — and had already
/// drifted: the driver page still knew only VIP, PREMIUM and COMFORT, so
/// a Black driver read "COMFORT" under a green leaf.
///
/// Every function here takes the raw `vehicle_type` string and normalises
/// it first, so the old names keep working until the rows are migrated.

/// The four canonical keys, worst to best.
const kTierStandard = 'standard';
const kTierCompact = 'compact';
const kTierPremium = 'premium';
const kTierBlack = 'black';

const kVehicleTiers = <String>[
  kTierStandard,
  kTierCompact,
  kTierPremium,
  kTierBlack,
];

/// Old strings still in the database, and the display names the rider app
/// sends ("SUV XL"). Mirrors LEGACY_TIER_MAP on the backend.
const _aliases = <String, String>{
  'comfort': kTierStandard,
  'sedan': kTierStandard,
  'economy': kTierStandard,
  'suv': kTierCompact,
  'rav4': kTierCompact,
  // A Traverse: three rows, six seats. Premium, not Black — Black is the
  // seven-seat tier.
  'suv_xl': kTierPremium,
  'suvxl': kTierPremium,
  'vip': kTierBlack,
  'luxury': kTierBlack,
  'suburban': kTierBlack,
};

/// Tokens to look for inside a free-text name, most specific first.
///
/// Order is the whole point: "suv_xl" has to be tested before "suv", or
/// an SUV XL reads as a compact and the rider is shown a RAV4 for a
/// six-seat booking.
const _textTokens = <(String, String)>[
  ('suv_xl', kTierPremium),
  ('suvxl', kTierPremium),
  ('suburban', kTierBlack),
  ('escalade', kTierBlack),
  ('luxury', kTierBlack),
  ('black', kTierBlack),
  ('vip', kTierBlack),
  ('premium', kTierPremium),
  ('compact', kTierCompact),
  ('rav4', kTierCompact),
  ('suv', kTierCompact),
  ('standard', kTierStandard),
  ('comfort', kTierStandard),
  ('economy', kTierStandard),
  ('sedan', kTierStandard),
];

/// Any tier string as one of the four — new, old, spaced, hyphenated, or
/// a display name with the tier buried in it ("Cruise VIP").
///
/// Anything unrecognised reads as Standard, which is what an
/// unclassified car gets anyway.
String tierKey(String? raw) {
  final k = (raw ?? '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[ \-]'), '_');
  if (k.isEmpty) return kTierStandard;
  if (kVehicleTiers.contains(k)) return k;
  final alias = _aliases[k];
  if (alias != null) return alias;
  for (final (token, tier) in _textTokens) {
    if (k.contains(token)) return tier;
  }
  return kTierStandard;
}

/// The car the rider is shown when picking this tier.
///
/// A rider choosing a six-seater is choosing it for the seats, so the
/// picture is the whole promise — and the driver has to see the same
/// shape on their own vehicle page.
///
/// All four are the `cruisert*` set: the same side profile, the same
/// black-and-gold render, shot from the same angle. The older `cruise_3`
/// / `cruise_6` / `cruise_7` files are three-quarter views, so mixing
/// them in meant Standard and Black faced the camera while Compact and
/// Premium stood side-on, in a row where they sit next to each other.
String tierCarImage(String? raw) {
  switch (tierKey(raw)) {
    case kTierBlack:
      return 'assets/images/cruisert1.png'; // Tahoe / Suburban
    case kTierPremium:
      return 'assets/images/cruisert_suvxl.png'; // Traverse, three rows
    case kTierCompact:
      return 'assets/images/cruisert_compact.png'; // RAV4
    default:
      return 'assets/images/cruisert3.png'; // Fusion, a saloon
  }
}

/// Uppercase, because every place that shows it shows it uppercase.
String tierLabel(String? raw) => tierKey(raw).toUpperCase();

/// Premium and Black keep the colours they have always had. The two new
/// tiers take the gap below them.
Color tierColor(String? raw) {
  switch (tierKey(raw)) {
    case kTierBlack:
      return const Color(0xFFD4A843);
    case kTierPremium:
      return const Color(0xFFB0BEC5);
    case kTierCompact:
      return const Color(0xFF66BB6A);
    default:
      return const Color(0xFF9E9E9E);
  }
}

IconData tierIcon(String? raw) {
  switch (tierKey(raw)) {
    case kTierBlack:
      return Icons.star_rounded;
    case kTierPremium:
      return Icons.diamond_rounded;
    case kTierCompact:
      return Icons.eco_rounded;
    default:
      return Icons.directions_car_rounded;
  }
}

/// The driver's share of the fare, as a fraction. Mirrors COMMISSION in
/// backend/services/vehicle_tiers.py — the backend is the authority; this
/// is only for showing a driver what a tier is worth.
double tierDriverShare(String? raw) {
  switch (tierKey(raw)) {
    case kTierBlack:
      return 0.70;
    case kTierPremium:
      return 0.65;
    case kTierCompact:
      return 0.62;
    default:
      return 0.60;
  }
}
