import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/set_pickup_location_screen.dart';
import 'package:cruise_app/services/places_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// Owner 2026-11-08 on the booking page of a reservation: "no debería de salir
// programar porque ya se programó" — and the pickup page said "Pagar con …"
// though a reservation charges nothing there.

Future<S> loadS(String lang) => S.delegate.load(Locale(lang));

void main() {
  group('a reservation time, short', () {
    final now = DateTime(2026, 11, 9, 14, 2);
    test('today, tomorrow, later — in both languages', () async {
      final es = await loadS('es');
      final en = await loadS('en');
      expect(es.schedShortWhen(DateTime(2026, 11, 9, 20, 15), now),
          'Hoy 8:15 PM');
      expect(es.schedShortWhen(DateTime(2026, 11, 10, 5, 30), now),
          'Mañana 5:30 AM');
      expect(es.schedShortWhen(DateTime(2026, 11, 12, 5, 30), now),
          'jue 11/12 5:30 AM');
      expect(en.schedShortWhen(DateTime(2026, 11, 10, 5, 30), now),
          'Tomorrow 5:30 AM');
      expect(en.schedShortWhen(DateTime(2026, 11, 12, 12, 0), now),
          'Thu 11/12 12:00 PM');
    });
  });

  test('the booking pill shows the reservation time, not "Programar" again',
      () {
    final src = File('lib/screens/ride_request_widgets.dart').readAsStringSync();
    final i = src.indexOf('Widget _buildScheduleButton()');
    final body = src.substring(i, src.indexOf('Future<bool> _openScheduleFromSheet', i));
    expect(body, contains('final sched = _ctrl.state.scheduledAt ?? widget.scheduledAt;'));
    expect(body, contains('S.of(context).schedShortWhen(sched, DateTime.now())'));
  });

  test('the pickup page of a reservation reserves, it does not pay', () {
    final page =
        File('lib/screens/set_pickup_location_screen.dart').readAsStringSync();
    expect(page, contains('? s.bookScheduledRidePrice(widget.priceText)'));
    expect(page, contains(': s.payWith(widget.paymentLabel)'));
    expect(page, contains('s.reservationAt('));
    expect(page, contains(
        'bool get _applePayLook => widget.isApplePay && widget.scheduledAt == null;'));
    final ctrl =
        File('lib/screens/ride_request_controller.dart').readAsStringSync();
    expect(ctrl, contains('scheduledAt: state.scheduledAt ?? widget.scheduledAt,'));
  });

  testWidgets('pickup page, reservation: "Reservar ahora · \$34.02"',
      (t) async {
    t.view.physicalSize = const Size(900 * 3, 1600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      home: SetPickupLocationScreen(
        pickup: PlaceDetails(address: '3659 Lorna Rd', lat: 33.40, lng: -86.80),
        pickupLabel: '3659 Lorna Rd',
        dropoff: PlaceDetails(address: 'BHM', lat: 33.56, lng: -86.75),
        dropoffLabel: 'BHM',
        tierName: 'Standard',
        priceText: '\$34.02',
        paymentLabel: 'Visa •••• 4242',
        isApplePay: true,
        scheduledAt: DateTime.now().add(const Duration(days: 1)),
        onConfirm: (_, __) async => false,
      ),
    ));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Reservar ahora · \$34.02'), findsOneWidget);
    expect(find.textContaining('Pagar con'), findsNothing);
    expect(find.textContaining('Reserva: Mañana'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });
}
