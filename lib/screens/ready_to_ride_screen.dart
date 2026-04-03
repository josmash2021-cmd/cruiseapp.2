import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/user_session.dart';
import 'home_screen.dart';

class ReadyToRideScreen extends StatefulWidget {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final String firstName;

  const ReadyToRideScreen({super.key, required this.firstName});

  @override
  State<ReadyToRideScreen> createState() => _ReadyToRideScreenState();
}

class _ReadyToRideScreenState extends State<ReadyToRideScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  bool _locationGranted = false;
  bool _showLocationPrompt = false;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic);
    _fadeCtrl.forward();

    // Check if location is already granted
    _checkLocationStatus();
  }

  Future<void> _checkLocationStatus() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse) {
      if (mounted) setState(() => _locationGranted = true);
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse) {
      if (mounted) {
        setState(() {
          _locationGranted = true;
          _showLocationPrompt = false;
        });
      }
    }
  }

  Future<void> _goToHome() async {
    if (!_locationGranted) {
      setState(() => _showLocationPrompt = true);
      await _requestLocation();
      if (!_locationGranted) return;
    }
    await UserSession.saveMode('rider');
    await UserSession.updateField('role', 'rider');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const HomeScreen(), durationMs: 600),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Column(
          children: [
            // ── Top illustration area ──
            Container(
              width: double.infinity,
              height: 300,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _gold.withValues(alpha: 0.25),
                    _gold.withValues(alpha: 0.08),
                    c.bg,
                  ],
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Glow effect behind illustration
                  Positioned(
                    top: 80,
                    child: Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _gold.withValues(alpha: 0.15),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Road / landscape abstraction
                  Positioned(
                    bottom: 40,
                    child: Container(
                      width: 280,
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _gold.withValues(alpha: 0.18),
                            Colors.purple.withValues(alpha: 0.12),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(40),
                      ),
                    ),
                  ),
                  // Person walking icon
                  Positioned(
                    top: 90,
                    child: Icon(
                      Icons.directions_walk_rounded,
                      size: 110,
                      color:
                          c.isDark ? Colors.white70 : const Color(0xFF3D2E1A),
                    ),
                  ),
                  // Small car
                  Positioned(
                    bottom: 55,
                    right: 70,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.directions_car_filled_rounded,
                        size: 32,
                        color: _gold,
                      ),
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
                    const SizedBox(height: 4),
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

                    // ── Location prompt (shown after user taps button) ──
                    if (_showLocationPrompt && !_locationGranted) ...[
                      const SizedBox(height: 28),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [_gold, _goldLight],
                                ),
                              ),
                              child: const Icon(
                                Icons.location_on_rounded,
                                color: Colors.black,
                                size: 28,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              S.of(context).enableLocationTitle,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: c.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              S.of(context).enableLocationDesc,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: c.textSecondary,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 44,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                  elevation: 0,
                                ),
                                onPressed: _requestLocation,
                                child: Text(
                                  S.of(context).allowLocation,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const Spacer(),

                    // ── Location always-on hint ──
                    if (_locationGranted)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_rounded,
                                color: _gold, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              S.of(context).locationAlwaysOn,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),

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
                            onPressed: _goToHome,
                            child: Text(
                              S.of(context).takeFirstRide,
                              style: const TextStyle(
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
      ),
    );
  }

  Widget _safetyRow(AppColors c, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: _gold),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: c.textSecondary,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
