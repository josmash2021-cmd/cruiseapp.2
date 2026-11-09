import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/ride_booking_confirmed_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// Found 2026-11-08 walking the owner through an airport reservation:
//  • the "booked" page was hand-written Spanglish ("Ride Reservado",
//    "un driver asignado", "Pendiente de asignacion") and its date always
//    English ("Monday, Nov 9");
//  • to the airport, the rider's chosen pickup was swapped for the phone's
//    current location once the airport lookup came back.

Future<void> pumpBooked(WidgetTester t, String lang) async {
  // Wide: the test font draws every letter as a full block.
  t.view.physicalSize = const Size(900 * 3, 1400 * 3);
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
    home: RideBookingConfirmedScreen(
      scheduledAt: DateTime(2026, 11, 10, 5, 30),
      pickupAddress: '3659 Lorna Rd, Hoover, AL',
      dropoffAddress: 'BHM · Airport — Delta Air Lines',
      vehicleType: 'Comfort',
      fare: 38.40,
      isFree: false,
      routeMinutes: 24,
      carAsset: 'assets/images/cruisert3.png',
      paymentLabel: 'Visa •••• 4242',
      dropoffIsAirport: true,
    ),
  ));
  for (var i = 0; i < 30; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> leave(WidgetTester t) async {
  // Before its 3.5 s hop to home; then let that timer run out harmlessly.
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 4));
}

void main() {
  testWidgets('the booked page speaks Spanish…', (t) async {
    await pumpBooked(t, 'es');
    expect(find.text('Viaje reservado'), findsOneWidget);
    expect(find.text('Te avisaremos cuando un conductor acepte tu viaje'),
        findsOneWidget);
    expect(find.text('Esperando conductor'), findsOneWidget);
    // The time large, the arrival beside it (5:30 + 24 min).
    expect(find.text('MARTES 10 NOV'), findsOneWidget);
    expect(find.text('5:30 AM'), findsOneWidget);
    expect(find.text('Llegada aprox.'), findsOneWidget);
    expect(find.text('5:54 AM'), findsOneWidget);
    // Pickup → drop-off split into place + line; car, payment, price.
    expect(find.text('3659 Lorna Rd'), findsOneWidget);
    expect(find.text('Hoover, AL'), findsOneWidget);
    expect(find.text('BHM · Airport'), findsOneWidget);
    expect(find.text('Delta Air Lines'), findsOneWidget);
    expect(find.text('Visa •••• 4242'), findsOneWidget);
    expect(find.text('\$38.40'), findsOneWidget);
    expect(find.text('Listo'), findsOneWidget);
    expect(find.text('Ver mis reservas'), findsOneWidget);
    await leave(t);
  });

  testWidgets('…and English', (t) async {
    await pumpBooked(t, 'en');
    expect(find.text('Ride booked'), findsOneWidget);
    expect(find.text('Waiting for a driver'), findsOneWidget);
    expect(find.text('TUESDAY, NOV 10'), findsOneWidget);
    expect(find.text('Arrives approx.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    await leave(t);
  });

  testWidgets('it stays until the rider taps (no 3.5 s hop to home)',
      (t) async {
    await pumpBooked(t, 'es');
    await t.pump(const Duration(seconds: 6));
    expect(find.text('Viaje reservado'), findsOneWidget);
    await leave(t);
  });

  test('an address splits into place and line', () {
    expect(splitBookedAddress('3659 Lorna Rd, Hoover, AL, USA'),
        ('3659 Lorna Rd', 'Hoover, AL'));
    expect(
        splitBookedAddress(
            'BHM · Birmingham-Shuttlesworth International Airport — Delta Air Lines'),
        ('BHM · Birmingham-Shuttlesworth International Airport', 'Delta Air Lines'));
    expect(splitBookedAddress('Somewhere'), ('Somewhere', ''));
  });

  test('the booking passes the minutes, the car, the payment, the airport',
      () {
    final ctrl =
        File('lib/screens/ride_request_controller.dart').readAsStringSync();
    expect(ctrl, contains('carAsset: _carAssetForOption(option.name),'));
    expect(ctrl, contains('paymentLabel: _paymentLabel(_selectedPaymentMethod),'));
    expect(ctrl, contains('dropoffIsAirport: state.isAirportTrip || widget.isAirportTrip,'));
    final page =
        File('lib/screens/ride_booking_confirmed_screen.dart').readAsStringSync();
    expect(page, isNot(contains('milliseconds: 3500')));
    expect(page, isNot(contains('CircularPinIcon.home')));
  });

  test('no hand-written copy left on the booked page', () {
    final src =
        File('lib/screens/ride_booking_confirmed_screen.dart').readAsStringSync();
    for (final old in ['Ride Reservado', 'driver asignado', 'asignacion',
        "DateFormat('EEEE"]) {
      expect(src, isNot(contains(old)), reason: old);
    }
  });

  test('to the airport, the chosen pickup stays', () {
    final src =
        File('lib/screens/ride_request_controller.dart').readAsStringSync();
    final fn = src.indexOf('Future<void> _autoApplyAirportSelection(');
    final guard = src.indexOf(
        'if (_ctrl.state.pickup == null && _userLocation != null) {', fn);
    expect(guard, greaterThan(fn));
    expect(src, isNot(contains('      // Auto-set current location as pickup if available\n'
        '      if (_userLocation != null) {')));
  });
}
