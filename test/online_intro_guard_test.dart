import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the first-GO "You're now online!" instruction overlay
/// (2026-10-22 user spec): once per device, for newly approved AND veteran
/// drivers, floating over the online map — never a page — with a single
/// gold "Entendido" button as the only way out.
void main() {
  final overlay =
      File('lib/screens/driver/online_intro_overlay.dart').readAsStringSync();
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the transparent PNG is bundled and referenced', () {
    expect(File('assets/images/online_intro_hero.png').existsSync(), isTrue);
    expect(overlay, contains('assets/images/online_intro_hero.png'));
    // A Shorebird patch can exclude the new asset — the card must render
    // anyway (2026-10-23: Patch 7 shipped the Dart but not the image).
    expect(overlay, contains('errorBuilder'));
  });

  test('it is an overlay, never a route', () {
    expect(overlay.contains('Navigator.'), isFalse,
        reason: 'no push/pop inside — the map stays mounted underneath');
    expect(screen, contains('if (_showOnlineIntro)'));
    expect(screen, contains('Positioned.fill('));
    expect(screen, contains('OnlineIntroOverlay('));
  });

  test('fires on the GO tap, once per device (always for the owner)', () {
    // The trigger is the GO TAP itself (owner spec 2026-10-22: "cuando
    // presionan activarse"). It lived in _enterOnlineMode's fresh-GO branch
    // first — but a phone remembering an open shift enters that with
    // resuming=true and the intro never showed (owner report 2026-10-23).
    final goTap = offline.indexOf('void _onGoTap()');
    expect(goTap, greaterThan(-1));
    final tapRegion = offline.substring(goTap, goTap + 7000);
    expect(tapRegion, contains('_maybeShowOnlineIntro()'));
    // …and the flip's own branches no longer carry it (no double-fire).
    final fn = controller.indexOf('Future<void> _enterOnlineMode');
    final region = controller.substring(fn, fn + 5500);
    expect(region.contains('_maybeShowOnlineIntro()'), isFalse,
        reason: 'the trigger lives in the GO tap, not the flip branches');
    expect(controller, contains("getBool('online_intro_seen_v1')"));
    expect(controller, contains("setBool('online_intro_seen_v1', true)"));
  });

  test('the seen flag is written only by the Entendido button', () {
    final dismiss = controller.indexOf('_dismissOnlineIntro');
    final triggerRegion =
        controller.substring(0, controller.indexOf('_maybeShowOnlineIntro'));
    expect(triggerRegion.contains("setBool('online_intro_seen_v1'"), isFalse,
        reason: 'marking seen before the button would let a kill skip it');
    expect(dismiss, greaterThan(-1));
    expect(overlay, contains('s.onlineIntroUnderstood'));
    expect(overlay.contains('Icons.close'), isFalse,
        reason: 'spec: only the Entendido button, no X');
  });

  test("the owner's demo account sees it on EVERY GO (spec 2026-10-22)", () {
    expect(overlay, contains('kOnlineIntroAlwaysEmails'));
    expect(overlay, contains('josmash33@gmail.com'));
    expect(controller, contains('kOnlineIntroAlwaysEmails.contains(email)'));
    // The seen flag is only consulted when the account is NOT in the
    // always-show set.
    expect(controller, contains('!alwaysShow'));
  });

  test('the driver count is an editable constant, used in the copy', () {
    expect(overlay, contains('const int kFirstDriverCount = 100;'));
    expect(overlay, contains('kFirstDriverCount'));
    expect(l10n, contains('onlineIntroSub(int n)'));
    expect(l10n, contains('onlineIntroB4Body(int n)'));
  });

  test('the four blocks and texts are localized ES/EN', () {
    for (final key in [
      'onlineIntroTitle',
      'onlineIntroB1Title',
      'onlineIntroB2Title',
      'onlineIntroB3Title',
      'onlineIntroB4Title',
      'onlineIntroUnderstood',
    ]) {
      expect(l10n, contains(key), reason: '$key missing');
    }
    expect(l10n, contains('¡Ya estás en línea!'));
    expect(l10n, contains("You're now online!"));
    expect(l10n, contains('Beneficios exclusivos'));
    expect(l10n, contains('Exclusive Benefits'));
  });
}
