import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-08-22 schedule hub tanda:
///   1. The hub ships WITHOUT the "Lock in the price of a ride" card —
///      pricing promises need a product decision first.
///   2. The cancellation-policy page's fee table is the SAME table the
///      backend captures from the hold — both sources are read and compared
///      here, so they cannot drift apart silently.
///   3. The datetime page's Depart tab shows the Drop-off time and the
///      Arrive tab shows the Pickup time (never swapped).
///   4. The airline page has Skip and the "Popular airlines at {CODE}"
///      header.
///
/// Source-grep style, like driver_scheduled_neu_guard_test.dart.
void main() {
  final hub = File('lib/screens/schedule_hub_screen.dart').readAsStringSync();
  final policy =
      File('lib/screens/schedule_cancel_policy_screen.dart').readAsStringSync();
  final datetime =
      File('lib/screens/schedule_datetime_screen.dart').readAsStringSync();
  final airline =
      File('lib/screens/airline_select_screen.dart').readAsStringSync();
  final tripsPy = File('backend/routers/trips.py').readAsStringSync();

  test('hub has no price-lock card', () {
    expect(hub.toLowerCase(), isNot(contains('lock in the price')),
        reason: 'the "Lock in the price of a ride" card is out of scope');
  });

  group('cancel fee table matches the backend', () {
    Map<String, int> parseDartTable() {
      final start = policy.indexOf('kScheduledCancelFeesUsd = {');
      expect(start, greaterThan(-1));
      final block = policy.substring(start, policy.indexOf('};', start));
      final out = <String, int>{};
      for (final m in RegExp(r"'(\w+)': (\d+)").allMatches(block)) {
        out[m.group(1)!] = int.parse(m.group(2)!);
      }
      return out;
    }

    Map<String, double> parsePyTable() {
      final start = tripsPy.indexOf('SCHEDULED_CANCEL_FEE_BY_TIER = {');
      expect(start, greaterThan(-1));
      final block = tripsPy.substring(start, tripsPy.indexOf('}', start));
      final out = <String, double>{};
      for (final m in RegExp(r'"(\w+)": ([\d.]+)').allMatches(block)) {
        out[m.group(1)!] = double.parse(m.group(2)!);
      }
      return out;
    }

    test('both sources define the same four tiers at the same price', () {
      final dart = parseDartTable();
      final py = parsePyTable();
      expect(dart, {'Compact': 10, 'Standard': 15, 'Premium': 25, 'Black': 35});
      expect(py, {'compact': 10.0, 'standard': 15.0, 'premium': 25.0, 'black': 35.0});
      for (final e in dart.entries) {
        final key = e.key.toLowerCase();
        expect(py[key], e.value.toDouble(),
            reason: '${e.key}: page says \$${e.value}, backend captures \$${py[key]}');
      }
    });

    test('the free window matches too (60 minutes)', () {
      expect(tripsPy, contains('SCHEDULED_CANCEL_FREE_WINDOW_MIN = 60'));
      expect(policy, contains('cancelPolicyIntro'),
          reason: 'the intro copy carries the same 1-hour promise');
    });
  });

  test('Depart shows Drop-off, Arrive shows Pickup', () {
    // The estimate line picks its label by mode; swapped would tell the
    // rider the wrong clock time for the leg they care about.
    expect(datetime, contains('_arriveMode'));
    final ternary = RegExp('schedPickupAt[\\s\\S]{0,200}schedDropoffAt');
    expect(ternary.hasMatch(datetime), isTrue,
        reason: 'Arrive mode must render the Pickup line, Depart the Drop-off');
  });

  test('airline page has Skip and the popular-airlines header', () {
    expect(airline, contains('airlineSkip'));
    expect(airline, contains('airlinePopularAt('));
    expect(airline, contains('airlineSeeMore'));
  });

  test('the airline hook is called from the schedule continuation', () {
    final entry =
        File('lib/screens/schedule_flow_entry.dart').readAsStringSync();
    expect(entry, contains('maybeShowAirlineSelect('));
    expect(entry, contains('AirportSelection('),
        reason: 'the pick must travel in the AirportSelection the booking reads');
  });

  test('schedule hub opens date/time wheels before addresses', () {
    // 2026-08-29 user spec: tapping "Schedule a ride" lands on the
    // Depart/Arrive wheels first, not on the address search.
    expect(hub, contains('ScheduleDateTimeScreen('));
    expect(hub, isNot(contains('scheduleChain: true')),
        reason: 'the hub no longer starts the chain from the address page');
  });
}
