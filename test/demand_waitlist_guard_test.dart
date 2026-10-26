import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the no-drivers demand flow (owner spec 2026-10-17: "ningun
/// rider podra pedir un viaje si no hay drivers activos — qué se puede
/// hacer" → chose A + schedule): the rider gets the honest message with a
/// "Schedule for later" button, is registered in the backend demand
/// waitlist, and gets one push the moment a driver flips online nearby.
void main() {
  final ctrl =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();
  final screen =
      File('lib/screens/ride_request_screen.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('both no-drivers dialog branches offer Schedule-for-later', () {
    expect(
        'slideFromRightRoute(const ScheduleHubScreen())'
            .allMatches(ctrl)
            .length,
        greaterThanOrEqualTo(2),
        reason: 'the remote-cancel branch AND the cancelled-flag branch');
    expect(ctrl, contains('S.of(context).scheduleForLater'));
    expect(screen, contains("import 'schedule_hub_screen.dart';"));
    expect(l10n, contains('scheduleForLater'));
    expect(l10n, contains('Te avisaremos en cuanto haya conductores activos'),
        reason: 'the message promises the wake-up push');
  });

  test('the drivers_available push drops the rider on the booking home', () {
    expect(mainDart, contains("type == 'drivers_available'"));
    expect(mainDart, contains('_handleDriversAvailablePush'));
    expect(mainDart, contains("if (mode == 'driver') return;"),
        reason: 'rider-only push — role-gated like every push handler');
  });

  test('backend wires the waitlist on both ends', () {
    final guardian = File('backend/guardian_agent.dart').existsSync()
        ? ''
        : File('backend/guardian_agent.py').readAsStringSync();
    final drivers = File('backend/routers/drivers.py').readAsStringSync();
    expect(guardian, contains('add_demand_waitlist('),
        reason: 'the no-driver auto-cancel registers the demand');
    expect(drivers, contains('notify_waiting_riders('),
        reason: 'the offline→online flip wakes the waiting riders');
    expect(
        File('backend/services/demand_waitlist.py').existsSync(), isTrue);
  });
}
