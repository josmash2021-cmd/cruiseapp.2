import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../widgets/feathered_image.dart';
import 'payment_method_screen.dart';

class NotificationsScreen extends StatefulWidget {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  /// SharedPreferences flag — the native prompt is fired automatically the
  /// first time this page is shown, never again (iOS only prompts once and
  /// repeated permission_handler asks are no-ops, but we still gate it).
  static const _autoAskedKey = 'notif_perm_auto_asked_v1';

  final String firstName;
  final String lastName;
  final String email;
  final String phone;

  const NotificationsScreen({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phone = '',
  });

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    _autoRequestPermissionOnce();
  }

  /// Fire the native notification prompt as soon as the page appears (once
  /// ever). The "Allow" button stays as the manual fallback.
  Future<void> _autoRequestPermissionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(NotificationsScreen._autoAskedKey) == true) return;
      await prefs.setBool(NotificationsScreen._autoAskedKey, true);
    } catch (_) {}
    await _requestNativePermission();
  }

  /// Request the real notification permission from the OS. Android 13+
  /// goes through permission_handler; iOS needs the FirebaseMessaging
  /// prompt (alert + badge + sound) — asking both is harmless on either.
  Future<void> _requestNativePermission() async {
    await Permission.notification.request();
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),

            // ── Close button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  onTap: () {
                    // Skip — go straight to next screen
                    _goNext(context);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      color: c.textPrimary,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Illustration: full-width image, feathered edges ──
            const FeatheredImage(
              'assets/images/onboarding/notifications.jpg',
              width: double.infinity,
              height: 240,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
            ),
            const SizedBox(height: 36),

            // ── Title ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                S.of(context).helpUsKeepInformed,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ── Subtitle ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                S.of(context).allowNotifsDescription,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),
            ),

            const Spacer(),

            // ── Allow button ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        NotificationsScreen._gold,
                        NotificationsScreen._goldLight,
                      ],
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
                    onPressed: () => _requestAndGoNext(context),
                    child: Text(
                      S.of(context).allowBtn,
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
    );
  }

  void _requestAndGoNext(BuildContext context) async {
    await _requestNativePermission();

    // "Allow" must mean ALL of them. The in-app toggles default to on, but
    // a rider who ever turned one off would tap Allow here and still get
    // nothing — re-assert every channel on the way through.
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'notif_master',
        'notif_ride',
        'notif_promo',
        'notif_safety',
        'notif_payment',
        'notif_sounds',
        'notif_vibrate',
        'sound_trips',
        'sound_messages',
      ]) {
        await prefs.setBool(key, true);
      }
    } catch (_) {}

    // Regardless of result, proceed to next screen
    if (context.mounted) _goNext(context);
  }

  void _goNext(BuildContext context) {
    Navigator.of(context).push(
      slideFromRightRoute(
        PaymentMethodScreen(
          firstName: widget.firstName,
          lastName: widget.lastName,
          email: widget.email,
          phone: widget.phone,
        ),
      ),
    );
  }
}
