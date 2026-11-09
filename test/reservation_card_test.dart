import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/ride_booking_confirmed_screen.dart';
import 'package:cruise_app/widgets/reservation_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// The rider's reservations, Lyft-style (owner 2026-11-08, drawing
// https://claude.ai/artifact/KzawVoUMMVyLpHnKS7r7UU): ONE card on Inicio and
// Programar, and the "Viaje reservado" page for an existing reservation.
// Found walking the app: Inicio only said "Tienes un viaje reservado"; in its
// last half hour it showed TWO cards and a car bar that looked like the
// driver was already coming; the driver's name never arrived; the VIP
// cancel estimate looked up 'Vip' and said $5 instead of $10.

Map<String, dynamic> trip({
  required DateTime at,
  bool driver = false,
  String vehicle = 'Comfort',
  double fare = 38.40,
  bool coords = false,
}) =>
    {
      'id': 990001,
      'status': driver ? 'scheduled_accepted' : 'scheduled',
      'scheduled_at': at.toUtc().toIso8601String(),
      'pickup_address': '3659 Lorna Rd, Hoover, AL, USA',
      'dropoff_address':
          'BHM · Birmingham-Shuttlesworth International Airport — Delta Air Lines',
      if (coords) ...{
        'pickup_lat': 33.4162,
        'pickup_lng': -86.7946,
        'dropoff_lat': 33.5629,
        'dropoff_lng': -86.7535,
      },
      'vehicle_type': vehicle,
      'fare': fare,
      'driver_id': driver ? 3 : null,
      if (driver) ...{
        'driver_name': 'Jhon Martinez',
        'driver_rating': 4.9,
        'vehicle_make': 'Toyota',
        'vehicle_model': 'Camry',
        'vehicle_plate': 'ABC1234',
      },
    };

Future<void> pump(WidgetTester t, String lang, Widget child) async {
  // Wide: the test font draws every letter as a full block.
  t.view.physicalSize = const Size(900 * 3, 1600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: Locale(lang),
    localizationsDelegates: const [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('es'), Locale('en')],
    home: Scaffold(body: child),
  ));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  // Sunday 8 Nov 2026, 8:30 PM — the reservation is Monday 5:30 AM.
  final now = DateTime(2026, 11, 8, 20, 30);
  final tomorrow = DateTime(2026, 11, 9, 5, 30);

  testWidgets('Inicio: when, where, car and price, "Ver las 2"', (t) async {
    await pump(
      t,
      'es',
      ReservationCard(
        reservation: Reservation.fromTrip(trip(at: tomorrow))!,
        style: ReservationCardStyle.home,
        count: 2,
        now: now,
      ),
    );
    expect(find.text('PRÓXIMA RESERVA'), findsOneWidget);
    expect(find.text('Mañana · 5:30 AM'), findsOneWidget);
    expect(find.text('Ver las 2'), findsOneWidget);
    expect(find.text('3659 Lorna Rd'), findsOneWidget);
    expect(find.text('Hoover, AL'), findsOneWidget);
    expect(find.text('BHM · Birmingham-Shuttlesworth International Airport'),
        findsOneWidget);
    expect(find.text('Delta Air Lines'), findsOneWidget);
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('\$38.40'), findsOneWidget);
    expect(find.text('Buscando conductor'), findsOneWidget);
  });

  testWidgets('Inicio, last hour: countdown and who is coming', (t) async {
    await pump(
      t,
      'es',
      ReservationCard(
        reservation: Reservation.fromTrip(
            trip(at: now.add(const Duration(minutes: 24)), driver: true))!,
        style: ReservationCardStyle.home,
        now: now,
      ),
    );
    expect(find.text('TU RESERVA'), findsOneWidget);
    expect(find.text('En 24 min'), findsOneWidget);
    expect(find.text('Hoy · 8:54 PM'), findsOneWidget);
    expect(find.text('Jhon M.'), findsOneWidget);
    expect(find.text('Toyota Camry · ABC1234'), findsOneWidget);
    // The driver row says it; the corner counts down.
    expect(find.text('Buscando conductor'), findsNothing);
  });

  testWidgets('Programar: the day as the label, the time as the title',
      (t) async {
    await pump(
      t,
      'es',
      Column(children: [
        ReservationCard(
          reservation: Reservation.fromTrip(trip(at: tomorrow))!,
          now: now,
        ),
        ReservationCard(
          reservation: Reservation.fromTrip(trip(
              at: DateTime(2026, 11, 12, 15, 20),
              driver: true,
              vehicle: 'Premium',
              fare: 29.75))!,
          now: now,
        ),
      ]),
    );
    expect(find.text('MAÑANA · LUN 9 NOV'), findsOneWidget);
    expect(find.text('5:30 AM'), findsOneWidget);
    expect(find.text('JUE 12 NOV'), findsOneWidget);
    expect(find.text('3:20 PM'), findsOneWidget);
    expect(find.text('Conductor asignado'), findsOneWidget);
    expect(find.text('\$29.75'), findsOneWidget);
    expect(find.text('Jhon M.'), findsOneWidget);
  });

  testWidgets('…and in English', (t) async {
    await pump(
      t,
      'en',
      Column(children: [
        ReservationCard(
          reservation: Reservation.fromTrip(trip(at: tomorrow))!,
          style: ReservationCardStyle.home,
          count: 3,
          now: now,
        ),
        ReservationCard(
          reservation: Reservation.fromTrip(trip(at: tomorrow))!,
          now: now,
        ),
      ]),
    );
    expect(find.text('NEXT RESERVATION'), findsOneWidget);
    expect(find.text('Tomorrow · 5:30 AM'), findsOneWidget);
    expect(find.text('See all 3'), findsOneWidget);
    expect(find.text('TOMORROW · MON, NOV 9'), findsOneWidget);
    expect(find.text('Finding driver'), findsNWidgets(2));
  });

  test('a zone-less time is UTC, never the phone\'s', () {
    final at = Reservation.parseAt('2026-11-09T11:30:00')!;
    expect(at.toUtc(), DateTime.utc(2026, 11, 9, 11, 30));
    expect(Reservation.parseAt('2026-11-09T11:30:00+00:00')!.toUtc(),
        DateTime.utc(2026, 11, 9, 11, 30));
    expect(Reservation.parseAt(null), isNull);
  });

  test('cancel estimate: free without a driver or before the last hour', () {
    final soon = now.add(const Duration(minutes: 40));
    Reservation r(DateTime at, {bool driver = true, String v = 'Comfort', double f = 38.4}) =>
        Reservation.fromTrip(trip(at: at, driver: driver, vehicle: v, fare: f))!;
    expect(estimatedReservationCancelFee(r(soon, driver: false), now), 0);
    expect(estimatedReservationCancelFee(r(tomorrow), now), 0);
    expect(estimatedReservationCancelFee(r(soon), now), 5);
    // The old lookup asked the table for 'Vip' and fell back to $5.
    expect(estimatedReservationCancelFee(r(soon, v: 'VIP'), now), 10);
    expect(estimatedReservationCancelFee(r(soon, v: 'Electric Pro'), now), 5);
    expect(estimatedReservationCancelFee(r(soon, f: 3.5), now), 3.5);
  });

  testWidgets('the reservation page: cancel, and "Ver política" under it',
      (t) async {
    final real = DateTime.now();
    final at = DateTime(real.year, real.month, real.day + 2, 5, 30);
    await pump(
      t,
      'es',
      RideBookingConfirmedScreen.reservation(
          Reservation.fromTrip(trip(at: at))!),
    );
    expect(find.text('Viaje reservado'), findsNothing);
    expect(find.text('Listo'), findsNothing);
    expect(find.text('5:30 AM'), findsOneWidget);
    expect(find.text('Buscando conductor'), findsOneWidget);
    expect(find.text('Cancela gratis hasta las 4:30 AM'), findsOneWidget);
    final cancel = t.getCenter(find.text('Cancelar reserva'));
    final policy = t.getCenter(find.text('Ver política'));
    expect(policy.dy, greaterThan(cancel.dy));
    // A button like Cancelar, not a link (owner 2026-11-08).
    final policyBtn = find.byKey(const ValueKey('reservation-policy'));
    expect(t.widget(policyBtn), isA<ElevatedButton>());
    expect(t.getSize(policyBtn).height,
        t.getSize(find.byKey(const ValueKey('reservation-cancel'))).height);
    // The card hugs its content: nothing is left empty under "Ver política".
    final sheetBottom = t.getBottomLeft(find.text('Ver política')).dy;
    expect(t.view.physicalSize.height / 3 - sheetBottom, lessThan(40));
    expect(find.byKey(const ValueKey('reservation-back')), findsOneWidget);
  });

  testWidgets('the reservation page names the driver once assigned',
      (t) async {
    final real = DateTime.now();
    final at = DateTime(real.year, real.month, real.day + 2, 15, 20);
    await pump(
      t,
      'en',
      RideBookingConfirmedScreen.reservation(
          Reservation.fromTrip(trip(at: at, driver: true))!),
    );
    expect(find.text('Jhon M.'), findsOneWidget);
    expect(find.text('Toyota Camry · ABC1234'), findsOneWidget);
    expect(find.text('Cancel reservation'), findsOneWidget);
    expect(find.text('View policy'), findsOneWidget);
    expect(find.text('Free to cancel until 2:20 PM'), findsOneWidget);
  });

  testWidgets('a reservation under way stays "Tu reserva" past its time',
      (t) async {
    final live = trip(at: now.subtract(const Duration(minutes: 5)), driver: true)
      ..['status'] = 'arrived';
    await pump(
      t,
      'es',
      ReservationCard(
        reservation: Reservation.fromTrip(live)!,
        style: ReservationCardStyle.home,
        now: now,
      ),
    );
    expect(find.text('TU RESERVA'), findsOneWidget);
    expect(find.text('PRÓXIMA RESERVA'), findsNothing);
    expect(Reservation.isLiveTrip(live), isTrue);
    expect(Reservation.isLiveTrip(trip(at: tomorrow, driver: true)), isFalse);
  });

  group('the trip goes on after its time, and the pushes open the right page',
      () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final hubSrc =
        File('lib/screens/schedule_hub_screen.dart').readAsStringSync();
    final mainSrc = File('lib/main.dart').readAsStringSync();

    test('Inicio and Programar keep a reservation under way', () {
      // The early driver is still waiting after 5:30 — it used to vanish.
      expect(home, contains('if (Reservation.isLiveTrip(t)) return true;'));
      expect(hubSrc, contains('if (Reservation.isLiveTrip(t)) return true;'));
    });

    test('"Conductor asignado" days ahead opens the reservation, not tracking',
        () {
      final fn = mainSrc.indexOf('void _navigateToScheduledTracking(');
      final reserved = mainSrc.indexOf('reservedStatuses.contains(status)', fn);
      final page =
          mainSrc.indexOf('RideBookingConfirmedScreen.reservation(r)', fn);
      final tracking = mainSrc.indexOf('RiderTrackingScreen(', fn);
      expect(reserved, greaterThan(fn));
      expect(page, greaterThan(reserved));
      expect(tracking, greaterThan(page));
    });

    test('the rider push "on the way" opens the started reservation', () {
      final fn = mainSrc.indexOf('void _handleDriverAssigned(');
      final rider = mainSrc.indexOf("if (mode == 'rider') {", fn);
      expect(rider, greaterThan(fn));
      expect(
          mainSrc.indexOf(
              '_navigateToScheduledTracking(tripId, reservationsOnly: true);',
              rider),
          greaterThan(rider));
    });
  });

  group('sources', () {
    final widgets =
        File('lib/screens/home_screen_widgets.dart').readAsStringSync();
    final hub = File('lib/screens/schedule_hub_screen.dart').readAsStringSync();

    test('Inicio: one card, no takeover of "¿A dónde?"', () {
      expect(widgets, isNot(contains('_buildHeroUpcomingRide')));
      expect(widgets, isNot(contains('_buildUpcomingProgressBar')));
      expect(widgets, isNot(contains("'Tienes un viaje reservado'")));
      expect(widgets, contains('style: ReservationCardStyle.home'));
    });

    test('Programar: the photo always stays, the cards under the button', () {
      // Owner 2026-11-08: "no quites la imagen de la página de scheduled".
      expect(hub, contains('ReservationCard('));
      expect(hub, isNot(contains('if (_rides.isEmpty) ...[')));
      expect(hub.indexOf("'assets/images/schedule_hero.jpg'"),
          lessThan(hub.indexOf('s.scheduleARide')));
      expect(hub.indexOf('s.scheduleARide'),
          lessThan(hub.indexOf('s.yourRidesTitle')));
      expect(hub, contains('RideBookingConfirmedScreen.reservation('));
      expect(hub, isNot(contains('showModalBottomSheet')),
          reason: 'the old detail sheet is the reservation page now');
    });
  });
}
