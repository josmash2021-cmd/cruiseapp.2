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
  bool selected = false,
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
            selected: selected,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a 30% promo in a list row: promo price, old price struck below',
      (tester) async {
    // Owner 2026-11-09: the "off applied" tag rides on the PICKED price
    // only — in a row it cut "Sin conductores cerca · Reserva".
    await pumpFare(tester, option(promo: 1400, discount: 30));
    final price = find.byKey(const ValueKey('quotedFarePrice'));
    final original = find.byKey(const ValueKey('quotedFareOriginal'));
    expect(find.byKey(const ValueKey('quotedFareBadge')), findsNothing);
    expect(find.byKey(const ValueKey('quotedFareApplied')), findsNothing);
    expect(find.text('\$14.00'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(tester.getCenter(original).dy, greaterThan(tester.getCenter(price).dy));
    expect(tester.widget<Text>(original).style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('the picked card: the tag under the struck fare', (tester) async {
    await pumpFare(tester, option(promo: 1400, discount: 30), selected: true);
    final applied = find.byKey(const ValueKey('quotedFareApplied'));
    final original = find.byKey(const ValueKey('quotedFareOriginal'));
    expect(find.text('30% off applied'), findsOneWidget);
    // Green text, no yellow box (owner 2026-11-09).
    expect(tester.widget<Text>(applied).style?.color, QuotedFareView.green);
    expect(
        find.ancestor(
            of: applied,
            matching: find.byWidgetPredicate(
                (w) => w is Container && w.decoration != null)),
        findsNothing);
    // Under the struck fare: beside it the price column pushed the tier's
    // name off the card on a 360-wide Android (2026-11-09).
    expect(tester.getCenter(applied).dy, greaterThan(tester.getCenter(original).dy));
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
    expect(find.byKey(const ValueKey('quotedFareApplied')), findsNothing);
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

  testWidgets('the struck price is the full fare from the quote', (tester) async {
    await pumpFare(tester, option(promo: 1500, discount: 25));
    expect(find.text('\$15.00'), findsOneWidget);
    expect(find.text('\$20.00'), findsOneWidget);
    expect(optionHasPromo(option(promo: 1500, discount: 25)), isTrue);
    expect(optionHasPromo(option()), isFalse);
  });

  testWidgets(r'$10 off picked: the price, "$10 off applied" and the full fare struck below',
      (tester) async {
    // Owner 2026-11-07: the welcome promotion is $10 off the first ride. The
    // server sends no percent for it, only the dollars off. 2026-11-09: the
    // tag beside the struck fare says it, never a "0% off".
    final ten = option(original: 2268, promo: 1268);
    expect(ten.hasAmountDiscount, isTrue);
    expect(ten.hasPercentageDiscount, isFalse);
    expect(optionHasPromo(ten), isTrue);
    await pumpFare(tester, ten, selected: true);
    final price = find.byKey(const ValueKey('quotedFarePrice'));
    final original = find.byKey(const ValueKey('quotedFareOriginal'));
    expect(find.byKey(const ValueKey('quotedFareBadge')), findsNothing);
    expect(find.text(r'$10 off applied'), findsOneWidget);
    expect(find.textContaining('0% off'), findsNothing);
    expect(find.text(r'$12.68'), findsOneWidget);
    expect(find.text(r'$22.68'), findsOneWidget);
    expect(tester.getCenter(original).dy, greaterThan(tester.getCenter(price).dy));
    expect(tester.widget<Text>(original).style?.decoration, TextDecoration.lineThrough);
    expect(discountDollarsLabel(750), '7.50');
  });
}
