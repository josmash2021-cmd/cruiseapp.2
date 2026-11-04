import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian (2026-11-03): the driver's "do I have an active trip?" check asks
/// the server, never a Firestore query across every driver's trips.
///
/// That query (`trips where status in [...]`, filtered for our driver in the
/// app) handed any driver every rider's name, phone and addresses, and
/// firestore.rules closes it once no driver runs a build older than 757
/// (tool/firestore_rules). Denied, a resumed trip never restarted the offer
/// polling — so the replacement must keep the old tri-state: only a
/// CONFIRMED ending clears the trip we hold.
void main() {
  final src = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final start = src.indexOf('  Future<void> _refreshActiveTripStatus() async {');
  final body = src.substring(start, src.indexOf('\n  }\n', start));

  test('asks the server, not a query over all trips', () {
    expect(start, greaterThan(-1));
    expect(body, contains('await ApiService.getActiveTrip()'));
    expect(body, isNot(contains("collection('trips')")));
    expect(src, isNot(contains("whereIn: const [")),
        reason: 'no other all-trips query left in the driver screen');
  });

  test('only a confirmed ending clears the held trip', () {
    expect(body, contains('await _serverSaysTripIsOver(_tripSqlId(held))'),
        reason: 'getActiveTrip reads a 502 the same as "none"');
    expect(body, contains('_kLiveTripStatuses.contains(status)'));
  });
}
