import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the nav intro page (user mockup 2026-10-08): the first time
/// a driver opens navigation toward a PICKUP, an intro page goes first —
/// once ever (LocalCache flag), dropoff legs never. The whole thing is pure
/// Dart, so it rides OTA.
void main() {
  test('the gate shows the intro on EVERY pickup-leg entry (2026-10-10)', () {
    final s = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync();
    // User spec 2026-10-10: "primero debe salir esa página siempre" — the
    // once-per-device flag died; every nav entry toward a pickup shows it.
    expect(s, isNot(contains('driver_nav_intro_seen_v1')),
        reason: 'no once-ever flag anymore');
    expect(s, contains('!_rideStarted && toPickup != false'));
    expect(s, contains('NavIntroScreen()'));
    expect(s.indexOf('_navEntering = true'),
        lessThan(s.indexOf('NavIntroScreen()')),
        reason: 'the re-entry guard goes up BEFORE the push — no stacked '
            'intros from a double-tap');
  });

  test('the nav morph blooms from the screen CENTRE, not the low card', () {
    final s =
        File('lib/widgets/nav_morph_overlay.dart').readAsStringSync();
    // User spec 2026-10-10: "la navegación no debe salir desde abajo, sino
    // desde el centro" — the enter bloom lerps from a small rect at screen
    // centre to full screen instead of scaling in place out of the card.
    expect(s, contains('Rect.fromCenter('));
    expect(s, contains('center: screenRect.center'));
    expect(s, contains('Positioned.fromRect(rect: enterRect, child: framed)'));
  });

  test('the intro page is bilingual text + a way forward', () {
    final s = File('lib/screens/driver/nav_intro_screen.dart')
        .readAsStringSync();
    for (final key in [
      'navIntroTitle',
      'navIntroDirectionsTitle',
      'navIntroRideTitle',
      'navIntroInsightsTitle',
      'navIntroStart',
    ]) {
      expect(s, contains(key), reason: '$key must come from l10n, not hardcoded');
    }
    expect(s, contains('Navigator.of(context).pop()'),
        reason: 'Get started must just close and let the nav open behind');
  });

  test('the hero is the design art served from the backend', () {
    final s = File('lib/screens/driver/nav_intro_screen.dart')
        .readAsStringSync();
    // 2026-10-10: "esta página debe tener esta imagen de esta foto" —
    // over the wire because OTA patches never carry new assets; the
    // code-drawn card stays as the stand-in.
    expect(s, contains('/static/nav_intro_hero.png'));
    expect(s, contains('Image.network('));
    expect(s, contains('const _RouteIllustration()'),
        reason: 'the drawn card remains the loading/failure fallback');
  });

  test('the strings exist in ES and EN', () {
    final s = File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(s, contains("'Navega a donde quieras con Cruise'"));
    expect(s, contains("'Navigate anywhere with Cruise'"));
    expect(s, contains("'Get directions right in the app'"));
    expect(s, contains("'See live driver insights'"));
  });
}
