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
    expect(find.text('30% OFF'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Used'), findsOneWidget);
    expect(find.text('Expired', skipOffstage: false), findsOneWidget);
    expect(find.text('Revoked', skipOffstage: false), findsOneWidget);
    expect(find.text('1 of 2 uses left'), findsOneWidget);
    expect(find.text('0 of 2 uses left'), findsOneWidget);
    expect(find.text('Up to 5 mi'), findsOneWidget);
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
}
