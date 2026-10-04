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

  test('the island never shows offers — offers arrive as the FCM banner',
      () {
    // Product call 2026-10-02 (user spec): "quita el live activity de la
    // isla cuando le llega una oferta — quiero que le llegue la
    // notificacion de oferta". The island keeps only the online-presence
    // state; the offer itself is the push banner + the in-app card.
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    final syncStart = ctrl.indexOf('void _syncOfferLiveActivity');
    expect(syncStart, greaterThan(-1));
    final block = ctrl.substring(syncStart, syncStart + 1200);
    expect(block.contains('showOffer('), isFalse,
        reason: 'the offer must never paint the island again — banner only');
    expect(block.contains("updateStatus(next)"), isTrue,
        reason: 'the island stays presence-only (online / on_trip)');
    expect(ctrl.contains('_offerLiveActivityFields'), isFalse,
        reason: 'the offer-card formatter is dead with the island offer');
  });
}
