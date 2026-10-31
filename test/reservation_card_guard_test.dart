import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the owner spec of 2026-10-31 on reservations:
///   * the offline sheet shows the driver's OWN next reservation, Lyft-style,
///     in gold: "$13.03 Viaje reservado · Conéctate antes de las 6:40 AM"
///     and the pickup time — the deadline is 1 hour before the pickup;
///   * a reservation that is gone (not online by the deadline, or removed by
///     dispatch) just FADES OUT — no message, no notification — on the
///     sheet, in "Mis Reservas" and in "Tus viajes".
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final offline = read('lib/screens/driver/driver_online_offline.dart');
  final ctrl = read('lib/screens/driver/driver_online_controller.dart');
  final mine = read('lib/screens/driver/driver_scheduled_trips_screen.dart');
  final list = read('lib/screens/driver/scheduled_rides_screen.dart');
  final l10n = read('lib/l10n/app_localizations.dart');

  test('the gold card: title, deadline 1 h before, pickup time', () {
    expect(l10n, contains("_es ? '\$price Viaje reservado' : '\$price Reserved ride'"));
    expect(l10n, contains("_es ? 'Conéctate antes de las \$time' : 'Go online by \$time'"));
    expect(offline, contains('s.reservedRideTitle('));
    expect(offline,
        contains('s.goOnlineBy(fmt.format(at.subtract(const Duration(hours: 1))))'));
    expect(offline, contains('Color(0xFFE8C547)'));
    expect(offline, contains('const Color _resInk = Color(0xFF14141A);'),
        reason: 'top-level const — part-file rule #16');
  });

  test('it shows at rest AND open, and fades in and out', () {
    expect(offline, contains('_heroReservationOr(Container('),
        reason: 'at rest it takes the demand card\'s place');
    expect(offline, contains('_buildMyReservationCard(),'));
    expect(offline, contains('transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c)'));
    expect(offline, contains('AnimatedSize('));
  });

  test('it is the driver\'s own next held reservation', () {
    expect(ctrl, contains('ApiService.getDriverScheduledTrips(id)'));
    expect(ctrl,
        contains("if (st != 'scheduled_accepted' && st != 'scheduled_active') continue;"));
    expect(ctrl, contains('_setState(() => _nextReservation = next);'));
  });

  test('lists fade a vanished reservation out, quietly and live', () {
    for (final src in [mine, list]) {
      expect(src, contains('scheduledRideRefreshNotifier'));
      expect(src, contains('AnimatedOpacity('));
      expect(src, contains('const Duration(milliseconds: 420)'));
    }
    expect(mine, contains('ScheduledBoardWatcher.acquire();'));
    expect(mine, contains('_leaving.contains(_trips[i][\'id\'])'));
    expect(list, contains('_leavingMine.contains(trips[i][\'id\'])'));
  });
}
