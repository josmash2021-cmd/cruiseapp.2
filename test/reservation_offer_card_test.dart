import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/screens/driver/reservation_offer_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-04: the reservation on the reservations map is the trip
/// offer card "tal cual", Verificado in gold, and Reservar exactly as wide
/// as the card.
void main() {
  final trip = <String, dynamic>{
    'id': 7,
    'fare': 19.67,
    'pickup_address': '3452 30th Way N, Birmingham, AL 35207',
    'dropoff_address': '2680 Hackberry Ln, Vestavia Hills, AL 35226',
    'pickup_lat': 33.5401,
    'pickup_lng': -86.7811,
    'dropoff_lat': 33.4180,
    'dropoff_lng': -86.7900,
    'duration_minutes': 16,
    'distance_miles': 10.0,
    'rider_name': 'Apple Carter',
    'rider_rating': 5.0,
    'rider_verified': true,
  };

  Widget host(Widget child) => MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: const [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es'), Locale('en')],
        home: Scaffold(
          backgroundColor: const Color(0xFF0A1128),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  child,
                  const SizedBox(height: 8),
                  ReserveOfferButton(label: 'Reservar', onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('the offer card: badge, time, fare, rail, rider with gold ✓',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(ReservationOfferCard(
      trip: trip,
      whenLabel: 'Mañana · 7:00 PM',
      driverPos: const LatLng(33.5200, -86.8000),
    )));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('RESERVADO'), findsOneWidget);
    expect(find.text('Mañana · 7:00 PM'), findsOneWidget);
    expect(find.text('\$19.67'), findsOneWidget);
    expect(find.text('Apple C.'), findsOneWidget);
    // Owner 2026-11-04 (final): RESERVADO on the price's right, the day and
    // time in gold, the hourly rate, and no rider photo.
    final price = t.getCenter(find.text('\$19.67'));
    final badge = t.getCenter(find.text('RESERVADO'));
    expect(badge.dx, greaterThan(price.dx + 100));
    expect((badge.dy - price.dy).abs(), lessThan(30));
    expect(t.widget<Text>(find.text('Mañana · 7:00 PM')).style?.color,
        const Color(0xFFE8C547));
    expect(find.textContaining('/h estimado por este viaje'), findsOneWidget);
    expect(find.text('A'), findsNothing, reason: 'no avatar initial');
    // Verificado and the rating on the name's right, one row.
    final name = t.getCenter(find.text('Apple C.'));
    final ver = t.getCenter(find.text('Verificado'));
    expect(ver.dx, greaterThan(name.dx));
    expect((ver.dy - name.dy).abs(), lessThan(4));
    final verified = t.widget<Text>(find.text('Verificado'));
    expect(verified.style?.color, const Color(0xFFE8C547));
    final icon = t.widget<Icon>(find.byIcon(Icons.verified_rounded));
    expect(icon.color, const Color(0xFFE8C547));
    // Reservar as wide as the card.
    final card = t.getSize(find.byType(ReservationOfferCard));
    final button = t.getSize(find.byKey(const ValueKey('reserve-offer-button')));
    expect(button.width, card.width);
    expect(button.height, 54);
    expect(t.takeException(), isNull);
  });

  test('the map floats it with the offer inset, Reservar asking first', () {
    final map = File('lib/screens/driver/scheduled_rides_map_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final i = map.indexOf('// ── The selected ride, floating above Reservar ──');
    expect(map.substring(i, i + 220), contains('left: 20,'));
    expect(map.substring(i, i + 220), contains('right: 20,'));
    expect(map, isNot(contains('Color(0xFF60A5FA)')),
        reason: 'Verificado is gold everywhere on this screen');
    // The open ride's route fills the strip above the card (owner
    // 2026-11-04, "se ve super lejos"): room for the callout only when the
    // pickup lands near the top.
    final f = map.indexOf('Future<void> _fitRouteOnce(');
    final fit = map.substring(f, f + 2600);
    expect(fit, contains('FlatMapProjection.fitFlat('));
    expect(fit, contains('const side = 32.0;'));
    expect(fit, contains('if (over <= 0) break;'));
    expect(fit, isNot(contains('padding.top + 140')));
  });
}
