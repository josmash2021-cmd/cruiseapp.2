import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/map/map_callout.dart';

/// The text of the Lyft-style map callouts (owner spec 2026-11-01): the
/// trip line ("$10 CRUISE" / "9 min away"), the airport line ("1-5
/// Drivers"), the zoom hysteresis and the once-per-hour count cadence.
void main() {
  final en = S(const Locale('en'));
  final es = S(const Locale('es'));

  group('trip price', () {
    test('the driver pay to the cent, exactly as the offer card writes it',
        () {
      // Owner 2026-11-05: the callout said $13 and the card $12.98.
      expect(tripCalloutPrice(10), r'$10.00');
      expect(tripCalloutPrice(12.98), r'$12.98');
      expect(tripCalloutPrice(10.5), r'$10.50');
      expect(tripCalloutPrice('12.7'), r'$12.70', reason: 'numeric strings too');
      expect(tripCalloutPrice(-3), r'$0.00');
      for (final f in [8.65, 10.01, 12.98, 18.2, 33.333]) {
        expect(tripCalloutPrice(f), '\$${f.toStringAsFixed(2)}',
            reason: 'the card prints \$${f.toStringAsFixed(2)}');
      }
    });

    test('no usable fare → no price', () {
      expect(tripCalloutPrice(null), isNull);
      expect(tripCalloutPrice('abc'), isNull);
      expect(tripCalloutPrice(double.nan), isNull);
      expect(tripCalloutPrice(true), isNull);
    });
  });

  test('product: CRUISE + the booking tier, uppercase', () {
    for (final std in ['standard', 'comfort', 'Fusion', '', null]) {
      expect(tripCalloutProduct(std), 'CRUISE', reason: '$std');
    }
    expect(tripCalloutProduct('compact'), 'CRUISE COMPACT');
    expect(tripCalloutProduct('Sedan'), 'CRUISE COMPACT',
        reason: 'the picker sold "Sedan" as Compact (tripTierKey)');
    expect(tripCalloutProduct('premium'), 'CRUISE PREMIUM');
    expect(tripCalloutProduct('SUV XL'), 'CRUISE PREMIUM');
    expect(tripCalloutProduct('vip'), 'CRUISE VIP');
    expect(tripCalloutProduct('black'), 'CRUISE VIP');
    expect(tripCalloutProduct('electric_pro'), 'CRUISE ELECTRIC PRO');
  });

  group('minutes to the pickup', () {
    test('pickup_eta_min as-is, never capped', () {
      expect(tripCalloutMinutes({'pickup_eta_min': 9}), 9);
      expect(tripCalloutMinutes({'pickup_eta_min': '9'}), 9);
      expect(tripCalloutMinutes({'pickup_eta_min': 680}), 680);
      expect(tripCalloutMinutes({'pickup_eta_min': 9.2}), 10);
    });

    test('without it, the road miles at the offer fallback speed', () {
      // 5 mi = 8.045 km at 17.88 m/s = 7.5 min → 8.
      expect(
          tripCalloutMinutes({'pickup_distance_miles': 5}), 8);
      expect(
          tripCalloutMinutes(
              {'pickup_eta_min': null, 'pickup_distance_miles': '5'}),
          8);
      expect(tripCalloutMinutes({}), isNull);
    });

    test('ES / EN', () {
      expect(en.tripCalloutMinAway(9), '9 min away');
      expect(es.tripCalloutMinAway(9), 'a 9 min');
    });
  });

  group('pickup coordinates (null-safe — the backend may not send them)', () {
    test('num or numeric string', () {
      expect(tripCalloutPickup({'pickup_lat': 33.56, 'pickup_lng': -86.75}),
          (lat: 33.56, lng: -86.75));
      expect(tripCalloutPickup({'pickup_lat': '33.56', 'pickup_lng': '-86.75'}),
          (lat: 33.56, lng: -86.75));
    });

    test('missing, null, junk, (0,0) or off the globe → null', () {
      expect(tripCalloutPickup({}), isNull);
      expect(tripCalloutPickup({'pickup_lat': null, 'pickup_lng': null}),
          isNull);
      expect(tripCalloutPickup({'pickup_lat': 'x', 'pickup_lng': -86.7}),
          isNull);
      expect(tripCalloutPickup({'pickup_lat': 0, 'pickup_lng': 0}), isNull);
      expect(tripCalloutPickup({'pickup_lat': 95, 'pickup_lng': 10}), isNull);
      expect(tripCalloutPickup({'pickup_lat': 30, 'pickup_lng': 190}),
          isNull);
    });
  });

  group('buildTripCallouts', () {
    Map<String, dynamic> item(int id,
            {Object? fare = 9.6,
            Object? lat = 33.5,
            Object? lng = -86.8,
            Object? vt = 'standard'}) =>
        {
          'trip_id': id,
          'fare': fare,
          'vehicle_type': vt,
          'pickup_eta_min': 9,
          'pickup_lat': lat,
          'pickup_lng': lng,
        };

    test('one callout per trip with a pickup; the rest are skipped', () {
      final out = buildTripCallouts([
        item(1),
        item(2, lat: null, lng: null), // backend without coords: inert
        {'fare': 5, 'pickup_lat': 1, 'pickup_lng': 1}, // no trip id
        item(1), // duplicate
        item(3, vt: 'premium', fare: 18.2),
      ], minAway: en.tripCalloutMinAway);
      expect(out.map((c) => c.tripId), [1, 3]);
      expect(out[0].title, r'$9.60 CRUISE');
      expect(out[0].keepRun, r'$9.60');
      expect(out[0].fadeRun, ' CRUISE');
      expect(out[0].subtitle, '9 min away');
      expect(out[1].title, r'$18.20 CRUISE PREMIUM');
      expect(out[1].fadeRun, ' CRUISE PREMIUM');
    });

    test('a backend that sends no pickup_lat/lng draws nothing', () {
      final out = buildTripCallouts([
        {'trip_id': 1, 'fare': 10, 'pickup_eta_min': 9},
        {'trip_id': 2, 'fare': 12, 'pickup_eta_min': 4},
      ], minAway: en.tripCalloutMinAway);
      expect(out, isEmpty);
    });

    test('no fare: the product stays, nothing fades', () {
      final out = buildTripCallouts([item(7, fare: null)],
          minAway: es.tripCalloutMinAway);
      expect(out.single.title, 'CRUISE');
      expect(out.single.keepRun, 'CRUISE');
      expect(out.single.fadeRun, isNull);
      expect(out.single.subtitle, 'a 9 min');
    });

    test('an unchanged poll is the same list; any change is not', () {
      final a = buildTripCallouts([item(1), item(3)],
          minAway: en.tripCalloutMinAway);
      final b = buildTripCallouts([item(1), item(3)],
          minAway: en.tripCalloutMinAway);
      expect(sameTripCallouts(a, b), isTrue);
      final fare = buildTripCallouts([item(1, fare: 14), item(3)],
          minAway: en.tripCalloutMinAway);
      expect(sameTripCallouts(a, fare), isFalse);
      final moved = buildTripCallouts([item(1, lat: 33.6), item(3)],
          minAway: en.tripCalloutMinAway);
      expect(sameTripCallouts(a, moved), isFalse);
    });
  });

  test('zoom hysteresis: expanded at >= 11.0, compact below 10.6', () {
    expect(calloutExpandedForZoom(10.9, wasExpanded: false), isFalse);
    expect(calloutExpandedForZoom(11.0, wasExpanded: false), isTrue);
    expect(calloutExpandedForZoom(10.7, wasExpanded: true), isTrue);
    expect(calloutExpandedForZoom(10.6, wasExpanded: true), isTrue);
    expect(calloutExpandedForZoom(10.59, wasExpanded: true), isFalse);
    expect(calloutExpandedForZoom(15.5, wasExpanded: false), isTrue);
    expect(calloutExpandedForZoom(double.nan, wasExpanded: true), isTrue);
  });

  test('morph timing: 380 ms; line 2 fades on the raw run', () {
    expect(kCalloutMorphDuration, const Duration(milliseconds: 380));
    expect(kCalloutMorphCurve, Curves.easeInOutCubic);
    expect(calloutFadeOpacity(1), 1);
    expect(calloutFadeOpacity(0.45), 0);
    expect(calloutFadeOpacity(0), 0);
    // Collapsing: gone 55 % into the run (v = 0.45); half-way at 27.5 %.
    expect(calloutFadeOpacity(1 - 0.275), closeTo(0.5, 1e-9));
    // Expanding: starts at 45 % of the run, half-way at 72.5 %.
    expect(calloutFadeOpacity(0.725), closeTo(0.5, 1e-9));
  });

  group('airport driver buckets', () {
    test('the owner\'s ranges', () {
      const cases = {
        -1: '0',
        0: '0',
        1: '1-5',
        5: '1-5',
        6: '5-15',
        9: '5-15',
        10: '10-15',
        15: '10-15',
        16: '15-20',
        20: '15-20',
        21: '20-30',
        30: '20-30',
        31: '30+',
        200: '30+',
      };
      cases.forEach((n, bucket) {
        expect(airportDriversBucket(n), bucket, reason: '$n drivers');
      });
    });

    test('"Drivers" capitalised in EN, "conductores" in ES', () {
      expect(en.airportDriversLabel(airportDriversBucket(0)), '0 Drivers');
      expect(en.airportDriversLabel(airportDriversBucket(3)), '1-5 Drivers');
      expect(es.airportDriversLabel(airportDriversBucket(7)),
          '5-15 conductores');
      expect(es.airportDriversLabel(airportDriversBucket(0)),
          '0 conductores');
    });
  });

  test('airport counts: fetched once, then only in a new local hour', () {
    final counts = AirportDriverCounts();
    final t1005 = DateTime(2026, 11, 1, 10, 5);
    expect(counts.countFor('BHM'), isNull, reason: 'no second line yet');
    expect(counts.staleCodes(['BHM', 'HSV'], t1005), ['BHM', 'HSV']);
    counts.store(['BHM', 'HSV'], {'BHM': 3}, t1005);
    expect(counts.countFor('BHM'), 3);
    expect(counts.countFor('HSV'), 0, reason: 'asked and nobody there');
    // The rest of the hour: nothing to fetch, the label cannot change.
    expect(counts.staleCodes(['BHM', 'HSV'], DateTime(2026, 11, 1, 10, 59)),
        isEmpty);
    // A new hour: ask again — the old value stays until the answer lands.
    final t1100 = DateTime(2026, 11, 1, 11, 0, 1);
    expect(counts.staleCodes(['BHM', 'HSV'], t1100), ['BHM', 'HSV']);
    expect(counts.countFor('BHM'), 3);
    counts.store(['BHM'], {'BHM': 12}, t1100);
    expect(counts.countFor('BHM'), 12);
    // A code first seen mid-hour is fetched for itself only.
    expect(counts.staleCodes(['BHM', 'MOB'], t1100), ['MOB']);
    expect(calloutNextHour(t1005), DateTime(2026, 11, 1, 11));
  });
}
