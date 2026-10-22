import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the first-GO "You're now online!" instruction overlay
/// (2026-10-22 user spec): once per device, for newly approved AND veteran
/// drivers, floating over the online map — never a page — with a single
/// gold "Entendido" button as the only way out.
void main() {
  final overlay =
      File('lib/screens/driver/online_intro_overlay.dart').readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the transparent PNG is bundled and referenced', () {
    expect(File('assets/images/online_intro_hero.png').existsSync(), isTrue);
    expect(overlay, contains('assets/images/online_intro_hero.png'));
  });

  test('it is an overlay, never a route', () {
    expect(overlay.contains('Navigator.'), isFalse,
        reason: 'no push/pop inside — the map stays mounted underneath');
    expect(screen, contains('if (_showOnlineIntro)'));
    expect(screen, contains('Positioned.fill('));
    expect(screen, contains('OnlineIntroOverlay('));
  });

  test('fires only on an explicit fresh GO, once per device', () {
    // The trigger lives in the fresh-GO branch of _enterOnlineMode — the
    // resuming branch (shift resume) never shows it.
    final fn = controller.indexOf('Future<void> _enterOnlineMode');
    final region = controller.substring(fn, fn + 5500);
    expect(region, contains('_maybeShowOnlineIntro()'));
    final trigger = region.indexOf('_maybeShowOnlineIntro()');
    final elseBranch = region.lastIndexOf('} else {', trigger);
    expect(elseBranch, greaterThan(-1));
    expect(elseBranch, greaterThan(region.indexOf('if (resuming) {')),
        reason: 'the trigger must be in the fresh-GO else, not in resuming');
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
