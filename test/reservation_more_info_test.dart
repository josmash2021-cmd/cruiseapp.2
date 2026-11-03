import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/driver/reservation_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner-approved drawing 2026-11-03: the three "More info" rows open real
/// pages inside the same glass, and back returns to the reservation.
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final at = DateTime.now().add(const Duration(hours: 3));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      home: ReservationDetailPage(reservation: {
        // No id: the page does not ask the server for the rider.
        'scheduled_at': at.toUtc().toIso8601String(),
        'fare': 8.06,
        'pickup_address': '1200 Morris Ave',
        'dropoff_address': 'BHM',
      }),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openRow(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(row, 300,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('reservation-detail')),
            matching: find.byType(Scrollable)));
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// The arrow, or [system] back (Android button / iOS swipe): either one
  /// returns to the reservation where it was left — the [row] tapped is
  /// back on screen and tappable — and never closes the page.
  Future<void> goBack(WidgetTester tester, String row,
      {bool system = false}) async {
    if (system) {
      await tester.binding.handlePopRoute();
    } else {
      await tester.tap(find.byKey(const ValueKey('res-sub-back')));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(row)).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('res-sub-back')).hitTestable(),
        findsNothing);
  }

  testWidgets('CRUISE in capitals in the header', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('\$8.06 CRUISE', findRichText: true),
        findsOneWidget);
  });

  testWidgets('How to complete: four timed steps, then back', (tester) async {
    await pumpPage(tester);
    await openRow(tester, 'res-how-to');
    expect(find.text('El viaje empieza solo').hitTestable(), findsOneWidget);
    expect(find.text('La última hora es para esta reserva').hitTestable(),
        findsOneWidget);
    await goBack(tester, 'res-how-to');
  });

  testWidgets('Cancel policy: the four cases and the fee table',
      (tester) async {
    await pumpPage(tester);
    await openRow(tester, 'res-cancel-policy');
    expect(find.text('Si tú cancelas').hitTestable(), findsOneWidget);
    expect(find.text('Standard \$15'), findsOneWidget);
    final noShow = find.textContaining('"Pasajero no llegó"');
    await tester.scrollUntilVisible(noShow, 200,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('res-sub-policy')),
            matching: find.byType(Scrollable)));
    expect(noShow, findsOneWidget, reason: 'names the real no-show slider');
    await goBack(tester, 'res-cancel-policy', system: true);
  });

  testWidgets('FAQ: answers open and close', (tester) async {
    await pumpPage(tester);
    await openRow(tester, 'res-faq');
    const q2 = '¿Me llegan otros viajes antes de la reserva?';
    const a2Start = 'Sí, hasta 1 hora antes de la recogida.';
    expect(find.textContaining(a2Start), findsNothing);
    await tester.tap(find.text(q2));
    await tester.pumpAndSettle();
    expect(find.textContaining(a2Start), findsOneWidget);
    await tester.tap(find.text(q2));
    await tester.pumpAndSettle();
    expect(find.textContaining(a2Start), findsNothing);
    await goBack(tester, 'res-faq');
  });
}
