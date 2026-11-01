import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the iOS foreground-offer suppression (user report
/// 2026-09-17: the "New Ride Offer" system banner showed on top of the
/// in-app offer card while the driver was INSIDE the app).
///
/// Root cause: AppDelegate sets itself as the UNUserNotificationCenter
/// delegate and answered `willPresent` with banner+sound+badge
/// unconditionally — which beats Flutter's
/// setForegroundNotificationPresentationOptions(alert: false). The
/// suppression has to live in the native delegate: offers never banner in
/// foreground (the in-app card owns the screen); every other type keeps
/// the historical behavior. Background is untouched (willPresent only
/// fires in foreground).
void main() {
  final swift =
      File('ios/Runner/AppDelegate.swift').readAsStringSync();

  test('offers never banner in foreground on iOS', () {
    expect(swift.contains('offerTypes'), isTrue);
    expect(swift.contains('completionHandler([])'), isTrue,
        reason: 'the offer branch returns NO presentation options');
    expect(swift.contains('"trip_offer"'), isTrue);
    expect(swift.contains('"new_offer"'), isTrue);
    expect(swift.contains('userInfo["type"]'), isTrue,
        reason: 'the decision reads the FCM data type');
  });

  // Owner spec 2026-11-01: every other FCM push in foreground is drawn by
  // Flutter as the glass banner (GlassNotificationBanner) — the system
  // banner would double it, so FCM keeps only sound + badge there.
  test('FCM pushes in foreground: sound + badge, Flutter draws the banner',
      () {
    final gcm = swift.indexOf('userInfo["gcm.message_id"] != nil');
    expect(gcm, isNonNegative);
    expect(swift.indexOf('completionHandler([.sound, .badge])', gcm),
        greaterThan(gcm));
  });

  test('local notifications keep the system banner in foreground', () {
    expect(swift.contains('completionHandler([.banner, .sound, .badge])'),
        isTrue,
        reason: 'scheduled reminders never reach onMessage — they keep the '
            'historical foreground banner');
  });
}
