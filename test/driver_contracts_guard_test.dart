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

  test('signing requires scrolling to the END of the document', () {
    // User spec 2026-10-21: "requiere que hagan todo el scroll down... y en
    // lo último es que marcarán la casilla y el botón de aceptar" — the sign
    // block is the LAST ListView item, and sign mode has no pinned bar.
    expect(screen.contains('_signBlock(s)'), isTrue);
    expect(screen.contains('if (widget.needsAcceptance &&'), isTrue,
        reason: 'the sign block only exists appended after the full text');
    expect(
        screen.contains(
            'if (widget.needsAcceptance) return const SizedBox.shrink();'),
        isTrue,
        reason: 'no pinned bottom bar in sign mode — the checkbox must live '
            'at the end of the scroll, not floating above the text');
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

  test('completed signatures clear the gate locally without another fetch', () {
    expect(screen, contains('final signed = await Navigator.of(context).push<bool>('));
    expect(screen, contains("c['needs_acceptance'] = false"),
        reason: 'the signed tile updates locally before any refresh');
    expect(
        screen,
        isNot(contains(
            'Future<void>.delayed(const Duration(milliseconds: 350))')),
        reason: 'the completed gate must not wait before closing');
    expect(offline, contains('final completed = await Navigator.of(context).push<bool>('));
    expect(offline, contains('_contractsPending = const []'));
    expect(offline,
        contains("r == 'contracts_not_accepted' || r == 'shift_rest_required'"),
        reason: 'contracts and rest must not look like vehicle-doc failures');

    final goStart =
        offline.indexOf('if (_docStatusLoaded && _contractsPending.isNotEmpty)');
    final goEnd = offline.indexOf('// Quick check:', goStart);
    expect(goStart, isNonNegative);
    expect(goEnd, greaterThan(goStart));
    final gate = offline.substring(goStart, goEnd);
    final completedStart = gate.indexOf('if (completed == true)');
    final elseStart = gate.indexOf('} else {', completedStart);
    expect(completedStart, isNonNegative);
    expect(elseStart, greaterThan(completedStart));
    final successBranch = gate.substring(completedStart, elseStart);
    expect(successBranch, isNot(contains('_checkVehicleDocStatus')),
        reason: 'a completed signature goes straight to GO without re-fetching');
    expect(gate, contains('await _checkVehicleDocStatus();'),
        reason: 'the network fallback remains for an incomplete/unknown result');
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

  test('the to-do hub does NOT list contracts (user spec 2026-10-21)', () {
    // "debe aparecer en esta pagina, no en el to-do" — the e-sign flow
    // reaches the driver through the GO gate and the boot check only.
    expect(items.contains("contracts('contracts'"), isFalse);
    expect(hub.contains('OnboardingItem.contracts'), isFalse,
        reason: 'the hub never renders a contracts card');
    expect(hub.contains('DriverContractsScreen'), isFalse);
    // The GO/boot gates stay — they ARE the signing entry.
    expect(offline.contains('_checkContractsGate'), isTrue);
    expect(offline.contains('_contractsPending.isNotEmpty'), isTrue);
  });

  test('signup step 0 links the contracts', () {
    expect(signup.contains('docLinkContracts'), isTrue);
    expect(signup.contains('DriverContractsScreen'), isTrue);
  });

  test('the hero artwork sits at the top of the contracts list (2026-10-22)', () {
    expect(File('assets/images/contracts_hero.jpg').existsSync(), isTrue);
    expect(screen, contains("assets/images/contracts_hero.jpg"));
    // …and it renders right after the header, before the contracts list.
    final header = screen.indexOf('s.contractsTitle');
    final hero = screen.indexOf('contracts_hero.jpg');
    final list = screen.indexOf('ListView.builder(');
    expect(header > -1 && hero > header && list > hero, isTrue,
        reason: 'hero must render between the title header and the list');
  });
}
