import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the periodic "You're now online!" instruction overlay:
/// every 6 hours per device for every driver, with no account exceptions.
/// It floats over the online map with one black, gold-lettered button.
void main() {
  final overlay =
      File('lib/screens/driver/online_intro_overlay.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync().replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync().replaceAll('\r\n', '\n');

  test('the transparent PNG is bundled and has a real remote fallback', () {
    final image = File('lib/widgets/onboarding_image.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(File('assets/images/online_intro_hero.png').existsSync(), isTrue);
    expect(overlay, contains('assets/images/online_intro_hero.png'));
    expect(overlay, contains('OnboardingImage('));
    expect(overlay, contains("filename: 'online_intro_hero.png'"));
    expect(File('backend/static/onboarding/online_intro_hero.png').existsSync(),
        isTrue);
    expect(image, contains('errorBuilder'));
    expect(image, contains('Image.network('));
    expect(image, isNot(contains('const SizedBox(height: 12)')));
  });

  test('the gold card has a cloud silhouette and an external black button', () {
    for (final needle in [
      'maxWidth: 360',
      'height: 150',
      'color: const Color(0xFFE8C547)',
      '_CloudClipper',
      '_CloudBorderPainter',
      '_cloudPath',
      'clipBehavior: Clip.none',
      'color: const Color(0xFFFFFDF6)',
      'color: Colors.black',
      'backgroundColor: Colors.black',
      'foregroundColor: _gold',
      'side: BorderSide(color: _gold, width: 1.2)',
      'const SizedBox(height: 10)',
    ]) {
      expect(overlay, contains(needle));
    }
    expect(overlay, isNot(contains('maxWidth: 420')));
    expect(overlay, isNot(contains('backgroundColor: _gold')),
        reason: 'the external button is black with gold text');
    expect(overlay, isNot(contains('shape: BoxShape.circle')),
        reason: 'icons are plain glyphs, never enclosed in a circle');
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

  test('fires after ten seconds and stays armed for the next 6 hours', () {
    final goTap = offline.indexOf('void _onGoTap()');
    expect(goTap, greaterThan(-1));
    final tapRegion = offline.substring(goTap, goTap + 7000);
    expect(tapRegion.contains('_maybeShowOnlineIntro()'), isFalse,
        reason: 'the tap no longer triggers it — the 10 s timer does');
    final fn = controller.indexOf('Future<void> _enterOnlineMode');
    final end = controller.indexOf('Future<void> _exitOnlineMode', fn);
    expect(end, greaterThan(fn));
    final region = controller.substring(fn, end);
    expect(region, contains('Timer.periodic(const Duration(seconds: 1)'));
    expect(region, contains('timer.tick < 10'));
    expect(region, contains('_introEpoch++'));
    final trigger = controller.indexOf('Future<void> _maybeShowOnlineIntro()');
    final triggerRegion = controller.substring(trigger, trigger + 3000);
    expect(triggerRegion, contains('onlineIntroDueNow(lastSeenMs, nowMs)'));
    expect(triggerRegion, isNot(contains('showEveryGo')));
    expect(triggerRegion, isNot(contains('UserSession.getUser()')),
        reason: 'recurrence needs no account lookup or network profile');
    expect(triggerRegion, contains("getInt('online_intro_last_seen_at')"));
    expect(triggerRegion, isNot(contains('ApiService.getMe()')),
        reason: 'recurrence does not wait for a network profile');
    expect(triggerRegion, isNot(contains('onlineIntroAlwaysAccount')));
    expect(triggerRegion, contains('epoch != _introEpoch'));
    expect(triggerRegion, contains('_introRetryAfter'));
    expect(controller, contains('onlineIntroRepeatInterval'));
    final present = controller.indexOf('void _presentOnlineIntro()');
    final presentRegion = controller.substring(present, present + 260);
    expect(presentRegion, isNot(contains('_introTimer?.cancel()')),
        reason: 'the timer survives presentation for the next 6 h');
    expect(controller, contains('_introTimer?.cancel();'),
        reason: 'exit and dispose still cancel the timer');
    expect(controller, contains("getInt('online_intro_last_seen_at')"));
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

  test('all drivers use a 6-hour timestamp and a black backdrop', () {
    expect(overlay, contains('onlineIntroRepeatInterval = Duration(hours: 6)'));
    expect(overlay, contains('bool onlineIntroDueNow'));
    expect(overlay, isNot(contains('onlineIntroShowsEveryGo')));
    expect(overlay, isNot(contains('onlineIntroEveryGoPhone')));
    expect(controller, isNot(contains('showEveryGo')));
    expect(controller, isNot(contains('onlineIntroAlwaysAccount')));
    expect(controller, contains("getInt('online_intro_last_seen_at')"));
    expect(controller, contains('onlineIntroDueNow(lastSeenMs, nowMs)'));
    expect(
        controller,
        contains(
            '_introRetryAfter = clock.now().add(onlineIntroRepeatInterval)'));
    expect(
        overlay, contains('color: Colors.black,\n          child: SafeArea('));
    expect(overlay, isNot(contains('alpha: 0.18')));
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
