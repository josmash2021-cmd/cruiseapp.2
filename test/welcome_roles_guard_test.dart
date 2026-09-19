import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the welcome screen role split (user spec 2026-09-17):
/// two buttons, one per role — Rider (person icon, gold) and Driver (car
/// icon, dark) — and the "Want to drive? Sign up to drive or Sign in" text
/// link is gone. Every role must still land on its own welcome flow.
void main() {
  final src = File('lib/screens/welcome_screen.dart').readAsStringSync();

  test('two role buttons with icons, each to its own flow', () {
    expect(src.contains('icon: Icons.person_rounded'), isTrue,
        reason: 'Rider carries the person icon');
    expect(src.contains('icon: Icons.directions_car_rounded'), isTrue,
        reason: 'Driver carries the car icon');
    expect(src.contains('label: S.of(context).rider'), isTrue);
    expect(src.contains('label: S.of(context).driver'), isTrue);
    expect(src.contains('RiderWelcomeScreen()'), isTrue,
        reason: 'the rider flow covers new AND existing accounts (phone '
            'login routes home when the account exists)');
    expect(src.contains('DriverWelcomeScreen()'), isTrue);
  });

  test('the drive text link is gone', () {
    expect(src.contains('Want to drive?'), isFalse);
    expect(src.contains('Sign up to drive'), isFalse);
    expect(src.contains('TapGestureRecognizer'), isFalse,
        reason: 'the link spans left with it');
  });
}
