import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/schedule_datetime_screen.dart';
import 'package:cruise_app/services/places_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// Owner 2026-11-08: "no puede aparecer horas viejas y debe ser con 40 min de
// anticipación cualquier reserva… cada vez que entren a esa página ya esté
// ajustando cuál es el mínimo… si colocan la salida la llegada aparecerá
// exacto y si le dan llegada le aparecerá a qué hora lo buscarán".

final pickup = PlaceDetails(address: '3659 Lorna Rd', lat: 33.40, lng: -86.80);
final dropoff = PlaceDetails(address: 'Walmart', lat: 33.45, lng: -86.82);

String otherEnd(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('sched-other-end'))).data!;
String earliestLine(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('sched-earliest'))).data!;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Opens the page from a host route so Next's pop lands somewhere.
Future<List<Object?>> open(WidgetTester t, ScheduleDateTimeScreen page) async {
  final popped = <Object?>[];
  // Wide: the test font draws every letter as a full block.
  t.view.physicalSize = const Size(900 * 3, 1400 * 3);
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
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () async {
          popped.add(await Navigator.of(ctx)
              .push<Object?>(MaterialPageRoute<Object?>(builder: (_) => page)));
        },
        child: const Text('open'),
      ),
    ),
  ));
  await settle(t); // the localizations load a frame late
  await t.tap(find.text('open'));
  await settle(t);
  return popped;
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

void main() {
  tearDown(() => scheduleClock = DateTime.now);

  group('the earliest bookable time', () {
    test('onto the wheels\' 5 minutes, never earlier', () {
      expect(ceilToFiveMinutes(DateTime(2026, 11, 9, 15, 27)),
          DateTime(2026, 11, 9, 15, 30));
      expect(ceilToFiveMinutes(DateTime(2026, 11, 9, 15, 25)),
          DateTime(2026, 11, 9, 15, 25));
      expect(ceilToFiveMinutes(DateTime(2026, 11, 9, 15, 25, 1)),
          DateTime(2026, 11, 9, 15, 30));
      expect(ceilToFiveMinutes(DateTime(2026, 11, 9, 23, 58)),
          DateTime(2026, 11, 10, 0, 0));
    });

    test('40 minutes ahead (was 30)', () {
      expect(kScheduleMinLeadMinutes, 40);
      expect(earliestSchedulePickup(DateTime(2026, 11, 9, 14, 2)),
          DateTime(2026, 11, 9, 14, 45));
      expect(earliestSchedulePickup(DateTime(2026, 11, 9, 14, 5)),
          DateTime(2026, 11, 9, 14, 45));
      expect(earliestSchedulePickup(DateTime(2026, 11, 9, 23, 40)),
          DateTime(2026, 11, 10, 0, 20));
    });
  });

  testWidgets('opens on the earliest time; Salida shows the exact arrival',
      (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    expect(earliestLine(t), contains('2:45 PM'));
    expect(otherEnd(t), 'Llegada: 2:59 PM');
    await close(t);
  });

  testWidgets('a past seed (the rider\'s old time) opens on the earliest',
      (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    await open(
        t,
        ScheduleDateTimeScreen(
          initialDateTime: DateTime(2026, 11, 9, 9, 0),
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    expect(otherEnd(t), 'Llegada: 2:59 PM');
    await close(t);
  });

  testWidgets('passed times are not on the wheels at all', (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    Finder inWheel(String wheel, String text) => find.descendant(
        of: find.byKey(ValueKey('wheel-$wheel')), matching: find.text(text));
    // Today from 2:45 PM: no AM, no 12 or 1, no :40 at 2 o'clock.
    expect(inWheel('ampm', 'AM'), findsNothing);
    expect(inWheel('hour', '12'), findsNothing);
    expect(inWheel('hour', '1'), findsNothing);
    expect(inWheel('hour', '2'), findsOneWidget);
    expect(inWheel('minute', '40'), findsNothing);
    expect(inWheel('minute', '45'), findsOneWidget);

    // Tomorrow every hour is there again.
    await t.drag(find.byKey(const ValueKey('wheel-day')), const Offset(0, -40));
    await settle(t);
    expect(inWheel('day', 'Mañana'), findsOneWidget);
    expect(inWheel('ampm', 'AM'), findsOneWidget);
    expect(inWheel('hour', '12'), findsOneWidget);
    expect(inWheel('minute', '40'), findsOneWidget);
    await close(t);
  });

  testWidgets('after 11:20 PM "Hoy" is gone: the earliest is tomorrow',
      (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 23, 40);
    await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('wheel-day')),
            matching: find.text('Hoy')),
        findsNothing);
    expect(earliestLine(t), contains('12:20 AM'));
    await close(t);
  });

  testWidgets('turning to an old hour rolls back to the earliest', (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    // A later hour is fine and stays: 2 → 4 PM (the drag really turns it).
    await t.drag(find.byType(CupertinoPicker).at(1), const Offset(0, -80));
    await settle(t);
    expect(otherEnd(t), 'Llegada: 4:59 PM');
    // Back past now: 4 → 12 (noon) is gone — it rolls to the earliest.
    await t.drag(find.byType(CupertinoPicker).at(1), const Offset(0, 160));
    await settle(t);
    expect(otherEnd(t), 'Llegada: 2:59 PM');
    await close(t);
  });

  testWidgets('Llegada shows when they are picked up; Next books that pickup',
      (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    final popped = await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    await t.tap(find.text('Llegada'));
    await settle(t);
    // Pickup 2:45 + 14 min = 2:59 → arrive 3:00 on the wheels, so the pickup
    // is 2:46: never earlier than the earliest.
    expect(otherEnd(t), 'Recogida: 2:46 PM');
    expect(earliestLine(t), contains('3:00 PM'));

    await t.tap(find.text('Siguiente'));
    await settle(t);
    final (at, _) = popped.single as (DateTime, Map<String, dynamic>);
    expect(at, DateTime(2026, 11, 9, 14, 46));
    await close(t);
  });

  testWidgets('without addresses Llegada says why and stays on Salida',
      (t) async {
    scheduleClock = () => DateTime(2026, 11, 9, 14, 2);
    await open(t, const ScheduleDateTimeScreen());
    await t.tap(find.text('Llegada'));
    await t.pump(const Duration(milliseconds: 300));
    expect(
        find.text('Para elegir la hora de llegada, primero elige las '
            'direcciones'),
        findsOneWidget);
    expect(earliestLine(t), contains('2:45 PM'));
    await t.pump(const Duration(seconds: 5));
    await close(t);
  });

  testWidgets('time passing on an open page moves the wheels forward',
      (t) async {
    var now = DateTime(2026, 11, 9, 14, 2);
    scheduleClock = () => now;
    await open(
        t,
        ScheduleDateTimeScreen(
          estimatedMinutes: 14,
          prefilledPickup: pickup,
          prefilledDropoff: dropoff,
        ));
    expect(otherEnd(t), 'Llegada: 2:59 PM');
    now = DateTime(2026, 11, 9, 14, 21); // earliest is now 3:05 PM
    await t.pump(const Duration(seconds: 21));
    await settle(t);
    expect(earliestLine(t), contains('3:05 PM'));
    expect(otherEnd(t), 'Llegada: 3:19 PM');
    expect(find.textContaining('Ya pasó esa hora'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await close(t);
  });
}
