import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the marketplace broadcast foreground gap (user report
/// 2026-10-26: "de los viajes que el rider reserva no les llega notificacion
/// a los drivers online y offline").
///
/// Root cause: with the driver app OPEN, Android never draws the FCM
/// notification copy, and `scheduled_ride` sat in neither foreground
/// allowlist — the handler suppressed it with only a silent inbox row.
///
/// The fix: the foreground handler draws a heads-up local notification on
/// Android (iOS already banners every non-offer type natively via the
/// AppDelegate willPresent — drawing there too would double the banner), and
/// the tap routes `scheduled_ride:<trip_id>` to the browse map.
void main() {
  // CRLF-agnostic: fresh worktree checkouts on Windows carry \r\n and
  // multi-line needles must still match (AGENTS.md pattern).
  final main = File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final notifService =
      File('lib/services/notification_service.dart').readAsStringSync().replaceAll('\r\n', '\n');

  test('foreground handler draws a heads-up for scheduled_ride on Android', () {
    expect(main.contains("if (type == 'scheduled_ride')"), isTrue,
        reason: 'the broadcast type gets its own foreground branch');
    expect(main.contains('Platform.isAndroid'), isTrue,
        reason: 'Android-only: iOS already banners it natively (willPresent) '
            '— drawing on iOS would double the banner');
    expect(
      main.contains(
          "payload:\n                      'scheduled_ride:"),
      isTrue,
      reason: 'the heads-up carries the trip id for tap routing',
    );
  });

  test('scheduled_ride never falls into the silent suppression branch', () {
    final branchAt = main.indexOf("if (type == 'scheduled_ride')");
    final suppressionAt = main.indexOf('suppressed foreground notification');
    expect(branchAt, greaterThan(0));
    expect(suppressionAt, greaterThan(0));
    expect(branchAt, lessThan(suppressionAt),
        reason: 'its return must come before the allowlist suppression');
  });

  test('local-notification tap routes scheduled_ride to the browse map', () {
    expect(notifService.contains('onScheduledRideTapped'), isTrue);
    expect(notifService.contains("payload.startsWith('scheduled_ride')"),
        isTrue);
    expect(main.contains('handleScheduledRideNotificationPayload'), isTrue);
    expect(
      main.contains(
          'NotificationService.onScheduledRideTapped =\n            handleScheduledRideNotificationPayload'),
      isTrue,
      reason: 'main() wires the callback next to onOfferTapped',
    );
    expect(
      main.contains(
          'builder: (_) => ScheduledRidesMapScreen(initialTripId: tripId)'),
      isTrue,
    );
  });
}
