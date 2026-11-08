import 'dart:io';

import 'package:cruise_app/services/place_ranking.dart';
import 'package:cruise_app/services/places_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Owner report 2026-11-08: a rider in Hoover, AL typing "3659 Lorna Rd" got
// the same house in Birmingham, Montgomery TX, Jacksonville FL and Boston,
// and "walmart" gave street names instead of the stores. The rows below are
// the real answers Google and Mapbox gave that day for that rider.

PlaceSuggestion g(String main, String secondary, double? meters,
        {List<String> types = const ['geocode']}) =>
    PlaceSuggestion(
      description: '$main, $secondary, USA',
      placeId: 'g:$main:$secondary',
      mainText: main,
      secondaryText: secondary,
      distanceMiles: meters == null ? null : meters / 1609.344,
      types: types,
    );

PlaceSuggestion m(String main, String rest, double meters) => PlaceSuggestion(
      description: '$main, $rest, United States',
      placeId: 'mapbox:$main:$rest',
      mainText: main,
      secondaryText: rest,
      distanceMiles: meters / 1609.344,
    );

List<String> rows(List<PlaceSuggestion> list) =>
    [for (final s in list) '${s.mainText} | ${s.secondaryText}'];

List<PlaceSuggestion> search(String q, List<PlaceSuggestion> merged,
        {String? state = 'AL'}) =>
    rankPlacesForRider(q, dedupePlaces(merged), riderState: state);

final lornaGoogle = [
  g('3659 Lorna Rd', 'Birmingham, AL', 2908),
  g('3659 Lorna Ridge Drive', 'Hoover, AL', 2290),
  g('3659 Lorna Rd', 'Montgomery, TX', 898357),
  g('3659 Lorna Rd', 'Jacksonville, FL', 599646),
  g('3659 Lorna Rd', 'Boston, MA', null),
];
final lornaMapbox = [
  m('3659 Lorna Road', 'Hoover, Alabama 35216', 2945),
  m('3659 Lorna Ridge Drive', 'Hoover, Alabama 35216', 2261),
  m('Lorna Ridge Dr', 'Pelham, Alabama 35124', 7723),
  m('Lorna Road', 'Mattapan, Massachusetts 02126', 1692714),
  m('3659 Old Lorena Road', 'Lorena, Texas 76655', 1003274),
  m('Lorna Road', 'Vestavia Hills, Alabama 35216', 594),
];

