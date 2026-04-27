import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../state/rider_trip_controller.dart';
import '../widgets/car_image_3d.dart';
import '../widgets/vehicle_tier_badge.dart';
import '../widgets/gold_particles_background.dart';

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

            // Cards — 3-column grid like home screen
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: options.asMap().entries.map((entry) {
                  final i = entry.key;
                  final opt = entry.value;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i < options.length - 1 ? 8 : 0),
                      child: _buildCard(c, isDark, opt, opt.id == selected?.id),
                    ),
                  );
                }).toList(),
              ),
            ),

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

    final VehicleTier tier;
    final String displayName;
    final String carImage;
    if (isSuv) {
      tier = VehicleTier.vip;
      displayName = 'BLACK';
      carImage = 'cruise_3.png';
    } else if (isCamry) {
      tier = VehicleTier.premium;
      displayName = 'PREMIUM';
      carImage = 'cruise_7.png';
    } else {
      tier = VehicleTier.comfort;
      displayName = 'STANDARD';
      carImage = 'cruise_6.png';
    }

    final borderColor = isSelected
        ? _gold.withValues(alpha: 0.70)
        : Colors.white.withValues(alpha: 0.08);

    return Semantics(
      label: '${opt.name} ride option, \$${opt.priceEstimate.toStringAsFixed(2)}, ${opt.etaMinutes} minutes away',
      button: true,
      selected: isSelected,
      child: GestureDetector(
        onTap: () => onSelect(opt),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          height: 168,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: borderColor,
              width: isSelected ? 2.0 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Animated gold particle background
              GoldParticlesBackground(
                particleCount: isSelected ? 35 : 20,
                child: const SizedBox.expand(),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Car image with 3D shadows
                    SizedBox(
                      width: 130,
                      height: 90,
                      child: CarImage3D(
                        assetPath: 'assets/images/$carImage',
                        cacheWidth: 360,
                        selected: isSelected,
                        fallback: Icon(
                          Icons.directions_car_rounded,
                          color: _gold.withValues(alpha: 0.5),
                          size: 40,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Display name
                    Text(
                      displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Tier badge inside card, below name
                    VehicleTierBadge(tier: tier),
                  ],
                ),
              ),
              // Selected checkmark
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: _gold,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Colors.black,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: Colors.white.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.65),
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
    
    return CarImage3D(
      assetPath: imagePath,
      cacheWidth: 200,
      dimmed: !isSelected,
      selected: isSelected,
      fallback: Icon(
        Icons.directions_car_rounded,
        color: isSelected ? _gold : Colors.white.withValues(alpha: 0.4),
        size: 36,
      ),
    );
  }
}
