import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian (user spec 2026-10-06): the post-approval payout gate must offer
/// a visible way FORWARD without linking a bank or card — a text-only "Skip"
/// under the methods, shown in gate mode only (opened from the menu it's an
/// exit, not a skip). The celebration continues the chain (guide → home) on
/// ANY pop, so Skip is just a pop — same as the back arrow.
void main() {
  test('gate mode shows a text-only Skip that pops', () {
    final s = File('lib/screens/driver/payout_methods_screen.dart')
        .readAsStringSync();
    expect(s, contains('if (widget.autoPopOnBankLinked)'),
        reason: 'Skip must exist ONLY in the post-approval gate flow');
    expect(s, contains('s.skip'));
    final skipIdx = s.indexOf('s.skip');
    final window = s.substring(skipIdx - 400, skipIdx + 100);
    expect(window, contains('TextButton('),
        reason: 'text-only letters — no filled pill');
    expect(window, contains('Navigator.of(context).pop()'));
  });

  test('the celebration continues the chain on pop (skip lands forward)', () {
    final s = File(
            'lib/screens/driver/onboarding/driver_approved_celebration_screen.dart')
        .readAsStringSync();
    final pushIdx =
        s.indexOf('PayoutMethodsScreen(autoPopOnBankLinked: true)');
    final homeIdx = s.indexOf('_continueToHome()');
    expect(pushIdx, greaterThan(-1));
    expect(homeIdx, greaterThan(pushIdx),
        reason:
            'if _continueToHome stops running after the payout screen pops, '
            'Skip/back would land back on the celebration instead of forward');
  });
}
