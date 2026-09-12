import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the "Select {tier}" no-drivers gate (2026-09-11).
///
/// The booking button must be DISABLED when the server confirms zero
/// drivers around the pickup — taking a request nobody can serve means a
/// hold on the rider's card and ten minutes watching a dead search.
///
/// What a source-grep test CAN pin (same style as ride_hold_guard_test):
///   a. The Select button's enabled state includes the gate, and
///      scheduled rides bypass it (a reservation needs nobody online NOW).
///   b. The gate trips only on a CONFIRMED zero — it reads the shared
///      DriverWaitEstimate cache and requires driverCount == 0.
///   c. A failed lookup is unknown, not none: the error path returns
///      driverCount -1 and must never disable the button.
///   d. The answer has a TTL and the screen re-asks every 20 s — a driver
///      coming online re-enables the button without an app restart.
void main() {
  final widgetsSrc =
      File('lib/screens/ride_request_widgets.dart').readAsStringSync();
  final estimateSrc =
      File('lib/services/driver_wait_estimate.dart').readAsStringSync();
  final controllerSrc =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();

  group('(a) the Select button carries the gate', () {
    test('enabled state includes the no-drivers rule', () {
      expect(
        widgetsSrc,
        contains('(_isScheduledMode || !_noDriversNearby)'),
        reason:
            'the Select button must stay disabled while a confirmed zero '
            'stands — and scheduled rides must bypass the gate entirely',
      );
    });

    test('scheduled mode covers param, airport and controller state', () {
      expect(widgetsSrc, contains('bool get _isScheduledMode =>'));
      final start = widgetsSrc.indexOf('bool get _isScheduledMode =>');
      final body = widgetsSrc.substring(start, start + 400);
      expect(body, contains('widget.scheduledAt != null'));
      expect(body, contains('widget.isAirportTrip'));
      expect(body, contains('_ctrl.state.scheduledAt != null'),
          reason:
              'an inline schedule pick flips controller state on the '
              'already-mounted screen — the gate must read it too');
    });
  });

  group('(b) the gate trips only on a confirmed zero', () {
    test('reads the shared cache and requires driverCount == 0', () {
      expect(widgetsSrc, contains('bool get _noDriversNearby'));
      final start = widgetsSrc.indexOf('bool get _noDriversNearby');
      final body = widgetsSrc.substring(start, start + 400);
      expect(body, contains('DriverWaitEstimate.cached('),
          reason:
              'a build must never start network work — the wait widget '
              'already fetched and the answer is shared');
      expect(body, contains('est.driverCount == 0'),
          reason: 'only a confirmed zero disables the button');
    });
  });

  group('(c) a failed lookup never disables the button', () {
    test('the error path reports unknown (-1), not none (0)', () {
      expect(estimateSrc, contains('driverCount: -1'),
          reason:
              'unknown is not the same as none — a network error must not '
              "tell the rider there are no drivers and block their ride");
      expect(estimateSrc, contains('bool get hasDrivers => driverCount > 0'));
    });
  });

  group('(d) the answer stays fresh', () {
    test('the estimate cache has a short TTL', () {
      expect(estimateSrc,
          contains('_ttl = Duration(seconds: 30)'),
          reason:
              '"no drivers" cached an hour ago was still shown until the '
              'rider force-closed the app — the TTL is the fix');
    });

    test('the choose-ride screen re-asks every 20 seconds', () {
      expect(controllerSrc, contains('_waitRefreshTimer = Timer.periodic('));
      final start =
          controllerSrc.indexOf('_waitRefreshTimer = Timer.periodic(');
      final body = controllerSrc.substring(start, start + 300);
      expect(body, contains('const Duration(seconds: 20)'),
          reason:
              'a driver who just came online must clear the gate without '
              'an app restart');
      expect(controllerSrc, contains('force: true'),
          reason:
              'the periodic refresh must bypass the cache or it re-reads '
              'its own stale answer');
    });

    test('the catchment radius is per-state (15 mi FL / 20 mi default)', () {
      expect(estimateSrc, contains('radiusMilesFor(double lat, double lng)'),
          reason:
              'the gate radius must match the dispatch reach or riders get '
              'enabled buttons that dispatch nobody');
    });
  });
}
