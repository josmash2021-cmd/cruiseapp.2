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
    expect(find.text('Te avisaremos cuando un conductor\nacepte tu viaje'),
        findsOneWidget);
    expect(find.text('Esperando conductor'), findsOneWidget);
    expect(find.text('martes 10 nov · 5:30 AM'), findsOneWidget);
    await leave(t);
  });

  testWidgets('…and English', (t) async {
    await pumpBooked(t, 'en');
    expect(find.text('Ride booked'), findsOneWidget);
    expect(find.text('Waiting for a driver'), findsOneWidget);
    expect(find.text('Tuesday, Nov 10 · 5:30 AM'), findsOneWidget);
    await leave(t);
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
