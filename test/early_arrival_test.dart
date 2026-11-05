import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/widgets/early_arrival_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03 ("hazlo así como Lyft"): a driver who swipes "Llegué"
/// before a reservation's pickup time sees "Llegaste temprano"; the pickup
/// pin says "Reservado"; the rider's ring holds until their own time.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showEarlyArrivalSheet(
                ctx,
                riderFirstName: 'William',
                waitStartsAt: DateTime(2026, 11, 3, 15, 20),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle(); // the localizations load first
    await tester.tap(find.text('open'));
    // Not pumpAndSettle: the X's 10 s ring would run out (and close it).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Llegaste temprano: the rider was told, the wait starts at '
      'the pickup time', (tester) async {
    await open(tester);
    expect(find.text('Llegaste temprano'), findsOneWidget);
    expect(
        find.text('Le avisamos a William que llegaste, por si ya está listo. '
            'Tu espera empieza a contar a las 3:20 PM.'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('early-arrival-ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('early-arrival-card')), findsNothing);
  });

  testWidgets('it closes by itself when the X ring runs out', (tester) async {
    await open(tester);
    await tester.pump(kEarlyArrivalAutoClose - const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('early-arrival-card')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('early-arrival-card')), findsNothing);
  });

  testWidgets('closing it in the last instant never pops the screen under '
      'it', (tester) async {
    // A tap outside at 9.8 s starts the 320 ms close; the 10 s clock then
    // ran out mid-close and its bare pop() took the trip screen with it.
    await open(tester);
    await tester.pump(kEarlyArrivalAutoClose - const Duration(milliseconds: 600));
    await tester.tapAt(const Offset(20, 20)); // the barrier
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('early-arrival-card')), findsNothing);
    expect(find.text('open'), findsOneWidget,
        reason: 'the screen under the card is still there');
  });

  test('the trip screen shows it only before the reservation time, and the '
      'nav wait counts from that time', () {
    final trip = read('lib/screens/driver/driver_trip_accept_screen.dart');
    expect(trip, contains(
        'if (pickupAt != null && pickupAt.isAfter(DateTime.now()) && mounted) {'));
    expect(trip, contains('unawaited(showEarlyArrivalSheet('));
    expect(trip, contains(': (_earlyWaitStart ?? _waitStartedAt),'),
        reason: 'the bar and "Pasajero no llegó" wait for the pickup time');
    expect(trip, contains('at.difference(created).inMinutes < 3'),
        reason: 'a web booking "for now" is not a reservation');
    expect(trip, contains(': S.of(context).pickupBadgeReserved,'));
  });

  test('the pickup is the "Reservado" pill on the ring', () {
    final nav = read('lib/screens/driver/driver_nav_view.dart');
    expect(nav, contains('? await scheduledPickupMarker(badge, unit, pin)'));
    expect(nav, contains('if (oldWidget.pickupBadge != widget.pickupBadge) {'));
  });

  test("the rider's ring holds until the reservation time", () {
    final rider = read('lib/screens/rider_confirm_pickup_screen.dart');
    expect(rider, contains(
        'if (holdUntil != null && DateTime.now().isBefore(holdUntil)) return;'));
    expect(rider, contains("key: const ValueKey('rider-wait-starts-at'),"));
    expect(rider, contains('unawaited(_loadReservationTime());'));
  });
}
