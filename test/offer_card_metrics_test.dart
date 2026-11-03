import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/utils/name_helper.dart';
import 'package:cruise_app/utils/offer_metrics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ride offer card (owner report 2026-11-01).
///
/// The screenshot read "1 h 39 min (747.3 mi) away" — 747 miles in 99
/// minutes is 450 mph. Every leg's minutes were clamped to 1..99, so any
/// pickup past ~66 road miles printed exactly 99, and the total chip
/// ("2 h 7 min" = 99 + 28) and the "$14.45/hr" (= $30.58 over 127 min) were
/// wrong with it. Also: the card had a 4 px side inset and the Accept pill
/// 20 px, so the card was 32 px wider than the button; and the rider showed
/// with the full surname instead of "Lisbeth T.".
void main() {
  String src(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group('offer leg minutes are never capped', () {
    test('the screenshot pickup: 747.3 road miles keeps the router\'s time',
        () {
      const km = 747.3 / 0.621371;
      // Google's own time for ~747 road miles is about 11 hours.
      final min = offerLegMinutes(km: km, roadMinutes: 680.4);
      expect(min, 681, reason: 'the old clamp(1, 99) printed 99 here');
      final mph = 747.3 / (min / 60);
      expect(mph, lessThan(90), reason: 'time and distance must agree');
    });

    test('straight-line fallback runs at 40 mph, with no ceiling', () {
      const km = 747.3 / 0.621371;
      final min = offerLegMinutes(km: km);
      // 1 202.66 km / 17.88 m/s = 1 121.1 min.
      expect(min, 1122);
      expect(min * 60 * kOfferFallbackSpeedMps, greaterThanOrEqualTo(km * 1000));
    });

    test('a road distance without a duration is not "1 min"', () {
      // The old card used `driverToPickupMin ?? 1`: a router that returned
      // metres but no seconds made any distance a one-minute drive.
      expect(offerLegMinutes(km: 40, roadMinutes: null), 38);
      expect(offerLegMinutes(km: 40, roadMinutes: double.nan), 38);
      expect(offerLegMinutes(km: 40, roadMinutes: 0), 38);
    });

    test('short and degenerate legs stay at least 1 min', () {
      expect(offerLegMinutes(km: 0), 1);
      expect(offerLegMinutes(km: double.nan), 1);
      expect(offerLegMinutes(km: 0.2, roadMinutes: 0.4), 1);
      expect(offerLegMinutes(km: 17.4, roadMinutes: 27.3), 28);
    });

    test('total and \$/hr use the corrected time', () {
      final pickup = offerLegMinutes(km: 1202.66, roadMinutes: 680.4);
      final trip = offerLegMinutes(km: 17.38, roadMinutes: 27.3);
      final total = offerTotalMinutes(pickup, trip);
      expect(total, 709);
      final s = S(const Locale('en'));
      expect(s.offerDuration(total), '11 h 49 min',
          reason: 'was "2 h 7 min" (99 + 28)');
      expect(offerPayPerHour(30.58, total).toStringAsFixed(2), '2.59',
          reason: 'was 14.45 (30.58 over the capped 127 min)');
      expect(s.offerAway(pickup, '747.3'), '11 h 21 min (747.3 mi) away');
    });

    test('no offer surface clamps minutes to 99 (or totals to 999) again',
        () {
      final cap = RegExp(r'\.clamp\(1,\s*99?9\)');
      for (final path in [
        'lib/screens/driver/driver_online_widgets.dart',
        'lib/screens/driver/scheduled_rides_map_screen.dart',
      ]) {
        final code = src(path);
        expect(cap.hasMatch(code), isFalse,
            reason: '$path caps offer minutes again — a far pickup prints '
                '"1 h 39 min" whatever its miles say');
        expect(code, contains('offerLegMinutes('));
      }
      // The reservations map's Lyft-style card (owner 2026-11-03) shows the
      // ride's own minutes, not a pickup + ride total.
      expect(src('lib/screens/driver/driver_online_widgets.dart'),
          contains('offerTotalMinutes('));
      final widgets = src('lib/screens/driver/driver_online_widgets.dart');
      expect(widgets, contains('offerPayPerHour(fare, totalMin)'));
      expect(widgets, isNot(contains('driverToPickupMin ?? 1')));
      expect(widgets, isNot(contains('pickupToDropoffMin ?? 1')));

      // The accept celebration reads the same leg right after the card.
      final controller = src('lib/screens/driver/driver_online_controller.dart');
      expect(controller, contains('_etaToPickup = offerLegMinutes(km: _distToPickup)'));
      expect(src('lib/screens/driver/trip_accepted_overlay.dart'),
          contains('offerDuration(widget.etaMinutes)'));
    });
  });

  group('the card is exactly as wide as the Accept pill', () {
    test('card and pill share one side inset', () {
      final widgets = src('lib/screens/driver/driver_online_widgets.dart');
      expect(widgets, contains('const double _kOfferSideInset = 20.0;'));
      expect(widgets,
          contains('horizontal: _kOfferSideInset, vertical: 4),\n                      child: card,'));
      expect(
          widgets,
          contains('_kOfferSideInset, 4, _kOfferSideInset, 8),\n'
              '                    child: _buildAcceptButton(offer, oid),'));
      expect(widgets, isNot(contains('horizontal: 4, vertical: 4),\n                      child: card,')),
          reason: 'the old 4 px card inset made the card 32 px wider');
    });
  });

  group('rider on an offer = first name + last initial', () {
    test('shortName', () {
      expect(shortName('Lisbeth Tosta'), 'Lisbeth T.');
      expect(shortName('  Lisbeth   Tosta  '), 'Lisbeth T.');
      expect(shortName('Lisbeth T.'), 'Lisbeth T.');
      expect(shortName('Maria Jose tosta'), 'Maria T.');
      expect(shortName('John Smith Jr.'), 'John S.');
      expect(shortName('Ángel Ñúñez'), 'Ángel Ñ.');
      expect(shortName('Lisbeth'), 'Lisbeth');
      expect(shortName(''), '');
      expect(shortName('   '), '');
      expect(shortName('Guest Rider'), 'Guest Rider');
    });

    test('offer cards use it; the post-accept screens keep the full name',
        () {
      final widgets = src('lib/screens/driver/driver_online_widgets.dart');
      expect(widgets,
          contains("nh.shortName((offer['rider_name'] as String?) ?? '')"));
      final trip = src('lib/screens/driver/driver_trip_accept_screen.dart');
      expect(trip,
          contains("nh.shortName((offer['rider_name'] as String?) ?? '')"),
          reason: 'the chained-offer card is an offer too');
      // Pickup identification (owner decision 2026-04-19) is unchanged.
      expect(displayName('Lisbeth Tosta'), 'Lisbeth Tosta');
    });
  });

  test('no drive time anywhere in lib/ is capped at 99 min', () {
    // The same 99 cap that printed "1 h 39 min (747.3 mi) away" lived in the
    // accept/resume seeds, the chained offer, the trip screen and the rider
    // tracking map (2026-11-01).
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (text.contains('clamp(1, 99)') || text.contains('clamp(0, 99)')) {
        hits.add(f.path);
      }
    }
    expect(hits, isEmpty);
  });
}
