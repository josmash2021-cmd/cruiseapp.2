import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the 2026-10-02 driver Live Activity fixes (user report: "el
/// driver fuera de la app no le sale la isla con la oferta"). Prod had ZERO
/// LA token registrations from every driver — the island could never paint.
/// These pins cover the three holes that were closed:
///
/// 1. The push-to-start entitlement (the island starting on a KILLED app,
///    exactly the "driver outside the app" case) must be declared.
/// 2. The native side must answer whether Settings has Live Activities off
///    (the silent no-op that hid the whole failure).
/// 3. Dart must ask it, and the online screen must say it out loud.
void main() {
  test('push-to-start entitlement is intentionally NOT declared', () {
    // 2026-10-02: adding com.apple.developer.live-activity-push-to-start
    // made Codemagic fail signing — its API-generated provisioning
    // profiles can only include App ID capabilities, and Apple exposes no
    // "Live Activities" checkbox on the App ID page (verified: the key is
    // only granted by Xcode-managed signing, which this pipeline does not
    // use). Without it the island still works for the real case — driver
    // went online (the app starts the island) and then backgrounds; only
    // the killed-cold-start case is out. Pin the decision so nobody
    // re-adds the key and breaks the iOS build again.
    final ent =
        File('ios/Runner/Runner.entitlements').readAsStringSync();
    expect(
      ent.contains('com.apple.developer.live-activity-push-to-start'),
      isFalse,
      reason: 'Codemagic API profiles cannot include this entitlement — '
          'declaring it kills the iOS build at signing (2026-10-02). '
          'Revisit only with Xcode-managed signing (allowProvisioningUpdates).',
    );
  });

  test('native reports areActivitiesEnabled (the Settings kill-switch)',
      () {
    final appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate.contains('case "activitiesEnabled"'), isTrue);
    expect(
      appDelegate.contains('ActivityAuthorizationInfo().areActivitiesEnabled'),
      isTrue,
    );
  });

  test('dart asks + the online screen says it out loud', () {
    final svc = File('lib/services/live_activity_service.dart')
        .readAsStringSync();
    expect(svc.contains('areActivitiesEnabled'), isTrue);
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(ctrl.contains('_laDisabled'), isTrue,
        reason: 'the notice must fire when the shift starts — silently '
            'no island is how prod ended with zero token registrations');
    final widgets = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(widgets.contains('_laDisabledNotice'), isTrue);
    final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n.contains('liveActivityOffTitle'), isTrue);
    expect(l10n.contains('liveActivityOffBody'), isTrue);
  });
}
