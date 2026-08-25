import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/user_session.dart';
import '../widgets/feathered_image.dart';
import 'home_screen.dart';

/// Lyft-style "You're set to ride" onboarding completion screen.
/// Full-bleed photo on top, big two-line title, clean safety rows with
/// hairline dividers, and a single gold CTA into home.
class ReadyToRideScreen extends StatefulWidget {
  final String firstName;

  const ReadyToRideScreen({super.key, required this.firstName});

  @override
  State<ReadyToRideScreen> createState() => _ReadyToRideScreenState();
}

class _ReadyToRideScreenState extends State<ReadyToRideScreen> {
  static const _gold = Color(0xFFD4AF37);

  bool _locationGranted = false;
  bool _showLocationPrompt = false;

  @override
  void initState() {
    super.initState();
    _checkLocationStatus();
  }

  Future<void> _checkLocationStatus() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse) {
      if (mounted) setState(() => _locationGranted = true);
    }
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
    final s = S.of(context);
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          Column(
            children: [
              // ── Full-bleed photo (edge to edge, feathered borders) ──
              FeatheredImage(
                'assets/images/onboarding/ready_to_ride.jpg',
                width: double.infinity,
                height: 240 + MediaQuery.of(context).padding.top,
              ),

              Expanded(
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 28),

                        // ── Big two-line title ──
                        Text(
                          s.readyToRide,
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                            height: 1.25,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Safety rows (clean, hairline dividers) ──
                        _safetyRow(
                          c: c,
                          icon: Icons.verified_user_outlined,
                          text: s.safetyPoint1,
                        ),
                        _divider(c),
                        _safetyRow(
                          c: c,
                          icon: Icons.route_outlined,
                          text: s.safetyPoint2,
                        ),
                        _divider(c),
                        _safetyRow(
                          c: c,
                          icon: Icons.support_agent_outlined,
                          text: s.safetyPoint3,
                        ),

                        const Spacer(),

                        // ── Take your first ride button ──
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFD4AF37),
                                  Color(0xFFB8960C),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(28),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFFD4AF37,
                                  ).withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: const Color(0xFF0A0A0A),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                              ),
                              onPressed: _goToHome,
                              child: Text(
                                s.takeFirstRide,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ── Location permission prompt overlay ──
          if (_showLocationPrompt && !_locationGranted)
            _locationPromptOverlay(s),
        ],
      ),
    );
  }

  /// One safety row: gold line icon + text. No enclosing card.
  Widget _safetyRow({
    required AppColors c,
    required IconData icon,
    required String text,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _gold, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: c.textPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(AppColors c) {
    return Divider(
      height: 1,
      thickness: 1,
      color: c.textTertiary.withValues(alpha: 0.15),
    );
  }

  /// Full-screen location permission overlay.
  Widget _locationPromptOverlay(S s) {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _gold.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFFD4AF37), Color(0xFFB8960C)],
                    ),
                  ),
                  child: const Icon(
                    Icons.location_on_rounded,
                    color: Colors.black,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  s.enableLocationTitle,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  s.enableLocationDesc,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.6),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    onPressed: _requestLocation,
                    child: Text(
                      s.allowLocation,
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
        ),
      ),
    );
  }
}
