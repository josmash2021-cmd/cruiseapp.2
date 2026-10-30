import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/server_time.dart';

/// Owner report 2026-10-30: a 1:40 PM (Miami) reservation showed "5:40 PM"
/// in the driver's "Mis Reservas" — the UTC time printed as if local.
void main() {
  test('a UTC server time comes back as the same instant in LOCAL time', () {
    final t = parseServerTime('2026-10-30T17:40:00+00:00')!;
    expect(t.isUtc, isFalse);
    expect(t.toUtc(), DateTime.utc(2026, 10, 30, 17, 40));
  });

  test('a tz-naive server time is UTC, not local', () {
    final t = parseServerTime('2026-10-30T17:40:00')!;
    expect(t.toUtc(), DateTime.utc(2026, 10, 30, 17, 40));
  });

  test('garbage and null are null', () {
    expect(parseServerTime(null), isNull);
    expect(parseServerTime(''), isNull);
    expect(parseServerTime('not a date'), isNull);
  });

  test('no driver screen parses a reservation time by hand', () {
    final bad = RegExp(r'DateTime\.(try)?[pP]arse\([^)]*(sched|rawTime|pickup_time)');
    final offenders = <String>[];
    for (final f in Directory('lib/screens/driver')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in bad.allMatches(src)) {
        offenders.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use parseServerTime (lib/utils/server_time.dart) — a raw '
            'parse prints UTC as if it were local time');
  });

  // The server sends the driver's reservations with scheduled_at as the
  // pickup's wall clock (so shipped builds print 1:40 PM); new builds must
  // swap the real instant back in before parseServerTime reads it as UTC.
  test('driver reservations read scheduled_at_utc', () {
    final api = File('lib/services/api_service.dart').readAsStringSync();
    final fn = api.substring(api.indexOf('getDriverScheduledTrips('));
    final body = fn.substring(0, fn.indexOf('throw ApiException'));
    expect(body, contains("final utc = t['scheduled_at_utc'];"));
    expect(body, contains("{...t, 'scheduled_at': utc}"));
  });
}
