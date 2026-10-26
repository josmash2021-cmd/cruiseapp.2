import 'package:cruise_app/models/ride_quote.dart';
import 'package:cruise_app/widgets/quoted_fare_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RideOption option({
  int original = 2000,
  int? promo,
  int discount = 0,
  bool free = false,
}) {
  final promoCents = promo ?? original;
  return RideOption(
    id: 'fusion',
    name: 'Comfort',
    description: '',
    priceEstimate: promoCents / 100,
    etaMinutes: 5,
    icon: '',
    originalTotalCents: original,
    promoTotalCents: promoCents,
    discountPercent: discount,
    discountAmountCents: original - promoCents,
    isFree: free,
  );
}

Future<void> pumpFare(
  WidgetTester tester,
  RideOption option, {
  int balance = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 320,
          child: QuotedFareView(
            option: option,
            cruiseCashCents: balance,
            freeLabel: 'Free',
            cruiseCashLabel: 'Cruise Cash',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('30% badge precedes the promo price and old price is struck below',
      (tester) async {
    await pumpFare(tester, option(promo: 1400, discount: 30));
    final badge = find.byKey(const ValueKey('quotedFareBadge'));
    final price = find.byKey(const ValueKey('quotedFarePrice'));
    final original = find.byKey(const ValueKey('quotedFareOriginal'));
    expect(find.text('30% OFF'), findsOneWidget);
    expect(find.text('\$14.00'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(tester.getCenter(badge).dx, lessThan(tester.getCenter(price).dx));
    expect(tester.getCenter(original).dy, greaterThan(tester.getCenter(price).dy));
    expect(tester.widget<Text>(original).style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('Free is gold beside the real struck fare, never a normal zero',
      (tester) async {
    await pumpFare(tester, option(promo: 0, free: true), balance: 5000);
    final free = find.byKey(const ValueKey('quotedFareFree'));
    final original = find.byKey(const ValueKey('quotedFareFreeOriginal'));
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(find.text('\$0.00'), findsNothing);
    expect(find.text('30% OFF'), findsNothing);
    expect(tester.getCenter(free).dx, lessThan(tester.getCenter(original).dx));
    expect(tester.widget<Text>(free).style?.color, QuotedFareView.gold);
    expect(tester.widget<Text>(original).style?.decoration, TextDecoration.lineThrough);
    expect(find.byKey(const ValueKey('quotedFareCash')), findsNothing);
  });

  testWidgets('normal and unknown fares have no promotional decoration',
      (tester) async {
    await pumpFare(tester, option());
    expect(find.text('\$20.00'), findsOneWidget);
    expect(find.byKey(const ValueKey('quotedFareBadge')), findsNothing);
    expect(find.byKey(const ValueKey('quotedFareOriginal')), findsNothing);
    expect(find.text('Free'), findsNothing);

    await pumpFare(
      tester,
      const RideOption(
        id: 'fusion',
        name: 'Comfort',
        description: '',
        priceEstimate: 0,
        etaMinutes: 0,
        icon: '',
      ),
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('\$0.00'), findsNothing);
  });

  testWidgets('Cruise Cash is separate and does not deform the 30% comparison',
      (tester) async {
    await pumpFare(tester, option(promo: 1400, discount: 30), balance: 1000);
    expect(find.text('\$14.00'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(find.text('−\$10.00 Cruise Cash'), findsOneWidget);
    expect(find.text('\$4.00'), findsNothing);
  });

  testWidgets('discount percentage comes from the quote', (tester) async {
    await pumpFare(tester, option(promo: 1500, discount: 25));
    expect(find.text('25% OFF'), findsOneWidget);
    expect(find.text('30% OFF'), findsNothing);
  });
}
