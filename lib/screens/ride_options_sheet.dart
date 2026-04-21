import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../state/rider_trip_controller.dart';

/// Premium ride options bottom sheet with card-based layout.
class RideOptionsSheet extends StatelessWidget {
  final List<RideOption> options;
  final RideOption? selected;
  final ValueChanged<RideOption> onSelect;
  final VoidCallback onConfirm;
  final bool isAirportTrip;
  final DateTime? scheduledAt;

  const RideOptionsSheet({
    super.key,
    required this.options,
    this.selected,
    required this.onSelect,
    required this.onConfirm,
    this.isAirportTrip = false,
    this.scheduledAt,
  });

  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFE8C96A);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Title row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    S.of(context).chooseYourRide,
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                      color: c.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const Spacer(),
                  if (isAirportTrip)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4285F4).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.flight_rounded,
                            size: 13,
                            color: Color(0xFF4285F4),
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Airport',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF4285F4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield_rounded, size: 13, color: _gold),
                        const SizedBox(width: 4),
                        Text(
                          S.of(context).insured,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _gold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Cards
            for (int i = 0; i < options.length; i++) ...[
              _buildCard(c, isDark, options[i], options[i].id == selected?.id),
              if (i < options.length - 1) const SizedBox(height: 8),
            ],

            const SizedBox(height: 14),

            // Payment row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.account_balance_wallet_rounded,
                        size: 16,
                        color: _gold,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      S.of(context).cash,
                      style: TextStyle(
                        fontSize: 14,
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.textTertiary,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            // Confirm button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_gold, _goldLight],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.30),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: onConfirm,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        selected != null
                            ? S
                                  .of(context)
                                  .confirmRideWithDetails(
                                    selected!.name,
                                    '\$${selected!.priceEstimate.toStringAsFixed(2)}',
                                  )
                            : S.of(context).confirmRide,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(AppColors c, bool isDark, RideOption opt, bool isSelected) {
    final isSuv = opt.id == 'suburban';
    final isCamry = opt.id == 'camry';

    // Tier mapping mirrors the Shopify booking widget:
    //   Suburban → VIP    (dark gradient + gold halo)
    //   Camry    → PREMIUM (gold gradient)
    //   Fusion   → COMFORT (silver gradient)
    final _BadgeTier tier;
    final String displayName;
    if (isSuv) {
      tier = _BadgeTier.vip;
      displayName = 'SUV';
    } else if (isCamry) {
      tier = _BadgeTier.premium;
      displayName = 'Comfort';
    } else {
      tier = _BadgeTier.comfort;
      displayName = 'Regular';
    }

    final cardBg = isSelected
        ? (isDark ? Colors.white.withValues(alpha: 0.07) : Colors.white)
        : (isDark
              ? Colors.white.withValues(alpha: 0.03)
              : const Color(0xFFF8F8FA));
    final borderColor = isSelected
        ? _gold.withValues(alpha: 0.50)
        : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.06));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Semantics(
        label: '${opt.name} ride option, \$${opt.priceEstimate.toStringAsFixed(2)}, ${opt.etaMinutes} minutes away${opt.surgeMultiplier > 1.0 ? ', ${opt.surgeMultiplier}x surge pricing' : ''}',
        button: true,
        selected: isSelected,
        child: GestureDetector(
          onTap: () => onSelect(opt),
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: borderColor,
              width: isSelected ? 1.5 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.15 : 0.04,
                      ),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Row(
            children: [
              // Car image
              SizedBox(
                width: 108,
                height: 72,
                child: _buildCarImage(opt.id, isSelected),
              ),
              const SizedBox(width: 14),

              // Info column
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name + tier badge with shimmer
                    Row(
                      children: [
                        Text(
                          displayName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _TierBadge(tier: tier),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Description
                    Text(
                      opt.description,
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textSecondary,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // ETA + capacity chips
                    Row(
                      children: [
                        _infoChip(
                          Icons.schedule_rounded,
                          '${opt.etaMinutes} min',
                          isDark,
                        ),
                        const SizedBox(width: 6),
                        _infoChip(
                          Icons.person_rounded,
                          '${opt.capacity}',
                          isDark,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Price column
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '\$${opt.priceEstimate.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: isSelected ? _gold : c.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (opt.surgeMultiplier > 1.0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      margin: const EdgeInsets.only(bottom: 2),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '⚡ ${opt.surgeMultiplier.toStringAsFixed(1)}x',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.redAccent,
                        ),
                      ),
                    )
                  else
                    Text(
                      'est. fare',
                      style: TextStyle(
                        fontSize: 10,
                        color: c.textTertiary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (isSelected) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(
                        color: _gold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _infoChip(IconData icon, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark
                ? Colors.white.withValues(alpha: 0.55)
                : Colors.black.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.65)
                  : Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  // Build car image widget based on vehicle type
  Widget _buildCarImage(String type, bool isSelected) {
    String imagePath;
    
    switch (type) {
      case 'suburban':
        imagePath = 'assets/images/cruise_3.png';
        break;
      case 'camry':
        imagePath = 'assets/images/cruise_7.png';
        break;
      case 'fusion':
      default:
        imagePath = 'assets/images/cruise_6.png';
    }
    
    return AnimatedOpacity(
      opacity: isSelected ? 1.0 : 0.75,
      duration: const Duration(milliseconds: 200),
      child: Image.asset(
        imagePath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        cacheWidth: 200,
        errorBuilder: (ctx, err, st) => Icon(
          Icons.directions_car_rounded,
          color: isSelected ? _gold : Colors.white.withValues(alpha: 0.4),
          size: 36,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Custom car silhouette painter for ride option cards
// ═══════════════════════════════════════════════════════════════════

class _CarSilhouettePainter extends CustomPainter {
  final String type;
  final Color color;

  _CarSilhouettePainter({required this.type, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    switch (type) {
      case 'suburban':
        _paintSuv(canvas, cx, cy, size);
        break;
      case 'camry':
        _paintSedan(canvas, cx, cy, size, wider: true);
        break;
      default:
        _paintSedan(canvas, cx, cy, size, wider: false);
    }
  }

  void _paintSedan(
    Canvas canvas,
    double cx,
    double cy,
    Size size, {
    bool wider = false,
  }) {
    final w = size.width * (wider ? 0.36 : 0.32);
    final h = size.height * 0.44;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // Body
    final body = Path()
      ..moveTo(cx - w * 0.70, cy - h * 0.90)
      ..cubicTo(
        cx - w * 0.30,
        cy - h * 1.0,
        cx + w * 0.30,
        cy - h * 1.0,
        cx + w * 0.70,
        cy - h * 0.90,
      )
      ..cubicTo(
        cx + w * 0.95,
        cy - h * 0.80,
        cx + w * 1.05,
        cy - h * 0.45,
        cx + w * 1.02,
        cy - h * 0.10,
      )
      ..cubicTo(
        cx + w * 1.0,
        cy + h * 0.15,
        cx + w * 1.0,
        cy + h * 0.35,
        cx + w * 1.02,
        cy + h * 0.50,
      )
      ..cubicTo(
        cx + w * 1.05,
        cy + h * 0.70,
        cx + w * 0.95,
        cy + h * 0.90,
        cx + w * 0.65,
        cy + h * 0.96,
      )
      ..cubicTo(
        cx + w * 0.35,
        cy + h * 1.0,
        cx - w * 0.35,
        cy + h * 1.0,
        cx - w * 0.65,
        cy + h * 0.96,
      )
      ..cubicTo(
        cx - w * 0.95,
        cy + h * 0.90,
        cx - w * 1.05,
        cy + h * 0.70,
        cx - w * 1.02,
        cy + h * 0.50,
      )
      ..cubicTo(
        cx - w * 1.0,
        cy + h * 0.35,
        cx - w * 1.0,
        cy + h * 0.15,
        cx - w * 1.02,
        cy - h * 0.10,
      )
      ..cubicTo(
        cx - w * 1.05,
        cy - h * 0.45,
        cx - w * 0.95,
        cy - h * 0.80,
        cx - w * 0.70,
        cy - h * 0.90,
      )
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);

    // Windshield
    final ws = Path()
      ..moveTo(cx - w * 0.50, cy - h * 0.42)
      ..lineTo(cx + w * 0.50, cy - h * 0.42)
      ..lineTo(cx + w * 0.72, cy - h * 0.10)
      ..lineTo(cx - w * 0.72, cy - h * 0.10)
      ..close();
    canvas.drawPath(ws, Paint()..color = color.withValues(alpha: 0.15));

    // Rear glass
    final rg = Path()
      ..moveTo(cx - w * 0.58, cy + h * 0.28)
      ..lineTo(cx + w * 0.58, cy + h * 0.28)
      ..lineTo(cx + w * 0.42, cy + h * 0.44)
      ..lineTo(cx - w * 0.42, cy + h * 0.44)
      ..close();
    canvas.drawPath(rg, Paint()..color = color.withValues(alpha: 0.15));

    // Roof
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + h * 0.02),
          width: w * 1.40,
          height: h * 0.36,
        ),
        Radius.circular(w * 0.25),
      ),
      Paint()..color = color.withValues(alpha: 0.20),
    );

    // Headlights
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + s * w * 0.52, cy - h * 0.88),
            width: w * 0.40,
            height: h * 0.06,
          ),
          Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: 0.6),
      );
    }

    // Taillights
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + s * w * 0.52, cy + h * 0.88),
            width: w * 0.38,
            height: h * 0.06,
          ),
          Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: 0.5),
      );
    }
  }

  void _paintSuv(Canvas canvas, double cx, double cy, Size size) {
    final w = size.width * 0.38;
    final h = size.height * 0.46;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // Body — boxy SUV with semi-oval corners
    final body = Path()
      ..moveTo(cx - w * 0.72, cy - h * 0.92)
      ..cubicTo(
        cx - w * 0.30,
        cy - h * 1.0,
        cx + w * 0.30,
        cy - h * 1.0,
        cx + w * 0.72,
        cy - h * 0.92,
      )
      ..cubicTo(
        cx + w * 0.92,
        cy - h * 0.86,
        cx + w * 1.04,
        cy - h * 0.52,
        cx + w * 1.04,
        cy - h * 0.12,
      )
      ..cubicTo(
        cx + w * 1.03,
        cy + h * 0.15,
        cx + w * 1.03,
        cy + h * 0.35,
        cx + w * 1.04,
        cy + h * 0.50,
      )
      ..cubicTo(
        cx + w * 1.04,
        cy + h * 0.72,
        cx + w * 0.92,
        cy + h * 0.90,
        cx + w * 0.68,
        cy + h * 0.97,
      )
      ..cubicTo(
        cx + w * 0.35,
        cy + h * 1.0,
        cx - w * 0.35,
        cy + h * 1.0,
        cx - w * 0.68,
        cy + h * 0.97,
      )
      ..cubicTo(
        cx - w * 0.92,
        cy + h * 0.90,
        cx - w * 1.04,
        cy + h * 0.72,
        cx - w * 1.04,
        cy + h * 0.50,
      )
      ..cubicTo(
        cx - w * 1.03,
        cy + h * 0.35,
        cx - w * 1.03,
        cy + h * 0.15,
        cx - w * 1.04,
        cy - h * 0.12,
      )
      ..cubicTo(
        cx - w * 1.04,
        cy - h * 0.52,
        cx - w * 0.92,
        cy - h * 0.86,
        cx - w * 0.72,
        cy - h * 0.92,
      )
      ..close();
    canvas.drawPath(body, fill);
    canvas.drawPath(body, stroke);

    // Windshield
    final ws = Path()
      ..moveTo(cx - w * 0.52, cy - h * 0.48)
      ..lineTo(cx + w * 0.52, cy - h * 0.48)
      ..lineTo(cx + w * 0.76, cy - h * 0.14)
      ..lineTo(cx - w * 0.76, cy - h * 0.14)
      ..close();
    canvas.drawPath(ws, Paint()..color = color.withValues(alpha: 0.15));

    // Rear glass — far back
    final rg = Path()
      ..moveTo(cx - w * 0.60, cy + h * 0.52)
      ..lineTo(cx + w * 0.60, cy + h * 0.52)
      ..lineTo(cx + w * 0.44, cy + h * 0.70)
      ..lineTo(cx - w * 0.44, cy + h * 0.70)
      ..close();
    canvas.drawPath(rg, Paint()..color = color.withValues(alpha: 0.15));

    // Roof — wider
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + h * 0.04),
          width: w * 1.50,
          height: h * 0.50,
        ),
        Radius.circular(w * 0.20),
      ),
      Paint()..color = color.withValues(alpha: 0.18),
    );

    // Roof rails
    for (final s in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + s * w * 0.68, cy - h * 0.18),
        Offset(cx + s * w * 0.68, cy + h * 0.26),
        Paint()
          ..color = color.withValues(alpha: 0.4)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // Headlights
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + s * w * 0.54, cy - h * 0.90),
            width: w * 0.44,
            height: h * 0.065,
          ),
          Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: 0.6),
      );
    }

    // Taillights
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + s * w * 0.55, cy + h * 0.90),
            width: w * 0.42,
            height: h * 0.065,
          ),
          Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CarSilhouettePainter old) =>
      old.type != type || old.color != color;
}

