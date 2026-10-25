import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the first-GO "You're now online!" instruction overlay
/// (2026-10-22 user spec): once per device, for newly approved AND veteran
/// drivers, floating over the online map — never a page — with a single
/// gold "Entendido" button as the only way out.
void main() {
  final overlay =
      File('lib/screens/driver/online_intro_overlay.dart').readAsStringSync();
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync();
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

  test('the gold card is compact, rounded and keeps the hero outside', () {
    for (final needle in [
      'maxWidth: 360',
      'height: 150',
      'color: const Color(0xFFE8C547)',
      'borderRadius: BorderRadius.circular(30)',
      'clipBehavior: Clip.none',
      'color: const Color(0xFFFFFDF6)',
      'backgroundColor: _navy',
      'foregroundColor: _gold',
    ]) {
      expect(overlay, contains(needle));
    }
    expect(overlay, isNot(contains('maxWidth: 420')));
    expect(overlay, isNot(contains('color: _navy,')),
        reason: 'the old navy card around all the content is gone; navy is '
            'only the contrasting button');
  });

  test('it is an overlay, never a route', () {
    expect(overlay.contains('Navigator.'), isFalse,
        reason: 'no push/pop inside — the map stays mounted underneath');
    expect(screen, contains('if (_showOnlineIntro)'));
    expect(screen, contains('Positioned.fill('));
    expect(screen, contains('OnlineIntroOverlay('));
    final build = screen.indexOf('Widget build(BuildContext context) {');
    final navHeader = screen.indexOf('Widget _navHeader()');
    final intro = screen.indexOf('if (_showOnlineIntro)', build);
    expect(build, greaterThan(-1));
    expect(navHeader, greaterThan(build));
    expect(intro, greaterThan(build));
    expect(intro, lessThan(navHeader),
        reason: 'the overlay belongs to the ROOT build/Stack, not _navHeader: '
            'inside _navHeader it never exists in the normal online state');
    expect(
        screen.substring(navHeader).contains('OnlineIntroOverlay('), isFalse);
  });

  test(
      'fires ~10 s after the shift is live, once per device (always for '
      'the owner)', () {
    // The trigger moved OFF the GO tap (owner spec 2026-10-23: "debe salir
    // después de unos 10 segundos de estar activado, no cuando se le da al
    // botón GO") — a Timer armed at the END of _enterOnlineMode, which also
    // cures the 700 ms race that checked _driverOnline before the flip
    // landed and let the overlay die silently.
    final goTap = offline.indexOf('void _onGoTap()');
    expect(goTap, greaterThan(-1));
    final tapRegion = offline.substring(goTap, goTap + 7000);
    expect(tapRegion.contains('_maybeShowOnlineIntro()'), isFalse,
        reason: 'the tap no longer triggers it — the 10 s timer does');
    final fn = controller.indexOf('Future<void> _enterOnlineMode');
    final region = controller.substring(fn, fn + 5500);
    expect(region, contains('Timer.periodic(const Duration(seconds: 1)'),
        reason: 'retries after ten seconds online instead of depending on '
            'one callback that can be lost with the screen lifecycle');
    expect(region, contains('timer.tick < 10'));
    expect(region, contains('_introEpoch++'));
    final trigger = controller.indexOf('Future<void> _maybeShowOnlineIntro()');
    final triggerRegion = controller.substring(trigger, trigger + 4500);
    final cachedIdentity = triggerRegion.indexOf('UserSession.getUser()');
    final liveLookup = triggerRegion.indexOf('ApiService.getMe()');
    final firstPresentation = triggerRegion.indexOf('_presentOnlineIntro();');
    expect(cachedIdentity, greaterThan(-1));
    expect(liveLookup, greaterThan(cachedIdentity));
    expect(firstPresentation, greaterThan(cachedIdentity));
    expect(firstPresentation, lessThan(liveLookup),
        reason: 'a first view or a locally recognized demo account presents '
            'before any network request — a slow getMe cannot suppress it');
    expect(triggerRegion, contains('if (alwaysShow || !seen)'));
    expect(triggerRegion, contains('me = await ApiService.getMe()'),
        reason: 'the live profile remains a fallback when seen=true and the '
            'cached identity did not match the demo account');
    expect(triggerRegion, contains('epoch != _introEpoch'));
    expect(triggerRegion, contains('_introRetryAfter'));
    expect(controller, contains('_introTimer?.cancel();'),
        reason: 'cancelled on exit/dispose — never fires over the '
            'offline map');
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
    expect(overlay, contains('kOnlineIntroAlwaysEmails.contains(email)'));
    expect(controller, contains('onlineIntroAlwaysAccount(cached: u)'));
    expect(
        controller, contains('onlineIntroAlwaysAccount(live: me, cached: u)'));
    expect(controller, contains('if (alwaysShow || !seen)'),
        reason: 'seen suppresses only accounts that are not always-show');
  });

  test('the always-show rule also matches the phone number (2026-10-23)', () {
    // Owner spec, literal: "debe ser para este telefono 3854612042". A
    // phone-created account can have an EMPTY cached email — the email-only
    // rule never matched and the seen flag then hid the intro forever.
    expect(overlay, contains('kOnlineIntroAlwaysPhones'));
    expect(overlay, contains('3854612042'));
    expect(overlay, contains("replaceAll(RegExp(r'\\D'), '')"),
        reason: 'the phone is normalized to digits before matching');
    expect(
        overlay,
        contains(
            'kOnlineIntroAlwaysPhones.any((p) => phoneDigits.endsWith(p))'),
        reason: 'email OR phone number grants always-show — and endsWith() '
            'accepts the +1 country-code prefix that the plain equality '
            'missed (3854612042 vs +13854612042)');
    expect(overlay, contains('kOnlineIntroAlwaysEmails.contains(email) ||'),
        reason: 'the two identifiers are OR-ed, not AND-ed');
    expect(controller, contains('[OnlineIntro] alwaysShow='),
        reason: 'a decision log exists for on-device verification');
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
