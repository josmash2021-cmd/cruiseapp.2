import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/user_session.dart';
import 'home_screen.dart';

/// Luxury full-screen "You're set to ride" onboarding completion screen.
/// Matches the driver onboarding pages style with full-bleed background,
/// glassmorphism cards, and staggered entrance animations.
class ReadyToRideScreen extends StatefulWidget {
  static const _gold = Color(0xFFD4AF37);

  final String firstName;

  const ReadyToRideScreen({super.key, required this.firstName});

  @override
  State<ReadyToRideScreen> createState() => _ReadyToRideScreenState();
}

class _ReadyToRideScreenState extends State<ReadyToRideScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);

  late AnimationController _animCtrl;
  bool _locationGranted = false;
  bool _showLocationPrompt = false;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _animCtrl.forward();
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
    _animCtrl.dispose();
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

  /// Staggered fade + slide animation for a child widget.
  Widget _staggered({
    required double begin,
    required double end,
    required Widget child,
    Offset slideBegin = const Offset(0, 0.08),
  }) {
    return AnimatedBuilder(
      animation: _animCtrl,
      builder: (_, __) {
        final t = _animCtrl.value;
        final interval = Interval(begin, end, curve: Curves.easeOutCubic);
        final progress = interval.transform(t.clamp(0.0, 1.0));
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(
              slideBegin.dx * (1 - progress),
              slideBegin.dy * (1 - progress) * 60,
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Full-screen background ──
          Image.asset(
            'assets/images/safety_rules_suburban.png',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),

          // ── Dark gradient overlay ──
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x4D000000), // 30% black
                  Color(0xD9000000), // 85% black
                ],
                stops: [0.0, 0.75],
              ),
            ),
          ),

          // ── Content ──
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 20),

                  // ── Header: icon + title + subtitle in pill ──
                  _staggered(
                    begin: 0.0,
                    end: 0.25,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Shield icon
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF1A1A1A),
                              border: Border.all(
                                color: _gold.withValues(alpha: 0.5),
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.shield_rounded,
                              color: _gold,
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Title
                          Text(
                            "YOU'RE SET TO RIDE.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: _gold,
                              letterSpacing: 2.0,
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Subtitle
                          Text(
                            "WE'RE HERE WHEN YOU NEED US.",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.75),
                              letterSpacing: 3.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Safety cards ──
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _staggered(
                          begin: 0.20,
                          end: 0.50,
                          child: _safetyCard(
                            icon: Icons.verified_user_rounded,
                            title: 'ALL DRIVERS MUST PASS REGULAR BACKGROUND CHECKS',
                            desc: s.safetyPoint1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _staggered(
                          begin: 0.35,
                          end: 0.65,
                          child: _safetyCard(
                            icon: Icons.route_rounded,
                            title: 'WE MONITOR RIDES FOR UNUSUAL ACTIVITY',
                            desc: s.safetyPoint2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _staggered(
                          begin: 0.50,
                          end: 0.80,
                          child: _safetyCard(
                            icon: Icons.support_agent_rounded,
                            title: 'FEEL UNSAFE? CONNECT WITH SAFETY SPECIALISTS',
                            desc: s.safetyPoint3,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Location toggle hint ──
                  _staggered(
                    begin: 0.75,
                    end: 0.90,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          color: _gold,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          s.locationAlwaysOn,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Take your first ride button ──
                  _staggered(
                    begin: 0.80,
                    end: 1.0,
                    child: SizedBox(
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
                              color: const Color(0xFFD4AF37).withValues(alpha: 0.4),
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
                            s.takeFirstRide.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),

          // ── Location permission prompt overlay ──
          if (_showLocationPrompt && !_locationGranted)
            _locationPromptOverlay(s),
        ],
      ),
    );
  }

  /// Glassmorphism safety card.
  Widget _safetyCard({
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _gold.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon container
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: _gold, size: 24),
            ),
            const SizedBox(width: 14),
            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _gold,
                      letterSpacing: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.75),
                      height: 1.35,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
