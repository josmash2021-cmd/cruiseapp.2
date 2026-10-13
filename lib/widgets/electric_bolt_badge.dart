import 'package:flutter/material.dart';

import 'ota_image.dart';

/// The Electric Pro mark: a gold bolt inside a dark ring, pinned to the
/// top-right corner of the tier's card (user spec 2026-10-13 — the home
/// fleet carousel card and the booking tier row).
///
/// OTA rule, same as car_electric.png: bolt_badge.png only exists in
/// bundles from the store release that ships it — Shorebird patches carry
/// no new assets — so a missing asset first tries the backend-hosted copy
/// (/static/bolt_badge.png), then composes the SAME badge from widgets:
/// the dark ring (0xFF1A1A22) with the gold bolt (0xFFE8C547).
///
/// Always decorative — the IgnorePointer keeps it from eating the card's
/// tap.
class ElectricBoltBadge extends StatelessWidget {
  final double size;

  const ElectricBoltBadge({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Image.asset(
        'assets/images/bolt_badge.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        errorBuilder: (_, __, ___) => otaImageFallback(
          'bolt_badge.png',
          Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A22),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.bolt_rounded,
              color: const Color(0xFFE8C547),
              size: size * 0.62,
            ),
          ),
          width: size,
          height: size,
        ),
      ),
    );
  }
}
