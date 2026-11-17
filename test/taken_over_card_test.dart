import 'package:cruise_app/widgets/taken_over_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared "Otro conductor lo tomó" run (instant offers + reservations,
/// 2026-11-16): it draws the notice on the card and nothing on it takes a tap.
void main() {
  testWidgets('draws the notice over the card and swallows taps', (tester) async {
    final ctrl = AnimationController(
        vsync: const TestVSync(), duration: const Duration(milliseconds: kTakenOverCardMs));
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: TakenOverCard(
            controller: ctrl,
            card: const SizedBox(width: 350, height: 220, child: ColoredBox(color: Colors.black, child: Text('Tarjeta'))),
            button: ElevatedButton(onPressed: () => tapped = true, child: const Text('Reservar')),
            title: 'Otro conductor lo tomó',
            body: 'Esta reserva ya fue asignada a otro conductor.',
          ),
        ),
      ),
    ));
    ctrl.value = 0.4; // frosted, the notice up
    await tester.pump();
    expect(find.text('Otro conductor lo tomó'), findsOneWidget);
    expect(find.text('Esta reserva ya fue asignada a otro conductor.'), findsOneWidget);
    await tester.tap(find.text('Reservar'), warnIfMissed: false);
    expect(tapped, isFalse, reason: 'a lost ride\'s button must not claim again');
    ctrl.value = 1.0; // gone
    await tester.pump();
    expect(tester.takeException(), isNull);
    ctrl.dispose();
  });
}
