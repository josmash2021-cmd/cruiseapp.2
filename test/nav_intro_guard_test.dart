import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the nav intro page (user mockup 2026-10-08): the first time
/// a driver opens navigation toward a PICKUP, an intro page goes first —
/// once ever (LocalCache flag), dropoff legs never. The whole thing is pure
/// Dart, so it rides OTA.
void main() {
  test('the gate shows the intro on EVERY nav entry, both legs', () {
    final s = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync();
    // User specs 2026-10-10: "primero debe salir esa página siempre" +
    // "cuando se le da start trip para ir al pickup o dropoff" — the
    // once-ever flag AND the pickup-only condition both died: every call
    // to _enterNavMode pushes the intro first.
    expect(s, isNot(contains('driver_nav_intro_seen_v1')),
        reason: 'no once-ever flag anymore');
    final bodyStart = s.indexOf('Future<void> _enterNavMode({bool? toPickup})');
    final bodyEnd = s.indexOf('_navToPickupOverride = toPickup;', bodyStart);
    final body = s.substring(bodyStart, bodyEnd);
    expect(body.contains('!_rideStarted'), isFalse,
        reason: 'no pickup-phase gate');
    expect(body.contains('toPickup != false'), isFalse,
        reason: 'no leg gate — dropoff legs see it too');
    expect(body.contains('NavIntroScreen()'), isTrue);
    expect(body.indexOf('_navEntering = true'),
        lessThan(body.indexOf('NavIntroScreen()')),
        reason: 'the re-entry guard goes up BEFORE the push — no stacked '
            'intros from a double-tap');
  });

  test('the nav morph is a pure fade in / fade out', () {
    final s =
        File('lib/widgets/nav_morph_overlay.dart').readAsStringSync();
    // User spec 2026-10-10: "que aparezca con fade in y cuando se quite se
    // quita con fade out" — no bloom, no scale, no origin: the snapshot
    // cross-fades over the scrim, then onto the live map.
    expect(s, isNot(contains('Transform.scale(')),
        reason: 'no growing frame anymore');
    expect(s, isNot(contains('Rect.fromCenter(')),
        reason: 'no centre bloom anymore');
    expect(s, contains('Positioned.fill(child: framed)'));
    expect(s, contains('_reveal.value'),
        reason: 'the cross-fade onto the live map stays');
  });

  test('icons are glyphs that shipped in the store build font', () {
    final s = File('lib/screens/driver/nav_intro_screen.dart')
        .readAsStringSync();
    // OTA patches can only render glyphs already inside the release's
    // tree-shaken MaterialIcons font — icons first used by a patch render
    // as "?" boxes (user report 2026-10-10).
    expect(s, contains('Icons.notifications_outlined'));
    expect(s, contains('Icons.bar_chart_rounded'));
    expect(s, contains('Icons.route_rounded'));
    expect(s, isNot(contains('Icons.traffic_rounded')));
    expect(s, isNot(contains('Icons.notifications_active_outlined')));
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
