import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 12 h shift cap and the no-auto-online boot (user spec
/// 2026-09-27): a shift never runs past 12 h online, and opening/logging
/// into the app never turns online on by itself — the shift starts with GO
/// (or a real work entry: offer push-tap, assigned trip).
void main() {
  final ghost =
      File('backend/ghost_driver_agent.py').readAsStringSync();
  final drivers = File('backend/routers/drivers.py').readAsStringSync();
  final auth = File('backend/routers/auth.py').readAsStringSync();
  final model = File('backend/models/database.py').readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final screen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync();
  final welcome = File('lib/screens/driver/driver_welcome_screen.dart')
      .readAsStringSync();
  final main_ = File('lib/main.dart').readAsStringSync();

  group('backend: the ghost agent caps shifts at 12 h', () {
    test('cap constant + cutoff + branch', () {
      expect(ghost, contains('SHIFT_CAP_HOURS = 12'));
      expect(ghost,
          contains('shift_cap_cutoff = now - timedelta(hours=SHIFT_CAP_HOURS)'));
      expect(ghost, contains('since = driver.online_since'));
      expect(ghost, contains('driver.online_since = None'));
    });

    test('never mid-trip, offers retire, driver is pushed', () {
      final idx = ghost.indexOf('since < shift_cap_cutoff');
      final block = ghost.substring(idx, idx + 1800);
      expect(block.contains('if driver.id in drivers_on_active_trip:'),
          isTrue,
          reason: 'a rider aboard beats the clock — the cap lands on the '
              'next scan once the trip closes');
      expect(block.contains('expire_pending_offers_for_driver'), isTrue);
      expect(block.contains('_send_shift_ended_push(driver)'), isTrue);
      expect(ghost.contains('"type": "driver_shift_ended"'), isTrue);
    });

    test('the shift clock is stamped on flips and cleared going offline', () {
      expect(drivers,
          contains('user.online_since = utc_now() if body.is_online else None'),
          reason: 'heartbeats must not restart the clock — only the flip');
      expect(auth, contains('db_user.online_since = None'));
    });

    test('the column ships in the model AND both boot migration lists', () {
      expect(
          model,
          contains(
              'online_since = Column(DateTime(timezone=True), nullable=True)'));
      expect(model, contains('("users", "online_since", "DATETIME")'));
      expect(model,
          contains('("users", "online_since", "TIMESTAMP WITH TIME ZONE")'),
          reason: 'SQLite ensure-list AND Postgres boot list — trampa #0');
    });
  });

  group('app: opening never turns online on by itself', () {
    test('routeExistingDriver opens OFFLINE (no resuming on login)', () {
      final idx = welcome.indexOf('slideFromRightRoute(const DriverOnlineScreen(');
      final block = welcome.substring(idx, idx + 120);
      expect(block.contains('resuming: true'), isFalse,
          reason: 'resuming: true at login was the auto-online the user '
              'reported — the shift starts with GO');
      final photo = File('lib/screens/driver/driver_profile_photo_screen.dart')
          .readAsStringSync();
      final pidx =
          photo.indexOf('slideFromRightRoute(const DriverOnlineScreen(');
      final pblock = photo.substring(pidx, pidx + 120);
      expect(pblock.contains('resuming: true'), isFalse);
    });
  });

  group('app: the live half of the cap', () {
    test('a 1-min timer closes the shift and stamps its start', () {
      expect(ctrl, contains('_shiftCapTimer = Timer.periodic('));
      expect(ctrl, contains('const Duration(hours: 12)'));
      expect(ctrl, contains('driver_went_online_at'));
      expect(ctrl, contains('unawaited(_exitOnlineMode()'));
    });

    test('the server push flips the live UI too', () {
      expect(screen, contains('shiftEndedNotifier'));
      expect(ctrl, contains('void _onShiftEndedPush()'));
      expect(main_, contains("if (type == 'driver_shift_ended')"));
      expect(
          File('lib/l10n/app_localizations.dart')
              .readAsStringSync(),
          contains('shiftEnded12h'));
    });

    test('the RESUME label expires at the cap', () {
      expect(ctrl, contains('const Duration(hours: 12).inMilliseconds'),
          reason: 'past 12 h the GO button reads GO, not RESUME — even if '
              'the app died mid-shift');
    });
  });
}
