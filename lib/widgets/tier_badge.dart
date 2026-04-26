import 'package:flutter/material.dart';

/// Tier color/label info derived from ride name.
/// Color palette + glyph match the Choose a Vehicle horizontal card
/// (ride_request_widgets.dart) so badges look identical wherever they
/// appear: VIP=black-on-gold-border-with-diamond, PREMIUM=gold-with-
/// star, COMFORT=silver-with-sparkle.
class TierInfo {
  final List<Color> bgGradient;
  final Color textColor;
  final IconData? icon;
  final String? glyph;
  final String label;
  final bool isVIP;
  final bool isPremium;
  final bool isComfort;

  const TierInfo._({
    required this.bgGradient,
    required this.textColor,
    required this.label,
    this.icon,
    this.glyph,
    required this.isVIP,
    required this.isPremium,
    required this.isComfort,
  });

  /// Resolve tier from ride/vehicle name (case-insensitive).
  factory TierInfo.from(String rideName) {
    final n = rideName.toLowerCase();
    if (n.contains('vip') || n.contains('suv') || n.contains('suburban') ||
        n.contains('black')) {
      return const TierInfo._(
        bgGradient: [Color(0xFF1A1A1A), Color(0xFF000000)],
        textColor: Colors.white,
        label: 'VIP',
        icon: Icons.diamond,
        isVIP: true,
        isPremium: false,
        isComfort: false,
      );
    }
    if (n.contains('premium') || n.contains('camry')) {
      return const TierInfo._(
        bgGradient: [
          Color(0xFFF5DC7A),
          Color(0xFFE8C547),
          Color(0xFFB08800),
        ],
        textColor: Colors.black,
        label: 'PREMIUM',
        glyph: '★',
        isVIP: false,
        isPremium: true,
        isComfort: false,
      );
    }
    return const TierInfo._(
      bgGradient: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
      textColor: Color(0xFF1A1A1A),
      label: 'COMFORT',
      glyph: '✦',
      isVIP: false,
      isPremium: false,
      isComfort: true,
    );
  }

  /// Gradient colors for the amount card on receipts (kept for callers
  /// like trip_receipt_screen).
  List<Color> get gradient {
    if (isVIP) return const [Color(0xFF1A1A1A), Color(0xFF000000)];
    if (isPremium) return const [Color(0xFFE8C547), Color(0xFFF5D990)];
    return const [Color(0xFFB0B0B0), Color(0xFFE8E8E8)];
  }
}

/// Static fixed-size badge (78x22) — matches the Choose a Vehicle
/// horizontal card 1:1 (ride_request_widgets.dart). No shimmer / pulse;
/// same colors and glyphs across all surfaces.
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
    return SizedBox(
      width: 78,
      height: 22,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: tier.bgGradient,
          ),
          borderRadius: BorderRadius.circular(6),
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
              Icon(tier.icon, size: 9, color: tier.textColor)
            else
              Text(
                tier.glyph ?? '',
                style: TextStyle(
                  color: tier.textColor,
                  fontSize: 8,
                  height: 1,
                ),
              ),
            const SizedBox(width: 3),
            Text(
              tier.label,
              style: TextStyle(
                color: tier.textColor,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.64,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
