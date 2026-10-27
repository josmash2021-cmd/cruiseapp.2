import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the bank-form silent-dead-end (Rolando 325 / Yudel 255,
/// 2026-10-26: "no me deja enviar, me sale error de cuenta" on Android).
/// The submit button goes inert while any field is missing/invalid, and the
/// form used to give ZERO explanation. The hint must name the first blocker
/// and stay wired under the button, ES/EN strings included.
void main() {
  final screen = File('lib/screens/driver/add_bank_account_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the form names the first missing/invalid field', () {
    expect(screen, contains('String? get _missingHint'));
    for (final branch in [
      's.accountHolderName',
      's.routingNumberInvalid',
      's.bankAccountNumber',
      's.accountNumbersDoNotMatch',
      's.dateOfBirth',
      's.bankFormAddressRequired',
      's.agreeToStripeAgreement',
    ]) {
      expect(screen, contains(branch), reason: '$branch branch must exist');
    }
  });

  test('the hint renders under the inert submit button', () {
    expect(screen, contains('if (!_canSubmit && _missingHint != null)'));
    expect(screen, contains('s.bankFormMissing(_missingHint!)'));
  });

  test('the hint strings exist ES/EN', () {
    expect(l10n, contains('String get bankFormAddressRequired'));
    expect(l10n, contains('String bankFormMissing(String field)'));
    expect(l10n, contains("'Te falta: \$field'"));
  });
}
