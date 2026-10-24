import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final screen = File('lib/screens/driver/payout_methods_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final backend = File('backend/routers/drivers.py').readAsStringSync();

  test('Instant Cashout add and change are disabled with Coming soon', () {
    final start = screen.indexOf('icon: Icons.flash_on_rounded');
    final end = screen.indexOf('_extraMethods()', start);
    final card = screen.substring(start, end);
    expect(card, contains('addLabel: s.comingSoon'));
    expect(card, contains('changeLabel: s.comingSoon'));
    expect(card, contains('enabled: false'));
    expect(screen, contains('required VoidCallback? onTap'));
    expect(screen, contains('(_busy || !enabled) ? null : onTap'));
  });

  test('bank flow stays enabled and existing methods remain visible', () {
    expect(screen, contains('onTap: _connectBankAccount'));
    expect(screen, contains('syncPayoutMethodsFromStripe'));
    expect(screen, contains("_methodOfType('debit_card')"));
  });

  test('server refuses new cards before Stripe and localization exists', () {
    final start = backend.indexOf('async def add_debit_card_payout(');
    final stripe = backend.indexOf('_create_driver_connect_account(', start);
    final gate = backend.indexOf(
      'raise HTTPException(410, "debit_card_payouts_coming_soon")',
      start,
    );
    expect(gate, greaterThan(start));
    expect(gate, lessThan(stripe));
    final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n, contains("String get comingSoon => _es ? 'Próximamente' : 'Coming Soon'"));
  });
}
