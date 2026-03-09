import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

class DriverPromosScreen extends StatelessWidget {
  const DriverPromosScreen({super.key});

  static const _gold = Color(0xFFD4A843);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    s.promotionsLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Active promotions section
                  _sectionTitle(s.activePromotions),
                  const SizedBox(height: 12),
                  _promoCard(
                    icon: Icons.local_fire_department_rounded,
                    iconColor: const Color(0xFFFF6B35),
                    title: s.surgeZoneTitle,
                    subtitle: s.surgeZoneDesc,
                    badge: '1.5x',
                    badgeColor: const Color(0xFFFF6B35),
                  ),
                  const SizedBox(height: 10),
                  _promoCard(
                    icon: Icons.star_rounded,
                    iconColor: _gold,
                    title: s.consecutiveBonus,
                    subtitle: s.consecutiveBonusDesc,
                    badge: '+\$5',
                    badgeColor: _gold,
                  ),

                  const SizedBox(height: 28),

                  // Upcoming promotions
                  _sectionTitle(s.upcomingPromotions),
                  const SizedBox(height: 12),
                  _promoCard(
                    icon: Icons.nightlight_round,
                    iconColor: const Color(0xFF7B68EE),
                    title: s.nightOwlBonus,
                    subtitle: s.nightOwlBonusDesc,
                    badge: '+\$3',
                    badgeColor: const Color(0xFF7B68EE),
                  ),
                  const SizedBox(height: 10),
                  _promoCard(
                    icon: Icons.weekend_rounded,
                    iconColor: const Color(0xFF4CAF50),
                    title: s.weekendWarrior,
                    subtitle: s.weekendWarriorDesc,
                    badge: '+10%',
                    badgeColor: const Color(0xFF4CAF50),
                  ),
                  const SizedBox(height: 10),
                  _promoCard(
                    icon: Icons.flight_rounded,
                    iconColor: const Color(0xFF42A5F5),
                    title: s.airportBonus,
                    subtitle: s.airportBonusDesc,
                    badge: '+\$2',
                    badgeColor: const Color(0xFF42A5F5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.5),
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _promoCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String badge,
    required Color badgeColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: badgeColor,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
