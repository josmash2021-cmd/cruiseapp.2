import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the post-approval payout gate: Skip must always open the
/// complete first-trip guide, even when its global seen flag is already set.
void main() {
  test('gate mode shows a text-only Skip with a dedicated result', () {
    final s = File('lib/screens/driver/payout_methods_screen.dart')
        .readAsStringSync();
    expect(s, contains('if (widget.autoPopOnBankLinked)'),
        reason: 'Skip must exist ONLY in the post-approval gate flow');
    expect(s, contains('s.skip'));
    final skipIdx = s.indexOf('s.skip');
    final window = s.substring(skipIdx - 400, skipIdx + 100);
    expect(window, contains('TextButton('),
        reason: 'text-only letters — no filled pill');
    expect(window, contains("Navigator.of(context).pop('skip')"),
        reason: 'Skip must not be confused with back or a linked bank');
    expect(s, contains('Navigator.of(context).pop(true)'),
        reason: 'a successfully linked bank keeps its separate result');
  });

  test('the celebration ALWAYS lands on the guide after the bank page', () {
    final s = File(
            'lib/screens/driver/onboarding/driver_approved_celebration_screen.dart')
        .readAsStringSync();
    // 2026-10-22 spec: bank linked, Skip, or back — every exit continues to
    // the mandatory guide, never straight home.
    expect(s, contains('await _continueToHome();'));
    expect(
        s,
        contains(
            'onboardingFadeSlideRoute(const FirstTripGuideScreen())'));
    expect(s.contains('first_trip_guide_seen_v1'), isFalse,
        reason: 'the seen-flag bypass died: the guide is always mandatory');
    expect(s.contains('const DriverOnlineScreen()'), isFalse,
        reason: 'home is only reachable through the guide in this flow');
    expect(s.contains("result == 'skip'"), isFalse,
        reason: 'no special-casing: Skip/back/linked all land on the guide');
  });

  test('the celebration headline says Welcome to Cruise in Ride + name', () {
    final s = File(
            'lib/screens/driver/onboarding/driver_approved_celebration_screen.dart')
        .readAsStringSync();
    final l10n =
        File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(s, contains('s.welcomeCruiseInRideTitle('),
        reason: 'the headline is personalized with the first name');
    expect(s, contains('s.approvedWelcomeBody'));
    expect(l10n, contains('Welcome to Cruise in Ride, \$firstName!'));
    expect(l10n, contains('¡Bienvenido a Cruise in Ride, \$firstName!'));
  });
}
