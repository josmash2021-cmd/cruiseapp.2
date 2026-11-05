import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/glass_style.dart';
import '../../widgets/map/heat_flame.dart';
import 'reservation_offer_card.dart';

/// "Hoover · 2.1 mi · 7 min" — the place, then the drive, when known.
String heatZoneSubtitle(String place, double? miles, int? minutes) {
  final parts = <String>[
    if (place.trim().isNotEmpty) place.trim(),
    if (miles != null && miles.isFinite) '${miles.toStringAsFixed(1)} mi',
    if (minutes != null) '${minutes < 1 ? 1 : minutes} min',
  ];
  return parts.join(' · ');
}

/// A heat cloud, tapped (owner 2026-11-05, Lyft's "BHM Queue · Navigate to
/// queue"): the sheet's glass in its place — the flame, "Zona con
/// pasajeros", place · miles · minutes, an X, and "Navegar a la zona".
class HeatZoneCard extends StatelessWidget {
  const HeatZoneCard({
    super.key,
    required this.subtitle,
    required this.onClose,
    required this.onNavigate,
    this.bottomInset = 0,
  });

  /// Null while the place and the drive are still being looked up.
  final String? subtitle;
  final VoidCallback onClose;

  /// Null until there is somewhere to drive to.
  final VoidCallback? onNavigate;

  /// The home indicator's inset: the button stays clear of it.
  final double bottomInset;

  static const Key closeKey = ValueKey('heat-zone-card-close');

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final sub = subtitle;
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      tint: glassSheetTint,
      roundFrostOnIOS: true,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 16 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Color(0xFF0B0B0F),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: CustomPaint(
                          size: Size.square(24),
                          painter: HeatFlamePainter(outline: false),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.heatZoneTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Text(
                              sub ?? s.heatZoneNearby,
                              key: ValueKey(sub ?? ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.62),
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Room for the X.
                    const SizedBox(width: 30),
                  ],
                ),
                const SizedBox(height: 18),
                Opacity(
                  opacity: onNavigate == null ? 0.5 : 1,
                  child: ReserveOfferButton(
                    label: s.heatZoneNavigate,
                    onTap: onNavigate ?? () {},
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Semantics(
              button: true,
              label: s.close,
              child: GestureDetector(
                key: closeKey,
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
