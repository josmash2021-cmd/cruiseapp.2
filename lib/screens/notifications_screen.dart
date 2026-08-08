import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import 'payment_method_screen.dart';

class NotificationsScreen extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

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
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 8),

              // ── Close button ──
              Align(
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
              const SizedBox(height: 24),

              // ── Illustration ──
              Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Background shape
                    Positioned(
                      top: 20,
                      child: Container(
                        width: 120,
                        height: 100,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                    // Bell icon
                    Icon(
                      Icons.notifications_active_rounded,
                      size: 80,
                      color: _gold,
                    ),
                    // Small car
                    Positioned(
                      bottom: 30,
                      left: 40,
                      child: Icon(
                        Icons.directions_car_rounded,
                        size: 28,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),

              // ── Title ──
              Text(
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
              const SizedBox(height: 14),

              // ── Subtitle ──
              Text(
                S.of(context).allowNotifsDescription,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),

              const Spacer(),

              // ── Allow button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
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
      ),
    );
  }

  void _requestAndGoNext(BuildContext context) async {
    // Request the real notification permission from the OS. Android 13+
    // goes through permission_handler; iOS needs the FirebaseMessaging
    // prompt (alert + badge + sound) — asking both is harmless on either.
    await Permission.notification.request();
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}

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
          firstName: firstName,
          lastName: lastName,
          email: email,
          phone: phone,
        ),
      ),
    );
  }
}