void main() {
  group('the state a place line names', () {
    test('code or full name, zip and country ignored', () {
      expect(stateOfPlaceText('Walmart Supercenter, Lakeshore Parkway, '
          'Homewood, AL, USA'), 'AL');
      expect(stateOfPlaceText('3659 Lorna Road, Hoover, Alabama 35216, '
          'United States'), 'AL');
      expect(stateOfPlaceText('Lorna Road, Mattapan, Massachusetts 02126, '
          'United States'), 'MA');
      expect(stateOfPlaceText('Airport, Indianapolis, IN, USA'), 'IN');
      expect(stateOfPlaceText('1600 Pennsylvania Ave NW, Washington, DC, '
          'USA'), 'DC');
    });

    test('a street or a business named after a state is not the state', () {
      expect(stateOfPlaceText('Georgia Ave, Hoover, AL, USA'), 'AL');
      expect(stateOfPlaceText('Alabama Grill, Main St, Tampa, FL, USA'), 'FL');
      expect(stateOfPlaceText('Somewhere'), isNull);
    });

    test('the country falls off the city line', () {
      expect(withoutCountry('Homewood, AL, USA'), 'Homewood, AL');
      expect(withoutCountry('Hoover, Alabama 35216, United States'),
          'Hoover, Alabama 35216');
    });
  });

  group('"3659 Lorna Rd" from Hoover, AL', () {
    final result = search('3659 Lorna Rd', [...lornaGoogle, ...lornaMapbox]);

    test('the house appears once, the right one first', () {
      expect(rows(result).first, '3659 Lorna Rd | Birmingham, AL');
      expect(rows(result).where((r) => r.contains('3659 Lorna R')
          && !r.contains('Ridge')), hasLength(1));
      expect(rows(result).where((r) => r.contains('3659 Lorna Ridge')),
          hasLength(1));
    });

    test('no copy of it in another state', () {
      for (final r in rows(result)) {
        expect(r, isNot(matches(RegExp(r'TX|FL|MA|Texas|Massachusetts'))));
      }
      expect(rows(result), [
        '3659 Lorna Rd | Birmingham, AL',
        '3659 Lorna Ridge Drive | Hoover, AL',
        'Lorna Road | Vestavia Hills, Alabama 35216',
        'Lorna Ridge Dr | Pelham, Alabama 35124',
      ]);
    });

    test('typing the other city still finds it', () {
      final boston = search('3659 Lorna Rd Boston',
          [...lornaGoogle, ...lornaMapbox]);
      expect(rows(boston).first, '3659 Lorna Rd | Boston, MA');
    });

    test('without the rider\'s state nothing is dropped', () {
      final all = search('3659 Lorna Rd', [...lornaGoogle, ...lornaMapbox],
          state: null);
      expect(rows(all).any((r) => r.contains('Jacksonville')), isTrue);
    });
  });

  test('"walmart" lists the stores by name, closest first, none abroad', () {
    final result = search('walmart', [
      g('Walmart Supercenter', 'Lakeshore Parkway, Homewood, AL', 4707,
          types: const ['department_store', 'store']),
      g('Walmart Supercenter', 'U.S. 31, Calera, AL', 29336,
          types: const ['department_store', 'store']),
      g('Walmart Supercenter', 'Trussville Crossings Parkway, Birmingham, AL',
          30995, types: const ['department_store', 'store']),
      g('Walmart Supercenter', 'John Hawkins Parkway, Hoover, AL', 5005,
          types: const ['department_store', 'store']),
      g('Walmart Supercenter', 'Montclair Road, Birmingham, AL', 16146,
          types: const ['department_store', 'store']),
      m('Walmart Drive', 'Empire, Alabama 35063', 41000),
      m('Walmart Drive', 'Louisville, Mississippi 39339', 260000),
      m('Walmart Circle', 'Booneville, Mississippi 38829', 250000),
      m('Walmart Way', 'Hampton, Georgia 30228', 230000),
    ]);
    expect(rows(result), [
      'Walmart Supercenter | Lakeshore Parkway, Homewood, AL',
      'Walmart Supercenter | John Hawkins Parkway, Hoover, AL',
      'Walmart Supercenter | Montclair Road, Birmingham, AL',
      'Walmart Supercenter | U.S. 31, Calera, AL',
      'Walmart Supercenter | Trussville Crossings Parkway, Birmingham, AL',
      'Walmart Drive | Empire, Alabama 35063',
    ]);
    expect(result.first.icon, PlaceSuggestion(
      description: '', placeId: '', types: const ['store']).icon);
  });

  group('"airport" from Hoover, AL', () {
    final merged = [
      g('Birmingham-Shuttlesworth International Airport (BHM)',
          'Messer Airport Highway, Birmingham, AL', 18259,
          types: const ['airport']),
      g('ATL airport (ATL)', 'North Terminal Parkway, Atlanta, GA', 221893,
          types: const ['airport']),
      g('Huntsville International Airport (HSV)', 'Huntsville, AL', 137062,
          types: const ['airport']),
      g('Airport', 'Indianapolis, IN', 705953),
    ];
    // Mapbox's roads named Airport — closer than BHM, still not the airport.
    PlaceSuggestion road(String main, String rest, double meters) =>
        PlaceSuggestion(
          description: '$main, $rest, United States',
          placeId: 'mapbox:$main:$rest',
          mainText: main,
          secondaryText: rest,
          distanceMiles: meters / 1609.344,
          types: const ['route'],
        );

    test('the home state\'s airports, closest first', () {
      final result = search('airport', merged);
      expect(rows(result), [
        'Birmingham-Shuttlesworth International Airport (BHM) | '
            'Messer Airport Highway, Birmingham, AL',
        'Huntsville International Airport (HSV) | Huntsville, AL',
      ]);
    });

    test('the airport before roads named Airport, even closer ones', () {
      final result = search('airport', [
        ...merged,
        road('Airport Lane Southwest', 'Bessemer, Alabama 35022', 17400),
        road('Airport Boulevard', 'Birmingham, Alabama 35212', 17900),
      ]);
      expect(rows(result).take(2), [
        'Birmingham-Shuttlesworth International Airport (BHM) | '
            'Messer Airport Highway, Birmingham, AL',
        'Huntsville International Airport (HSV) | Huntsville, AL',
      ]);
      expect(rows(result).skip(2), [
        'Airport Lane Southwest | Bessemer, Alabama 35022',
        'Airport Boulevard | Birmingham, Alabama 35212',
      ]);
      // Typing the road still puts the road first.
      final blvd = search('airport blvd', [
        ...merged,
        road('Airport Boulevard', 'Birmingham, Alabama 35212', 17900),
      ]);
      expect(rows(blvd).first, 'Airport Boulevard | Birmingham, Alabama 35212');
    });

    test('naming another state\'s airport finds it', () {
      final result = search('atl airport', merged);
      expect(rows(result).first, 'ATL airport (ATL) | North Terminal Parkway, '
          'Atlanta, GA');
    });
  });

  test('a neighbour across the state line stays (Phenix City → Columbus)',
      () {
    final result = search('columbus park crossing', [
      g('Columbus Park Crossing', 'Columbus, GA', 9000),
      g('Phenix City Park', 'Phenix City, AL', 3000),
    ]);
    expect(rows(result), contains('Columbus Park Crossing | Columbus, GA'));
  });

  test('"galleria": a road both providers name is one row, the measured one',
      () {
    PlaceSuggestion road(String main, String rest, double? meters,
            {bool mapbox = false}) =>
        PlaceSuggestion(
          description: mapbox
              ? '$main, $rest, United States'
              : '$main, $rest, USA',
          placeId: mapbox ? 'mapbox:$main:$rest' : 'g:$main:$rest',
          mainText: main,
          secondaryText: rest,
          distanceMiles: meters == null ? null : meters / 1609.344,
          types: const ['route'],
        );
    // Live answers 2026-11-08: Google sends bare roads with no distance.
    final result = search('galleria', [
      g('Galleria Animal Clinic', 'John Hawkins Parkway, Hoover, AL', 4020,
          types: const ['veterinary_care', 'establishment']),
      g('Galleria Woods', 'Galleria Woods Drive, Hoover, AL', 4670,
          types: const ['health', 'establishment']),
      road('Galleria Circle', 'Hoover, AL', null),
      road('Galleria Boulevard', 'Birmingham, AL', null),
      road('Galleria Circle', 'Hoover, Alabama 35244', 3220, mapbox: true),
      road('Galleria Boulevard', 'Hoover, Alabama 35244', 3700, mapbox: true),
      road('Galleria Woods Drive', 'Hoover, Alabama 35244', 4500,
          mapbox: true),
    ]);
    expect(rows(result), [
      'Galleria Animal Clinic | John Hawkins Parkway, Hoover, AL',
      'Galleria Woods | Galleria Woods Drive, Hoover, AL',
      'Galleria Circle | Hoover, Alabama 35244',
      'Galleria Boulevard | Hoover, Alabama 35244',
      'Galleria Woods Drive | Hoover, Alabama 35244',
    ]);
  });

  test('Mapbox fuzzy filler goes; Google typo fixes stay', () {
    final galleria = search('galleria', [
      g('Galleria Animal Clinic', 'John Hawkins Parkway, Hoover, AL', 4020,
          types: const ['establishment']),
      m('Crowne Reserve', 'Hoover, Alabama 35244', 4700),
    ]);
    expect(rows(galleria), ['Galleria Animal Clinic | John Hawkins Parkway, '
        'Hoover, AL']);
    final typo = search('walmrt', [
      g('Walmart Supercenter', 'Lakeshore Parkway, Homewood, AL', 4707,
          types: const ['department_store']),
    ]);
    expect(typo, hasLength(1));
  });

  test('two different Main Streets of one state stay two when both measured',
      () {
    final result = search('main st', [
      m('Main Street', 'Trussville, Alabama 35173', 30000),
      m('Main Street', 'Montevallo, Alabama 35115', 45000),
    ]);
    expect(result, hasLength(2));
  });

  test('what kind of place a row is, for its mark', () {
    PlaceType kind(List<String> types) =>
        PlaceSuggestion(description: 'x', placeId: 'x', types: types)
            .placeType;
    // Google's Walmart: no bare "store" in its first types.
    expect(kind(const ['department_store', 'food_store', 'establishment']),
        PlaceType.commerce);
    expect(kind(const ['restaurant', 'food', 'establishment']),
        PlaceType.business);
    expect(kind(const ['establishment']), PlaceType.business);
    expect(kind(const ['airport', 'establishment']), PlaceType.airport);
    expect(kind(const ['subpremise', 'geocode']), PlaceType.home);
    expect(kind(const ['route']), PlaceType.home);
  });

  test('distance text under the icon', () {
    expect(placeDistanceText(0.02), '0.1');
    expect(placeDistanceText(2.94), '2.9');
    expect(placeDistanceText(18.6), '19');
  });

  group('wiring', () {
    final service = File('lib/services/places_service.dart').readAsStringSync();
    final screen =
        File('lib/screens/pickup_dropoff_search_screen.dart').readAsStringSync();
    final proxy = File('backend/routers/misc.py').readAsStringSync();

    test('Google is asked with a bias it honours and measures from the rider',
        () {
      expect(service, contains("params['locationbias'] = 'circle:50000@"));
      expect(service, contains("params['origin'] = '\$lat,\$lon';"));
      expect(service, isNot(contains("params['radius'] = '160000';")));
      expect(proxy, contains('params["locationbias"] = f"circle:50000@'));
      expect(proxy, contains('"distance_meters": p.get("distance_meters")'));
      expect(proxy, isNot(contains('params["radius"] = "160000"')));
    });

    test('one Google answer; Mapbox POIs only when Google has none', () {
      expect(service, isNot(contains("types: 'geocode')")));
      expect(service, contains('if (google.isEmpty) ...box,'));
      expect(service, contains('rankPlacesForRider(cleanInput, dedupePlaces('));
    });

    test('the field rail is the offer card\'s: rings + RouteConnectorLine', () {
      expect(screen, contains('RouteConnectorLine'));
      expect(screen, contains('const _Dot(_Mark.pickup)'));
      expect(screen, contains('const _Dot(_Mark.dropoff)'));
      expect(screen, isNot(contains('_DotConnectorLine')));
      // One thin-line family (owner pick B, then "los negocios y
      // aeropuertos también"), never the font's filled glyphs.
      expect(screen, contains('PlaceGlyph(widget.suggestion.placeType)'));
      expect(screen, isNot(contains('Icons.place_rounded, color: _gold')));
      expect(screen, contains('placeDistanceMi('));
    });
  });
}
