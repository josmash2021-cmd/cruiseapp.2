import 'package:cruise_app/widgets/smooth_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: "así como se abre se cierra smooth, y así para todo" —
/// what folds in must fold out the same way, not vanish and leave an empty
/// box to shrink.
void main() {
  Widget host(bool visible) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SmoothReveal(
                visible: visible,
                child: const SizedBox(
                    key: ValueKey('box'), width: 200, height: 100),
              ),
              const SizedBox(key: ValueKey('below'), height: 10),
            ],
          ),
        ),
      );

  double top(WidgetTester t) =>
      t.getTopLeft(find.byKey(const ValueKey('below'))).dy;

  testWidgets('it unfolds and folds over the same time, drawn all the way',
      (t) async {
    await t.pumpWidget(host(false));
    expect(find.byKey(const ValueKey('box')), findsNothing);
    expect(top(t), 0);

    await t.pumpWidget(host(true));
    await t.pump(kSmoothRevealDuration ~/ 2);
    final opening = top(t);
    expect(opening, inExclusiveRange(10.0, 90.0));
    await t.pump(kSmoothRevealDuration);
    expect(top(t), 100);

    await t.pumpWidget(host(false));
    await t.pump(kSmoothRevealDuration ~/ 2);
    expect(find.byKey(const ValueKey('box')), findsOneWidget,
        reason: 'still drawn while it folds — not gone at once');
    expect(top(t), closeTo(opening, 1),
        reason: 'half way out = half way in: the same curve both ways');
    await t.pump(kSmoothRevealDuration);
    expect(find.byKey(const ValueKey('box')), findsNothing);
    expect(top(t), 0);
  });

  test('the nav gold is one flat, solid gold', () {
    expect(kNavGold.a, 1.0);
  });
}
