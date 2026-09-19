import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the welcome screen (user spec 2026-09-17, updated
/// 2026-09-19):
///
///   1. Background is the CRUISE car clip (assets/videos/welcome_bg.mp4),
///      looping and muted, over the static SUV frame as instant fallback.
///   2. Lockup/headline/tagline are baked into the video — no in-app text
///      overlay may duplicate them.
///   3. Two buttons, one per role — Pasajero (person icon, gold) and
///      Conductor (hand-painted steering wheel, dark; Material has no
///      wheel glyph), icon LEFT of the label — and the "Want to drive?"
///      text link stays gone. Every role lands on its own welcome flow.
void main() {
  final src = File('lib/screens/welcome_screen.dart').readAsStringSync();

  group('video background (user spec 2026-09-19)', () {
    test('CRUISE car clip loops muted over the static fallback frame', () {
      expect(src.contains('assets/videos/welcome_bg.mp4'), isTrue);
      expect(src.contains('setLooping(true)'), isTrue,
          reason: 'the welcome clip loops forever behind the buttons');
      expect(src.contains('setVolume(0)'), isTrue,
          reason: 'background clips are always muted');
      expect(src.contains('welcome_bg_suv.png'), isTrue,
          reason: 'the static frame stays under the video as boot/fallback');
    });

    test('no in-app lockup/headline — the text is baked into the clip', () {
      expect(src.contains('welcomeHeadline'), isFalse,
          reason: 'doubling the baked headline reads as a glitch');
      expect(src.contains('welcomeSubheadline'), isFalse);
    });
  });

  group('two role buttons with icons, each to its own flow', () {
    test('Pasajero carries the person icon, Conductor the steering wheel', () {
      expect(src.contains('Icons.person_rounded'), isTrue,
          reason: 'Pasajero carries the person icon');
      expect(src.contains('_SteeringWheelIcon'), isTrue,
          reason: 'Conductor carries the hand-painted steering wheel');
      expect(src.contains('Icons.directions_car_rounded'), isFalse,
          reason: 'user spec 2026-09-19: volante, no carrito');
    });

    test('labels come from l10n (Pasajero/Conductor in ES)', () {
      expect(src.contains('label: S.of(context).rider'), isTrue);
      expect(src.contains('label: S.of(context).driver'), isTrue);
    });

    test('the icon rides LEFT of the label', () {
      final row = RegExp(
              r'children: \[\s*if \(widget\.leading != null\)\s*\.\.\.\[\s*widget\.leading!,\s*const SizedBox\(width: 10\),\s*\],\s*Text\(')
          .hasMatch(src);
      expect(row, isTrue,
          reason: 'user spec 2026-09-19: icono a la izquierda de la palabra');
    });

    test('each role lands on its own flow', () {
      expect(src.contains('RiderWelcomeScreen()'), isTrue,
          reason: 'the rider flow covers new AND existing accounts (phone '
              'login routes home when the account exists)');
      expect(src.contains('DriverWelcomeScreen()'), isTrue);
    });
  });

  test('the drive text link is gone', () {
    expect(src.contains('Want to drive?'), isFalse);
    expect(src.contains('Sign up to drive'), isFalse);
    expect(src.contains('TapGestureRecognizer'), isFalse,
        reason: 'the link spans left with it');
  });
}
