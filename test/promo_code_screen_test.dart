import 'dart:async';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/screens/promo_code_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> promotion(
  int id,
  String kind,
  String status, {
  int percent = 30,
  int fallback = 30,
  int remaining = 1,
}) {
  return {
    'id': id,
    'kind': kind,
    'percent': percent,
    'fallback_percent': fallback,
    'max_miles': kind == 'free' ? 5.0 : null,
    'allowed_tiers': ['standard', 'compact', 'electric_pro', 'premium'],
    'uses_per_rider': 2,
    'remaining_uses': remaining,
    'status': status,
    'starts_at': '2026-01-01T00:00:00Z',
    'expires_at': '2027-01-01T00:00:00Z',
    'reason': 'New rider courtesy',
  };
}

Widget app(PromoCodeScreen screen) => MaterialApp(
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: screen,
    );

void main() {
  testWidgets('server promotions render rules and refresh on socket',
      (tester) async {
    // Tall enough for the available AND the past promos (the list builds
    // lazily: a card past the viewport is not built at all).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final updates = StreamController<Map<String, dynamic>>();
    addTearDown(updates.close);
    var loads = 0;
    await tester.pumpWidget(app(
      PromoCodeScreen(
        promotionsLoader: () async {
          loads++;
          return {
            'promotions': [
              promotion(1, 'percent', 'active'),
              promotion(2, 'free', 'used', remaining: 0),
              promotion(3, 'percent', 'expired', percent: 15),
              promotion(4, 'percent', 'revoked', percent: 50),
            ],
          };
        },
        pricingUpdates: updates.stream,
      ),
    ));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('WELCOME10'), findsNothing);
    expect(find.text('CRUISE50'), findsNothing);
    // Lyft wording (owner 2026-11-09): "30% off", no "Active" — an active
    // promo says it is ready for the next ride; the rest sit under "Past".
    expect(find.text('30% off'), findsOneWidget);
    expect(find.textContaining('OFF'), findsNothing);
    expect(find.text('Active'), findsNothing);
    expect(find.text('Ready for your next ride'), findsOneWidget);
    expect(find.text('Applies automatically when you ride'), findsOneWidget);
    expect(find.text('Past promos', skipOffstage: false), findsOneWidget);
    expect(find.text('Free', skipOffstage: false), findsOneWidget);
    expect(find.text('Used', skipOffstage: false), findsOneWidget);
    expect(find.text('Expired', skipOffstage: false), findsOneWidget);
    expect(find.text('Revoked', skipOffstage: false), findsOneWidget);
    expect(find.text('1 of 2 uses left'), findsOneWidget);
    // A past promo shows no "uses left".
    expect(find.text('0 of 2 uses left', skipOffstage: false), findsNothing);
    expect(find.text('Up to 5 mi', skipOffstage: false), findsOneWidget);
    // Available first, then the past ones.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('promotion_1'))).dy,
      lessThan(tester
          .getTopLeft(find.byKey(const ValueKey('promotion_2'),
              skipOffstage: false))
          .dy),
    );
    expect(find.textContaining('ELECTRIC PRO'), findsWidgets);
    expect(find.textContaining('Valid:'), findsWidgets);
    expect(find.text('Your assigned promotions are applied automatically.'),
        findsOneWidget);

    updates.add(const {'version': 2});
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('server error stays actionable', (tester) async {
    await tester.pumpWidget(app(
      PromoCodeScreen(
        promotionsLoader: () async => throw Exception('offline'),
        pricingUpdates: const Stream.empty(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Could not load your promotions.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('server empty state has no fabricated promotions',
      (tester) async {
    await tester.pumpWidget(app(
      PromoCodeScreen(
        promotionsLoader: () async => {'promotions': const []},
        pricingUpdates: const Stream.empty(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No promos available'), findsOneWidget);
    expect(find.text('WELCOME10'), findsNothing);
    expect(find.text('CRUISE50'), findsNothing);
  });

  test('promotion copy is localized in Spanish', () {
    final s = S(const Locale('es'));
    expect(s.free, 'Gratis');
    expect(s.promotionUsesRemaining(1, 2), '1 de 2 usos restantes');
    expect(s.promotionMaxMiles('5'), 'Hasta 5 mi');
    expect(s.promotionRevoked, 'Revocada');
    expect(
      s.promotionsAutoApplied,
      'Tus promociones asignadas se aplican automáticamente.',
    );
  });

  testWidgets(r'a dollars-off promotion reads "$10 off · On your first ride"',
      (tester) async {
    final ten = promotion(9, 'amount', 'active', percent: 0, fallback: 0)
      ..['amount_cents'] = 1000
      ..['uses_per_rider'] = 1
      ..['reason'] = 'On your first ride';
    await tester.pumpWidget(app(
      PromoCodeScreen(
        promotionsLoader: () async => {
          'promotions': [ten],
        },
        pricingUpdates: const Stream.empty(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(r'$10 off'), findsOneWidget);
    expect(find.text('On your first ride'), findsOneWidget);
    expect(find.text('Ready for your next ride'), findsOneWidget);
    // One use, one ride: no "1 of 1 uses left".
    expect(find.text('1 of 1 uses left'), findsNothing);
    expect(find.textContaining('OFF'), findsNothing);
    expect(find.text('0% off'), findsNothing);
  });

  test('Lyft promo copy in Spanish', () {
    final s = S(const Locale('es'));
    expect(s.amountOffTitle('10'), r'$10 de descuento');
    expect(s.promoApplied, 'Promo aplicada');
    expect(s.promoReadyNextRide, 'Lista para tu próximo viaje');
    expect(s.usedPromosHeader, 'Usadas');
  });
}
