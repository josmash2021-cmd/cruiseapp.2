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
/// The fix: the foreground handler draws the glass in-app banner (owner spec
/// 2026-11-01, one banner on both platforms — iOS no longer draws its own
/// for FCM in foreground), and its tap routes the push to the browse map
/// exactly like the system notification's tap.
void main() {
  // CRLF-agnostic: fresh worktree checkouts on Windows carry \r\n and
  // multi-line needles must still match (AGENTS.md pattern).
  final main = File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final notifService =
      File('lib/services/notification_service.dart').readAsStringSync().replaceAll('\r\n', '\n');

  // The foreground handler (the tap router has its own scheduled_ride
  // branch earlier in the file).
  final onMessageAt = main.indexOf('FirebaseMessaging.onMessage.listen(');

  test('foreground handler shows the glass banner for scheduled_ride', () {
    final branchAt = main.indexOf("if (type == 'scheduled_ride')", onMessageAt);
    expect(branchAt, greaterThan(0),
        reason: 'the broadcast type gets its own foreground branch');
    final branch = main.substring(branchAt, main.indexOf('return;', branchAt));
    expect(branch, contains('_showPushBanner(message, type: type'),
        reason: 'the glass banner on both platforms');
    expect(branch, isNot(contains('NotificationService.show(')),
        reason: 'no OS heads-up on top of the banner');
    // Its tap goes through the push tap router → the browse map.
    final tapTypes = main.substring(main.indexOf('const _kPushBannerTapTypes'),
        main.indexOf('};', main.indexOf('const _kPushBannerTapTypes')));
    expect(tapTypes, contains("'scheduled_ride'"));
    expect(main, contains('? () => _handleNotificationTap(message)'));
  });

  test('scheduled_ride never falls into the allowlist branch', () {
    final branchAt = main.indexOf("if (type == 'scheduled_ride')", onMessageAt);
    final allowlistAt = main.indexOf('final isAllowedInApp =', onMessageAt);
    expect(branchAt, greaterThan(0));
    expect(allowlistAt, greaterThan(0));
    expect(branchAt, lessThan(allowlistAt),
        reason: 'its return must come before the allowlist split');
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

  test('cold launch also routes a scheduled local-notification payload', () {
    final launchAt = main.indexOf('getNotificationAppLaunchDetails');
    final catchAt = main.indexOf('} catch', launchAt);
    final launch = main.substring(launchAt, catchAt);
    expect(launch, contains('handleOfferNotificationPayload(payload);'));
    expect(launch,
        contains('handleScheduledRideNotificationPayload(payload);'));
  });

  test('a scheduled push refreshes either open marketplace screen', () {
    expect(notifService, contains('scheduledRideRefreshNotifier'));
    expect(main, contains('scheduledRideRefreshNotifier.value++'));
    // The marketplace is the map now; the driver's own reservations page
    // (my_reservations_page.dart, 2026-11-03) listens too, below.
    for (final path in [
      'lib/screens/driver/scheduled_rides_map_screen.dart',
    ]) {
      final screen = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      expect(screen, contains('.addListener(_onScheduledRidePush)'),
          reason: path);
      expect(screen, contains('_loadAvailable(force: true)'), reason: path);
      expect(screen, contains('.removeListener(_onScheduledRidePush)'),
          reason: path);
    }
    final mine = File('lib/screens/driver/my_reservations_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(mine, contains('scheduledRideRefreshNotifier.addListener(_onBoard)'));
    expect(mine,
        contains('scheduledRideRefreshNotifier.removeListener(_onBoard)'));
  });

  test('the driver home refreshes its scheduled badge on push', () {
    final screen = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final controller = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(screen, contains('.addListener(_onScheduledRidePush)'));
    expect(screen, contains('.removeListener(_onScheduledRidePush)'));
    expect(controller, contains('void _onScheduledRidePush()'));
    expect(controller, contains('unawaited(_fetchScheduledCount())'));
  });
}
