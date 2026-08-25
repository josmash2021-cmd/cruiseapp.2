import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/page_transitions.dart';
import 'driver_notifications_screen.dart';
import 'driver_todo_screen.dart';
import 'onboarding_intro_screen.dart';
import 'onboarding_items.dart';
import 'onboarding_widgets.dart';

/// One-time intro sequence before the to-do hub (Lyft style).
///
/// After the "Tell us about yourself" step, each onboarding item gets its
/// own intro page in a fixed order — vehicle → plate → ssn → license →
/// photo → background — pushed with [onboardingFadeSlideRoute]:
/// - a completed capture pops `true` → the NEXT intro shows;
/// - "Skip for now" (or the X) on ANY intro ends the sequence and lands
///   directly on [DriverTodoScreen];
/// - finishing the last intro also lands on [DriverTodoScreen].
///
/// Shown only once per device (SharedPreferences
/// `onboarding_intro_flow_seen_v1`); afterwards the caller's entry point
/// goes straight to the hub.
class OnboardingIntroFlowScreen extends StatefulWidget {
  const OnboardingIntroFlowScreen({super.key});

  static const seenFlag = 'onboarding_intro_flow_seen_v1';

  /// The fixed intro order.
  static const sequence = [
    OnboardingItem.vehicle,
    OnboardingItem.plate,
    OnboardingItem.ssn,
    OnboardingItem.license,
    OnboardingItem.photo,
    OnboardingItem.background,
  ];

  /// True when the intro sequence was already shown on this device.
  static Future<bool> wasSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(seenFlag) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  State<OnboardingIntroFlowScreen> createState() =>
      _OnboardingIntroFlowScreenState();
}

class _OnboardingIntroFlowScreenState extends State<OnboardingIntroFlowScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final seen = await OnboardingIntroFlowScreen.wasSeen();
    if (!mounted) return;
    if (seen) {
      _toHub();
      return;
    }
    // Mark as seen up front: even a skipped sequence never replays.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(OnboardingIntroFlowScreen.seenFlag, true);
    } catch (_) {}

    for (final item in OnboardingIntroFlowScreen.sequence) {
      if (!mounted) return;
      final completed = await Navigator.of(context).push<bool>(
        onboardingFadeSlideRoute<bool>(
          OnboardingIntroScreen(
            entry: OnboardingItemEntry(
              item: item,
              status: OnboardingItemStatus.pending,
            ),
          ),
        ),
      );
      // Skip / close on any intro → straight to the hub, remaining intros
      // are not shown. A completed capture continues to the next intro.
      if (completed != true) {
        _toHub();
        return;
      }
    }
    _toHub();
  }

  Future<void> _toHub() async {
    if (!mounted) return;
    // Notification-permission page once, between the intro sequence and the
    // hub (2026-08-25 — the driver flow never showed one before).
    final notifShown = await DriverNotificationsScreen.wasShown();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      onboardingFadeSlideRoute(
        notifShown
            ? const DriverTodoScreen()
            : const DriverNotificationsScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Placeholder behind the pushed intros — only visible during pushes.
    return const Scaffold(backgroundColor: kOnboardingNavy);
  }
}
