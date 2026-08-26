import 'package:flutter/material.dart';

import '../../../config/page_transitions.dart';
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
/// Runs on EVERY registration (user spec 2026-08-25 — no once-per-device
/// latch, same rule as the notification-permission page): this screen is
/// only reachable from the registration chain, and a device that already
/// ran the sequence once still gets it again on a fresh signup.
class OnboardingIntroFlowScreen extends StatefulWidget {
  const OnboardingIntroFlowScreen({super.key});

  /// The fixed intro order.
  static const sequence = [
    OnboardingItem.vehicle,
    OnboardingItem.plate,
    OnboardingItem.ssn,
    OnboardingItem.license,
    OnboardingItem.photo,
    OnboardingItem.background,
  ];

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

  void _toHub() {
    if (!mounted) return;
    // The notification-permission page moved to right after the email step
    // (2026-08-25) — the intro sequence goes straight to the hub.
    Navigator.of(
      context,
    ).pushReplacement(onboardingFadeSlideRoute(const DriverTodoScreen()));
  }

  @override
  Widget build(BuildContext context) {
    // Placeholder behind the pushed intros — only visible during pushes.
    return const Scaffold(backgroundColor: kOnboardingNavy);
  }
}
