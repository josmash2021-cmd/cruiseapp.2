import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch-controlled force-update gate (2026-10-10,
/// user spec): a switch in the dispatch panel (/panel/actualizacion.html)
/// makes every app boot land on a blocking "Update required" page whose
/// only exit is the store.
///
/// The contract that makes this safe:
///  - the app check is FAIL-OPEN (null/error/offline = let the user in),
///  - the page is BLOCKING (no back gesture, no skip),
///  - the Update button leaves the app for the store,
///  - web is never gated (there is no store to send a browser to).
void main() {
  final screen =
      File('lib/screens/update_required_screen.dart').readAsStringSync();
  final splash = File('lib/screens/splash_screen.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the page is blocking — no back, no skip', () {
    expect(screen.contains('PopScope('), isTrue);
    expect(screen.contains('canPop: false'), isTrue,
        reason: 'the back gesture must not escape the gate');
  });

  test('the Update button leaves for the store', () {
    expect(screen.contains('launchUrl('), isTrue);
    expect(screen.contains('LaunchMode.externalApplication'), isTrue,
        reason: 'the store must open outside the app webview');
    expect(screen.contains('storeUrl'), isTrue);
  });

  test('splash checks the gate before any destination', () {
    expect(splash.contains('ApiService.getAppUpdateStatus()'), isTrue);
    expect(splash.contains('UpdateRequiredScreen('), isTrue);
    final gateIdx = splash.indexOf('await updateGate');
    final branchIdx = splash.indexOf('if (loggedIn) {');
    expect(gateIdx, greaterThan(-1));
    expect(branchIdx, greaterThan(-1));
    expect(gateIdx, lessThan(branchIdx),
        reason: 'the gate decides BEFORE the logged-in/logged-out split — '
            'both paths stop at the store page');
    expect(splash.contains("gate['required'] == true"), isTrue);
  });

  test('the check is fail-open and web is never gated', () {
    expect(api.contains('getAppUpdateStatus'), isTrue);
    expect(api.contains('/app-update-status?platform='), isTrue);
    expect(api.contains('if (kIsWeb) return null;'), isTrue,
        reason: 'browsers have no store — web must skip the gate');
    expect(api.contains('const Duration(seconds: 4)'), isTrue,
        reason: 'a hung check must not hold the splash hostage');
  });

  test('store URL fallbacks live in the app too', () {
    expect(api.contains('apps.apple.com/app/id6760517086'), isTrue);
    expect(api.contains('play.google.com/store/apps/details?id=com.cruiseinride.app'),
        isTrue);
  });

  test('user-facing strings exist in ES and EN', () {
    expect(l10n.contains('updateRequiredTitle'), isTrue);
    expect(l10n.contains('updateRequiredBody'), isTrue);
    expect(l10n.contains('updateNowButton'), isTrue);
    expect(l10n.contains('Actualización requerida'), isTrue);
    expect(l10n.contains('Update required'), isTrue);
  });
}
