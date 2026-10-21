import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the digital contracts & e-acceptance system (2026-10-21,
/// user spec — Uber-style): five server-versioned documents, checkbox +
/// "Accept and sign electronically" per document, PDF receipt download,
/// and the can_go_online gate that keeps a driver offline until every
/// required contract is current.
void main() {
  final screen =
      File('lib/screens/driver/driver_contracts_screen.dart').readAsStringSync();
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync();
  final online =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final hub =
      File('lib/screens/driver/onboarding/driver_todo_screen.dart').readAsStringSync();
  final items =
      File('lib/screens/driver/onboarding/onboarding_items.dart').readAsStringSync();
  final signup =
      File('lib/screens/driver/driver_signup_screen.dart').readAsStringSync();

  test('the contracts screen signs only with checkbox + explicit button', () {
    expect(screen.contains("c['needs_acceptance'] != true"), isTrue);
    expect(screen.contains('_checked && !_busy'), isTrue,
        reason: 'the gold sign button stays disabled until the checkbox');
    expect(screen.contains('contractAcceptSign'), isTrue);
    expect(screen.contains('acceptContract('), isTrue);
    expect(screen.contains('downloadContractReceipt'), isTrue,
        reason: 'signed documents offer the PDF receipt (spec item 2)');
    expect(screen.contains('gate: true') , isFalse,
        reason: 'the SCREEN never hard-codes gate mode — callers decide');
    expect(screen.contains('PopScope'), isTrue,
        reason: 'gate mode blocks back until every contract is current');
  });

  test('the boot gate checks all five contracts, not just the old ICA', () {
    expect(offline.contains('_checkContractsGate'), isTrue);
    expect(offline.contains('ApiService.getContracts()'), isTrue);
    expect(offline.contains('DriverContractsScreen(gate: true)'), isTrue);
    expect(offline.contains('_checkDriverAgreementConsent'), isFalse,
        reason: 'the single-ICA check was generalized — no zombie gate');
    expect(online.contains("import 'driver_agreement_screen.dart'"), isFalse,
        reason: 'the hardcoded agreement screen no longer gates the driver');
    expect(online.contains('driver_contracts_screen.dart'), isTrue);
  });

  test('the GO tap refuses online with contracts pending', () {
    expect(offline.contains('_contractsPending.isNotEmpty'), isTrue);
    expect(online.contains('List<String> _contractsPending'), isTrue);
    expect(offline.contains("result['contracts_pending']"), isTrue,
        reason: 'the flag comes from can_go_online — the server is the '
            'authority, the app only routes to the e-sign hub');
  });

  test('ApiService carries the four contract calls', () {
    for (final m in [
      'getContracts()',
      'getContract(String slug',
      'acceptContract({',
      'downloadContractReceipt(String slug)',
    ]) {
      expect(api.contains(m), isTrue, reason: 'missing ApiService.$m');
    }
    expect(api.contains('/legal/contracts'), isTrue);
  });

  test('the to-do hub lists contracts and routes to the e-sign hub', () {
    expect(items.contains("contracts('contracts'"), isTrue);
    expect(items.contains('case OnboardingItem.contracts'), isTrue);
    expect(hub.contains('OnboardingItem.contracts'), isTrue);
    expect(hub.contains('DriverContractsScreen'), isTrue);
  });

  test('signup step 0 links the contracts', () {
    expect(signup.contains('docLinkContracts'), isTrue);
    expect(signup.contains('DriverContractsScreen'), isTrue);
  });
}
