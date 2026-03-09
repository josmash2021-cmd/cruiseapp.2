import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/user_session.dart';
import 'home_screen.dart';

class ReadyToRideScreen extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final String firstName;

  const ReadyToRideScreen({super.key, required this.firstName});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          // ── Top illustration area ──
          Container(
            width: double.infinity,
            height: 280,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _gold.withValues(alpha: 0.3),
                  _gold.withValues(alpha: 0.1),
                  c.bg,
                ],
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Road / landscape abstraction
                Positioned(
                  bottom: 40,
                  child: Container(
                    width: 260,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.2),
                          Colors.purple.withValues(alpha: 0.15),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                // Person walking icon
                Icon(
                  Icons.directions_walk_rounded,
                  size: 100,
                  color: c.isDark ? Colors.white70 : const Color(0xFF3D2E1A),
                ),
                // Small car
                Positioned(
                  bottom: 55,
                  right: 80,
                  child: Icon(
                    Icons.directions_car_filled_rounded,
                    size: 36,
                    color: _gold.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),

          // ── Content ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    S.of(context).readyToRide,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                      height: 1.2,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Safety points ──
                  _safetyRow(
                    c,
                    Icons.verified_user_outlined,
                    S.of(context).safetyPoint1,
                  ),
                  const SizedBox(height: 20),
                  _safetyRow(
                    c,
                    Icons.route_rounded,
                    S.of(context).safetyPoint2,
                  ),
                  const SizedBox(height: 20),
                  _safetyRow(
                    c,
                    Icons.security_rounded,
                    S.of(context).safetyPoint3,
                  ),

                  const Spacer(),

                  // ── Take your first ride ──
                  Padding(
                    padding: const EdgeInsets.only(bottom: 32),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [_gold, _goldLight],
                          ),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: const Color(0xFF1A1400),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                          onPressed: () async {
                            await UserSession.saveMode('rider');
                            await UserSession.updateField('role', 'rider');
                            if (!context.mounted) return;
                            Navigator.of(context).pushAndRemoveUntil(
                              smoothFadeRoute(
                                const HomeScreen(),
                                durationMs: 600,
                              ),
                              (_) => false,
                            );
                          },
                          child: Text(
                            S.of(context).takeFirstRide,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _safetyRow(AppColors c, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: c.textSecondary),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              color: c.textSecondary,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
