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

  test('the celebration forces the complete guide only for Skip', () {
    final s = File(
            'lib/screens/driver/onboarding/driver_approved_celebration_screen.dart')
        .readAsStringSync();
    final pushIdx =
        s.indexOf('PayoutMethodsScreen(autoPopOnBankLinked: true)');
    final homeIdx =
        s.indexOf('await _continueToHome(forceGuide: forceGuide);');
    expect(pushIdx, greaterThan(-1));
    expect(homeIdx, greaterThan(pushIdx),
        reason: 'the payout result must reach the continuation');
    expect(s, contains("forceGuide = result == 'skip';"),
        reason: 'only the Skip result forces the guide; true/null do not');
    expect(s, contains('!forceGuide &&'),
        reason: 'forcing the guide overrides first_trip_guide_seen_v1');
    expect(s, contains('FirstTripGuideScreen()'));
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
