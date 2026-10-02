import 'package:flutter/material.dart';

import '../utils/vehicle_tier_style.dart';

/// Tier color/label info derived from a trip's ride name.
///
/// The catalogue is the current four — Standard / Compact / Premium /
/// Black — resolved through [tripTierKey], so rows that still carry a
/// legacy booking name ("Comfort", "SUV XL", "VIP") read in the current
/// names everywhere this badge appears. Black keeps the old VIP look
/// (black-on-gold-border-with-diamond), Premium the gold-with-star,
/// Standard the silver-with-sparkle; Compact takes the green gap.
class TierInfo {
  final List<Color> bgGradient;
  final Color textColor;
  final IconData? icon;
  final String? glyph;
  final String label;
  final bool isVIP;
  final bool isPremium;
  final bool isComfort;
  final bool isCompact;

  const TierInfo._({
    required this.bgGradient,
    required this.textColor,
    required this.label,
    this.icon,
    this.glyph,
    required this.isVIP,
    required this.isPremium,
    required this.isComfort,
    required this.isCompact,
  });

  /// Resolve tier from ride/vehicle name (case-insensitive).
  factory TierInfo.from(String rideName) {
    switch (tripTierKey(rideName)) {
      case kTierBlack:
        return const TierInfo._(
          bgGradient: [Color(0xFF1A1A1A), Color(0xFF000000)],
          textColor: Colors.white,
          label: 'Black',
          icon: Icons.diamond,
          isVIP: true,
          isPremium: false,
          isComfort: false,
          isCompact: false,
        );
      case kTierPremium:
        return const TierInfo._(
          bgGradient: [
            Color(0xFFF5DC7A),
            Color(0xFFE8C547),
            Color(0xFFB08800),
          ],
          textColor: Colors.black,
          label: 'Premium',
          glyph: '★',
          isVIP: false,
          isPremium: true,
          isComfort: false,
          isCompact: false,
        );
      case kTierCompact:
        return const TierInfo._(
          bgGradient: [Color(0xFF9CCC9E), Color(0xFF4E9A51)],
          textColor: Color(0xFF0B2E0D),
          label: 'Compact',
          icon: Icons.eco_rounded,
          isVIP: false,
          isPremium: false,
          isComfort: false,
          isCompact: true,
        );
      default:
        return const TierInfo._(
          bgGradient: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
          textColor: Color(0xFF1A1A1A),
          label: 'Standard',
          glyph: '✦',
          isVIP: false,
          isPremium: false,
          isComfort: true,
          isCompact: false,
        );
    }
  }

  /// Gradient colors for the amount card on receipts (kept for callers
  /// like trip_receipt_screen).
  List<Color> get gradient {
    if (isVIP) return const [Color(0xFF1A1A1A), Color(0xFF000000)];
    if (isPremium) return const [Color(0xFFE8C547), Color(0xFFF5D990)];
    if (isCompact) return const [Color(0xFF66BB6A), Color(0xFF43A047)];
    return const [Color(0xFFB0B0B0), Color(0xFFE8E8E8)];
  }

  /// Human-readable ride title from the raw vehicle_type value, in the
  /// current catalogue: "Comfort" -> "Standard", "SUV XL" -> "Premium",
  /// "VIP" -> "Black", "Sedan" -> "Compact".
  static String displayTitle(String rideName) {
    final k = tripTierKey(rideName);
    return k[0].toUpperCase() + k.substring(1);
  }
}

/// Auto-width badge showing the real ride title ("Standard", "Black
/// Premium") with the tier's colors/glyph: BLACK=black-on-gold-border-
/// with-diamond, PREMIUM=gold-with-star, COMPACT=green-with-leaf,
/// STANDARD=silver-with-sparkle.
class TierBadge extends StatelessWidget {
  final String rideName;

  const TierBadge({
    super.key,
    required this.rideName,
    // Kept for backward-compat with old call sites; not used.
    double fontSize = 8,
    double iconSize = 9,
  });

  @override
  Widget build(BuildContext context) {
    final tier = TierInfo.from(rideName);
    // No `alignment` on this Container: with alignment set it expands to
    // the max width its parent offers (in a Wrap, the whole row) instead
    // of shrink-wrapping the label.
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tier.bgGradient,
        ),
        borderRadius: BorderRadius.circular(7),
        border: tier.isVIP
            ? Border.all(
                color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                width: 1,
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tier.icon != null)
            Icon(tier.icon, size: 10, color: tier.textColor)
          else
            Text(
              tier.glyph ?? '',
              style: TextStyle(
                color: tier.textColor,
                fontSize: 9,
                height: 1,
              ),
            ),
          const SizedBox(width: 4),
          Text(
            tier.label,
            style: TextStyle(
              color: tier.textColor,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
