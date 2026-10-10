import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the nav intro page (user mockup 2026-10-08): the first time
/// a driver opens navigation toward a PICKUP, an intro page goes first —
/// once ever (LocalCache flag), dropoff legs never. The whole thing is pure
/// Dart, so it rides OTA.
void main() {
  test('the gate shows the intro once, pickup leg only', () {
    final s = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync();
    expect(s, contains("LocalCache.get<bool>('driver_nav_intro_seen_v1')"));
    expect(s, contains("LocalCache.set('driver_nav_intro_seen_v1', true)"));
    // Only before pickup: the ride must not have started and the leg
    // override must not be dropoff.
    expect(s, contains('!_rideStarted && toPickup != false'));
    expect(s, contains('NavIntroScreen()'));
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
