import 'dart:io';
import 'dart:typed_data';

import 'package:cruise_app/data/airport_airlines.dart';
import 'package:cruise_app/data/airport_data.dart';
import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/driver/nav_trip_panel.dart';
import 'package:cruise_app/screens/driver/reservation_offer_card.dart';
import 'package:cruise_app/widgets/airline_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-16 (drawing https://claude.ai/artifact/6YSvXDpGS4T2mKy8L92gvj):
/// the dispatch panel saves the airline on a reservation to the airport and
/// writes the airport end as the rider app does — "FLL · Terminal 1 — United
/// Airlines", `airport_code` "FLL" — but keeps `is_airport` FALSE (pricing).
/// The driver still sees the AIRPORT badge and the airline's real logo.

// A 1×1 transparent PNG.
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  const fllUnited = 'FLL · Terminal 1 — United Airlines';

  group('the airport rule', () {
    test('airport_code alone makes it an airport ride', () {
      expect(tripIsAirport({'is_airport': false, 'airport_code': 'FLL'}),
          isTrue,
          reason: 'a panel reservation keeps is_airport false');
      expect(tripIsAirport({'airport_code': 'FLL'}), isTrue);
      expect(tripIsAirport({'is_airport': true}), isTrue);
      // FCM data is all strings.
      expect(tripIsAirport({'is_airport': 'true'}), isTrue);
      expect(tripIsAirport({'is_airport': '1'}), isTrue);
    });

    test('no flag and no code is an ordinary ride', () {
      expect(tripIsAirport(null), isFalse);
      expect(tripIsAirport(const {}), isFalse);
      expect(tripIsAirport({'is_airport': false}), isFalse);
      expect(tripIsAirport({'is_airport': false, 'airport_code': ''}), isFalse);
      expect(tripIsAirport({'airport_code': '  '}), isFalse);
      expect(tripIsAirport({'airport_code': 'None'}), isFalse);
      expect(tripIsAirport({'airport_code': null}), isFalse);
    });
  });

  group('the airline from the address', () {
    test('"FLL · Terminal 1 — United Airlines" → United → UA', () {
      expect(airlineFromAddress(fllUnited), 'United Airlines');
      expect(airlineIataFor(airlineFromAddress(fllUnited)!), 'UA');
      // Terminal not confirmed: the airport's name stands in for it.
      expect(
          airlineFromAddress(
              'FLL · Fort Lauderdale-Hollywood Intl — Southwest Airlines'),
          'Southwest Airlines');
      // A terminal name with its own dash: the airline is the LAST part.
      expect(
          airlineFromAddress('TPA · Main Terminal — Airside E — Delta Air Lines'),
          'Delta Air Lines');
    });

    test('no airline, no logo', () {
      expect(airlineFromAddress(null), isNull);
      expect(airlineFromAddress(''), isNull);
      expect(airlineFromAddress('FLL · Terminal 1'), isNull);
      expect(airlineFromAddress('MIA · Terminal D (North) — Door D1'), isNull,
          reason: 'a pickup at the airport carries the arrival door');
      expect(airlineFromAddress('MIA · Terminal J (South) — Charter / Private'),
          isNull);
      expect(airlineFromAddress('3659 Lorna Rd, Hoover, AL, USA'), isNull);
    });
  });

  test('FLL: United and Southwest fly from Terminal 1', () {
    final fll = kCommonAirports.firstWhere((a) => a.code == 'FLL');
    final t1 = fll.terminals.firstWhere((t) => t.name == 'Terminal 1');
    expect(t1.airlines, containsAll(['United Airlines', 'Southwest Airlines']));
    for (final t in fll.terminals.where((t) => t.name != 'Terminal 1')) {
      expect(t.airlines, isNot(contains('United Airlines')), reason: t.name);
      expect(t.airlines, isNot(contains('Southwest Airlines')), reason: t.name);
    }
  });

  group('the driver sees it', () {
    final asked = <String>[];
    setUp(() {
      asked.clear();
      AirlineLogo.providerFor = (url) {
        asked.add(url);
        return MemoryImage(_png);
      };
    });
    tearDown(() => AirlineLogo.providerFor = (url) => NetworkImage(url));

    Widget host(Widget child) => MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('es'), Locale('en')],
          home: child,
        );

    void phone(WidgetTester t) {
      t.view.physicalSize = const Size(390 * 3, 844 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
    }

    Map<String, dynamic> trip(String dropoff, {String? code}) => {
          'id': 9,
          'fare': 41.20,
          'pickup_address': '3452 30th Way N, Fort Lauderdale, FL',
          'dropoff_address': dropoff,
          'pickup_lat': 26.1400,
          'pickup_lng': -80.1700,
          'dropoff_lat': 26.0726,
          'dropoff_lng': -80.1527,
          'duration_minutes': 18,
          'distance_miles': 9.4,
          'rider_name': 'Apple Carter',
          'rider_rating': 5.0,
          'is_airport': false,
          if (code != null) 'airport_code': code,
        };

    testWidgets('reservation card: AEROPUERTO + the airline logo', (t) async {
      phone(t);
      await t.pumpWidget(host(Scaffold(
        body: Center(
          child: ReservationOfferCard(
              trip: trip(fllUnited, code: 'FLL'), whenLabel: 'Mañana · 5:30 AM'),
        ),
      )));
      await t.pump();
      expect(find.text('AEROPUERTO'), findsOneWidget);
      expect(find.text(fllUnited), findsOneWidget,
          reason: 'the destination text stays whole');
      final logo = t.widget<AirlineLogo>(find.byType(AirlineLogo));
      expect(logo.airline, 'United Airlines');
      expect(logo.size, lessThanOrEqualTo(30));
      expect(asked.single, endsWith('/static/airlines/UA.png'));
      expect(t.takeException(), isNull);
    });

    testWidgets('an ordinary reservation: no badge, no logo', (t) async {
      phone(t);
      await t.pumpWidget(host(Scaffold(
        body: Center(
          child: ReservationOfferCard(
              trip: trip('2680 Hackberry Ln, Vestavia Hills, AL'),
              whenLabel: 'Mañana · 5:30 AM'),
        ),
      )));
      await t.pump();
      expect(find.text('AEROPUERTO'), findsNothing);
      expect(find.byType(AirlineLogo), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('navigation panel: the logo on the drop-off row', (t) async {
      phone(t);
      await t.pumpWidget(host(MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0A1430),
          body: Stack(children: [
            Positioned.fill(
              child: NavTripPanel(
                etaLabel: '12 min · 9.4 mi',
                riderName: 'William Smith',
                riderPhotoUrl: '',
                riderId: null,
                toPickup: false,
                pickupAddress: '1102 Garden Woods Dr',
                dropoffAddress: fllUnited,
                fare: 41.20,
                moving: false,
                stage: NavPanelStage.driving,
                onOpenChat: () {},
                onSupport: () {},
                onCancelTrip: () {},
                onArrived: () {},
                onSlidePickUp: () {},
                onSlideFinish: () {},
              ),
            ),
          ]),
        ),
      )));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.drag(find.text('12 min · 9.4 mi'), const Offset(0, -120));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Dejar a William'), findsWidgets);
      expect(find.text(fllUnited), findsOneWidget);
      expect(t.widget<AirlineLogo>(find.byType(AirlineLogo)).airline,
          'United Airlines');
      expect(t.takeException(), isNull);
    });
  });

  group('every driver surface uses the same rule', () {
    final widgets = read('lib/screens/driver/driver_online_widgets.dart');
    final myRes = read('lib/screens/driver/my_reservations_page.dart');
    final card = read('lib/screens/driver/reservation_offer_card.dart');
    final nav = read('lib/screens/driver/nav_trip_panel.dart');
    final map = read('lib/screens/driver/scheduled_rides_map_screen.dart');

    test('no surface reads is_airport alone', () {
      for (final entry in {
        'driver_online_widgets': widgets,
        'my_reservations_page': myRes,
        'reservation_offer_card': card,
        'scheduled_rides_map_screen': map,
      }.entries) {
        expect(entry.value, isNot(contains("['is_airport'] == true")),
            reason: '${entry.key}: use tripIsAirport()');
        expect(entry.value, isNot(contains("['is_airport'] != true")),
            reason: '${entry.key}: use tripIsAirport()');
      }
      expect(widgets, contains('final bool isAirportTrip = tripIsAirport(offer);'));
      expect(card, contains('final isAirport = tripIsAirport(trip);'));
      expect(myRes, contains('final isAirport = tripIsAirport(t);'));
      expect(map, contains('if (_airportOnly && !tripIsAirport(t)) return false;'));
    });

    test('the reservation CONFIRM offer keeps its AIRPORT badge', () {
      final i = widgets.indexOf('if (isReservationConfirm) {');
      final j = widgets.indexOf('} else if (isScheduled) {', i);
      expect(i, greaterThan(0));
      expect(widgets.substring(i, j), contains('label: s.badgeAirport,'));
    });

    test('the offer, the reservation list and the nav panel draw the logo', () {
      expect(widgets, contains('dropoffAirline: airlineFromAddress(dropoffAddr),'));
      expect(widgets, contains(': AirlineLogo(dropoffAirline, size: 28),'));
      expect(card, contains('airlineFromAddress(trip[\'dropoff_address\']'));
      expect(myRes, contains('dropAirline: airlineFromAddress(dropAddr),'));
      expect(myRes, contains('AirlineLogo(dropAirline, size: 28),'));
      expect(myRes, contains('_airportBadge(s),'));
      expect(nav, contains('trailing: _airlineMark(widget.dropoffAddress),'));
      expect(nav, contains('trailing: _airlineMark(next.dropoffAddress),'));
    });
  });
}
