import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Lyft-style "Meet {tier}" detail sheet (2026-08-25): tapping a tier card
/// in the choose-a-ride sheet opens this modal — car render, title, tagline,
/// three benefit bullets, and a big "Select {tier}" pill that runs the SAME
/// flow as the sheet's own Select button (close, then the caller's
/// onSelect). Pure UI: no payment/dispatch logic lives here.
class TierDetailSheet extends StatelessWidget {
  /// Display name exactly as the rider sees it on the card ("Black",
  /// "Premium", "Compact", "Standard") — brand names, not localized.
  final String tierName;

  /// Tier key for the copy: 'black' | 'premium' | 'standard' | 'compact'.
  final String tierKey;

  /// Same car render the card uses, so the sheet feels like the card
  /// opened up rather than a different screen.
  final String carAssetPath;

  /// Runs the existing Select flow (pickup-pin page). The sheet pops
  /// itself first.
  final VoidCallback onSelect;

  /// Mirrors the main "Select {tier}" button's enabled state: when the
  /// fare is not real yet, no payment method exists, Cruise Cash comes up
  /// short, or nobody is around for an immediate request, the sheet's
  /// button shows disabled instead of starting a doomed request.
  final bool canSelect;

  const TierDetailSheet({
    super.key,
    required this.tierName,
    required this.tierKey,
    required this.carAssetPath,
    required this.onSelect,
    this.canSelect = true,
  });

  static Future<void> show(
    BuildContext context, {
    required String tierName,
    required String tierKey,
    required String carAssetPath,
    required VoidCallback onSelect,
    bool canSelect = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TierDetailSheet(
        tierName: tierName,
        tierKey: tierKey,
        carAssetPath: carAssetPath,
        onSelect: onSelect,
        canSelect: canSelect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bullets = _bullets(s);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Close affordance, top-right like Lyft's X.
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Image.asset(
                carAssetPath,
                height: 110,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.directions_car_rounded,
                  color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                  size: 64,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              s.tierMeetTitle(tierName),
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _tagline(s),
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 22),
            for (final (icon, text) in bullets) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 40,
                    child: Icon(
                      icon,
                      size: 22,
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            const SizedBox(height: 10),
            GestureDetector(
              onTap: canSelect
                  ? () {
                      Navigator.of(context).pop();
                      onSelect();
                    }
                  : null,
              child: Opacity(
                opacity: canSelect ? 1.0 : 0.4,
                child: Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8C547),
                    borderRadius: BorderRadius.circular(27),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    s.selectTierLabel(tierName),
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _tagline(S s) {
    switch (tierKey) {
      case 'black':
        return s.tierTaglineBlack;
      case 'premium':
        return s.tierTaglinePremium;
      case 'standard':
        return s.tierTaglineStandard;
      default:
        return s.tierTaglineCompact;
    }
  }

  List<(IconData, String)> _bullets(S s) {
    switch (tierKey) {
      case 'black':
        return [
          (Icons.directions_car_rounded, s.tierBulletBlack1),
          (Icons.diamond_rounded, s.tierBulletBlack2),
          (Icons.workspace_premium_rounded, s.tierBulletBlack3),
        ];
      case 'premium':
        return [
          (Icons.directions_car_rounded, s.tierBulletPremium1),
          (Icons.airline_seat_legroom_extra_rounded, s.tierBulletPremium2),
          (Icons.workspace_premium_rounded, s.tierBulletPremium3),
        ];
      case 'standard':
        return [
          (Icons.directions_car_rounded, s.tierBulletStandard1),
          (Icons.airline_seat_legroom_extra_rounded, s.tierBulletStandard2),
          (Icons.workspace_premium_rounded, s.tierBulletStandard3),
        ];
      default:
        return [
          (Icons.directions_car_rounded, s.tierBulletCompact1),
          (Icons.savings_rounded, s.tierBulletCompact2),
          (Icons.group_rounded, s.tierBulletCompact3),
        ];
    }
  }
}
