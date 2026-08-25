import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/feathered_image.dart';
import 'driver_todo_screen.dart';
import 'onboarding_widgets.dart';

/// Notification-permission page of the registration flows (2026-08-25) —
/// the same Lyft-style page for rider and driver: X to skip, feathered
/// hero, "Help us keep you informed", gold Allow button, and the native OS
/// prompt fired when the page appears. It fires on EVERY registration —
/// same device or not (user spec: no once-per-device latch). The OS itself
/// decides whether the dialog can re-show; we always ask.
/// [nextScreen] decides where it lands next.
///
/// Cold-start mode (user spec 2026-08-25): a signed-in driver gets this
/// page pushed over the home whenever notifications or location are still
/// missing. [popOnDone] makes Allow/X simply close the page instead of
/// continuing an onboarding chain, and [requestLocation] adds the GPS ask
/// to the auto-prompt (the home already requests location on its own, so
/// the ask is wrapped against a request already in flight).
class DriverNotificationsScreen extends StatefulWidget {
  const DriverNotificationsScreen({
    super.key,
    this.nextScreen,
    this.popOnDone = false,
    this.requestLocation = false,
  });

  /// Where to continue after Allow / skip. Defaults to the driver to-do
  /// hub (the intro-flow entry keeps working unchanged).
  final Widget? nextScreen;

  /// Cold-start mode: Allow/X pop this page back to whatever is under it.
  final bool popOnDone;

  /// Also ask for location (GPS) alongside notifications.
  final bool requestLocation;

  @override
  State<DriverNotificationsScreen> createState() =>
      _DriverNotificationsScreenState();
}

class _DriverNotificationsScreenState extends State<DriverNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Ask on every registration (2026-08-25): no device latch — a new
    // signup always gets the OS prompt.
    _requestNativePermission();
  }

  /// Android 13+ goes through permission_handler; iOS needs the
  /// FirebaseMessaging prompt (alert + badge + sound). Asking both is
  /// harmless on either platform.
  Future<void> _requestNativePermission() async {
    await Permission.notification.request();
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}
    if (widget.requestLocation) {
      // Only when still simply denied — a deniedForever has no dialog left
      // and a grant needs nothing. Geolocator throws if the home's own
      // startup request is still in flight; that one already asked.
      try {
        final p = await Geolocator.checkPermission();
        if (p == LocationPermission.denied) {
          await Geolocator.requestPermission();
        }
      } catch (_) {}
    }
  }

  void _goHub() {
    if (!mounted) return;
    if (widget.popOnDone) {
      Navigator.of(context).maybePop();
      return;
    }
    Navigator.of(context).pushReplacement(
      onboardingFadeSlideRoute(widget.nextScreen ?? const DriverTodoScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: kOnboardingNavy,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  onTap: _goHub,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const FeatheredImage(
              'assets/images/onboarding/notifications.jpg',
              width: double.infinity,
              height: 240,
            ),
            const SizedBox(height: 36),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                s.helpUsKeepInformed,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                s.allowNotifsDescription,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kOnboardingGold,
                    foregroundColor: const Color(0xFF1A1400),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  onPressed: () async {
                    await _requestNativePermission();
                    _goHub();
                  },
                  child: Text(
                    s.allowBtn,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
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
}