// ═══════════════════════════════════════════════════════════════════
//  Tier badge — pixel-matches the Shopify booking widget
//  (vipRide__badge--vip / --premium / --comfort)
// ═══════════════════════════════════════════════════════════════════

enum _BadgeTier { vip, premium, comfort }

class _TierBadge extends StatefulWidget {
  final _BadgeTier tier;
  const _TierBadge({required this.tier});

  @override
  State<_TierBadge> createState() => _TierBadgeState();
}

class _TierBadgeState extends State<_TierBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _haloCtl;

  @override
  void initState() {
    super.initState();
    // 6s pulsing halo — matches vipHalo CSS keyframes.
    _haloCtl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _haloCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _haloCtl,
      builder: (_, __) {
        final t = _haloCtl.value;
        // ease-in-out cubic-bezier(.4,0,.6,1) approximation.
        final ease = 0.5 - 0.5 * math.cos(t * 2 * math.pi);
        return _buildBadge(ease);
      },
    );
  }

  Widget _buildBadge(double ease) {
    switch (widget.tier) {
      case _BadgeTier.vip:
        return _badgeShell(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
          ),
          border: Border.all(
            color: const Color(0xFFE8C547).withValues(alpha: 0.30),
            width: 1,
          ),
          shadow: [
            BoxShadow(
              color: const Color(0xFFE8C547)
                  .withValues(alpha: 0.20 + 0.25 * ease),
              blurRadius: 14 + 8 * ease,
              spreadRadius: 0.5,
            ),
          ],
          icon: _vipSparkleIcon,
          iconColor: const Color(0xFFE8C547),
          label: 'VIP',
          labelColor: Colors.white,
        );

      case _BadgeTier.premium:
        return _badgeShell(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFF5DC7A),
              Color(0xFFE8C547),
              Color(0xFFB08800),
            ],
          ),
          shadow: const [
            BoxShadow(
              color: Color(0x66D4AF37),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
            BoxShadow(
              color: Color(0x40E8C547),
              blurRadius: 14,
            ),
          ],
          icon: Icons.star_rounded,
          iconColor: Colors.black,
          label: 'PREMIUM',
          labelColor: Colors.black,
        );

      case _BadgeTier.comfort:
        return _badgeShell(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
          ),
          shadow: const [
            BoxShadow(
              color: Color(0x4DC0C0C0),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
            BoxShadow(
              color: Color(0x26C8C8C8),
              blurRadius: 12,
            ),
          ],
          icon: Icons.auto_awesome_rounded,
          iconColor: const Color(0xFF1A1A1A),
          label: 'COMFORT',
          labelColor: const Color(0xFF1A1A1A),
        );
    }
  }

  Widget _badgeShell({
    required Gradient gradient,
    BoxBorder? border,
    required List<BoxShadow> shadow,
    required dynamic icon, // IconData or Widget
    required Color iconColor,
    required String label,
    required Color labelColor,
  }) {
    return Container(
      height: 22,
      constraints: const BoxConstraints(minWidth: 78),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        gradient: gradient,
        border: border,
        borderRadius: BorderRadius.circular(6),
        boxShadow: shadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon is IconData)
            Icon(icon, size: 11, color: iconColor)
          else
            SizedBox(width: 12, height: 12, child: icon as Widget),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w900,
              color: labelColor,
              letterSpacing: 1.0,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  // Custom sparkle (matches the VIP crown/sparkle SVG on the web).
  Widget get _vipSparkleIcon => const Icon(
        Icons.auto_awesome,
        size: 11,
        color: Color(0xFFE8C547),
      );
}
