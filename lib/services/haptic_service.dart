import 'package:flutter/services.dart';
import '../main.dart' show accessibilityNotifier;

/// Thin wrapper around [HapticFeedback] that respects the user's
/// accessibility preference for haptic feedback.
///
/// All haptic calls in the app should go through this service instead of
/// calling [HapticFeedback] directly.
class HapticService {
  HapticService._();

  static void lightImpact() {
    if (accessibilityNotifier.hapticFeedback) {
      HapticFeedback.lightImpact();
    }
  }

  static void mediumImpact() {
    if (accessibilityNotifier.hapticFeedback) {
      HapticFeedback.mediumImpact();
    }
  }

  static void heavyImpact() {
    if (accessibilityNotifier.hapticFeedback) {
      HapticFeedback.heavyImpact();
    }
  }

  static void selectionClick() {
    if (accessibilityNotifier.hapticFeedback) {
      HapticFeedback.selectionClick();
    }
  }

  static void vibrate() {
    if (accessibilityNotifier.hapticFeedback) {
      HapticFeedback.vibrate();
    }
  }
}
