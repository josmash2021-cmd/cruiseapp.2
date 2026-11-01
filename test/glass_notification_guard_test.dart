import 'dart:io';

import 'package:cruise_app/widgets/glass_notification_banner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardian for the owner spec of 2026-11-01: "todas las notificaciones
/// dentro de la app deben llegar en este estilo — vidrio, borroso — arriba;
/// duran ~7 s, salen deslizando hacia arriba con fade, y se quitan
/// deslizando hacia arriba". One banner (lib/widgets/
/// glass_notification_banner.dart) — foreground pushes, the old toast
/// helpers and the event SnackBars all go through it.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// The `{…}` body that follows [signature] (brace-matched; skips the
  /// parameter list, named `{…}` parameters included).
  String body(String src, String signature) {
    final at = src.indexOf(signature);
    expect(at, isNonNegative, reason: 'missing: $signature');
    final head = RegExp(r'\)\s*(async\s*)?\{').firstMatch(src.substring(at))!;
    final open = at + head.end - 1;
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
    }
    fail('unbalanced body after $signature');
  }

  final banner = read('lib/widgets/glass_notification_banner.dart');
  final mainDart = read('lib/main.dart');

  test('7 s, slide-up exit, swipe-up dismiss — pinned constants', () {
    expect(banner, contains('const kGlassBannerDuration = Duration(seconds: 7);'));
    expect(banner, contains('const kGlassBannerSwipeDistance = 36.0;'));
    expect(banner, contains('const kGlassBannerSwipeVelocity = 500.0;'));
    expect(banner, contains('const kGlassBannerRadius = 20.0;'));
    expect(banner, contains('const kGlassBannerSideMargin = 16.0;'));
    // Shown on the ROOT overlay so it works on every screen.
    expect(banner, contains('navigatorKey?.currentState?.overlay'));
    expect(banner, contains('Overlay.maybeOf(context, rootOverlay: true)'));
    expect(mainDart,
        contains('GlassNotificationBanner.navigatorKey = _navigatorKey;'));
  });

  test('the frost is inset so iOS cannot blur a square past the corners', () {
    // ceil(20 · (1 − 1/√2)) = 6 — see the comment on the constant.
    expect(banner, contains('const kGlassBannerBlurInset = 6.0;'));
    expect(banner, contains('padding: EdgeInsets.all(kGlassBannerBlurInset)'));
    expect(banner, contains('GlassSurface('),
        reason: 'reuses the shared glass, no second blur recipe');
    expect(banner, contains('tint: Colors.transparent'),
        reason: 'the tint is painted over the WHOLE card after the frost');
  });

  // Owner 2026-11-01: "¿por qué está gris y no transparente blurry?" — the
  // banner wore the open sheet's 82 % tint and read as a flat grey box.
  test('see-through glass: light tint, denser only on the unblurred rim', () {
    expect(kGlassBannerTint.a, lessThanOrEqualTo(0.45),
        reason: 'the frosted map must show through');
    expect(kGlassBannerRimTint.a, greaterThan(kGlassBannerTint.a));
    expect(banner, contains('color: kGlassBannerRimTint,'));
    expect(banner, contains('width: kGlassBannerBlurInset),'),
        reason: 'extra smoke exactly where iOS does not blur');
  });

  test('foreground pushes use the banner, never a system/local copy', () {
    final start = mainDart.indexOf('FirebaseMessaging.onMessage.listen(');
    final end = mainDart.indexOf('FirebaseMessaging.onMessageOpenedApp.listen(');
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final handler = mainDart.substring(start, end);
    expect('_showPushBanner('.allMatches(handler).length, greaterThanOrEqualTo(4),
        reason: 'dispatch inbox, chat, scheduled_ride, general types');
    expect(handler, isNot(contains('NotificationService.show(')),
        reason: 'no OS heads-up drawn while the app is open');
    expect(handler, isNot(contains('showSnackBar')));
    // Offers stay off: the offer card owns the screen.
    expect(handler, contains('if (!isOffer && hasText) {'));
    final push = body(mainDart, 'void _showPushBanner(');
    expect(push, contains('GlassNotificationBanner.show('));
    expect(push, contains('glassBannerIconForType(type)'));
  });

  test('iOS: FCM in foreground keeps sound + badge, no system banner', () {
    final swift = read('ios/Runner/AppDelegate.swift');
    final gcm = swift.indexOf('userInfo["gcm.message_id"] != nil');
    expect(gcm, isNonNegative);
    expect(swift.indexOf('completionHandler([.sound, .badge])', gcm),
        greaterThan(gcm));
    expect(gcm, lessThan(swift.indexOf('completionHandler([.banner, .sound, .badge])')),
        reason: 'the FCM branch returns before the local-notification banner');
  });

  test('old toast helpers delegate to the one banner', () {
    final toast = read('lib/utils/app_toast.dart');
    expect(toast, contains('GlassNotificationBanner.show('));
    expect(toast, isNot(contains('OverlayEntry')));
    final offer = read('lib/widgets/offer_banner.dart');
    expect(offer, contains('GlassNotificationBanner.show('));
    expect(offer, isNot(contains('OverlayEntry')));
  });

  test('event notices are banners, not bottom SnackBars', () {
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');
    for (final sig in [
      'void _onShiftEndedPush(',
      'void _showDispatchPresenceNotice(',
      'void _onDispatchPresenceSet(',
    ]) {
      final b = body(ctrl, sig);
      expect(b, contains('GlassNotificationBanner.show('), reason: sig);
      expect(b, isNot(contains('showSnackBar')), reason: sig);
    }

    final trip = read('lib/screens/driver/driver_trip_accept_screen.dart');
    final route = body(trip, 'void _showRouteChangeBanner(');
    expect(route, contains('GlassNotificationBanner.show('));
    expect(route, isNot(contains('MaterialBanner')));
    expect(trip, isNot(contains('Passenger no-show — Trip auto-cancelled')),
        reason: 'the hard-coded bilingual SnackBar is now S.of(context) copy');
    expect('riderNoShowCancelledBody'.allMatches(trip).length, 2);

    final pickup = read('lib/screens/rider_confirm_pickup_screen.dart');
    final cancelled = body(pickup, 'void _onTripCancelled(');
    expect(cancelled, contains('GlassNotificationBanner.show('));
    expect(cancelled, isNot(contains('showSnackBar')));

    final sched = read('lib/screens/driver/scheduled_rides_map_screen.dart');
    final pending = body(sched, 'void _tryConsumePendingSelect(');
    expect(pending, contains('GlassNotificationBanner.show('));
    expect(pending, isNot(contains('showSnackBar')));

    final rr = read('lib/screens/ride_request_controller.dart');
    expect('title: S.of(context).noDriversAvailableTitle'.allMatches(rr).length +
            'title: noDriversTitle'.allMatches(rr).length,
        2,
        reason: 'both no-driver auto-cancel notices are banners');

    expect(body(mainDart, 'void _showOfferGoneNotice('),
        contains('GlassNotificationBanner.show('));

    final screen = read('lib/screens/driver/driver_online_screen.dart');
    final gate = screen.indexOf('S.of(context).goOnlineEnabledBody');
    expect(gate, isNonNegative);
    expect(screen.lastIndexOf('GlassNotificationBanner.show(', gate),
        greaterThan(gate - 200));
  });

  test('banner copy is localized (ES + EN)', () {
    final l10n = read('lib/l10n/app_localizations.dart');
    expect(l10n, contains('String get riderNoShowCancelledBody => _es'));
    expect(l10n, contains('String get riderMissedPickupBody => _es'));
  });

  test('an old iOS binary keeps its system banner (no double banner)', () {
    // A Shorebird patch carries the Dart banner but not the AppDelegate
    // change: builds before it still present the system banner in
    // foreground, so the glass copy must stay off there.
    final main = read('lib/main.dart');
    expect(main, contains('const int kFirstQuietForegroundPushIosBuild = 754;'));
    final fn = main.indexOf('void _showPushBanner(');
    final guard = main.indexOf(
        '(_nativeBuildNumber ?? 0) < kFirstQuietForegroundPushIosBuild', fn);
    expect(guard, greaterThan(fn));
    expect(guard, lessThan(main.indexOf('GlassNotificationBanner.show(', fn)));
    expect(main, contains('_nativeBuildNumber = int.tryParse(packageInfo.buildNumber);'));
  });

  test("declining an offer shows the 5 s glass note (only the driver's X)", () {
    expect(banner,
        contains('const kDeclinedOfferBannerDuration = Duration(seconds: 5);'));
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');
    final fn = ctrl.indexOf('Future<void> _rejectOffer(Map<String, dynamic> r,');
    expect(fn, isNonNegative);
    final show = ctrl.indexOf('title: S.of(context).offerDeclinedBanner,', fn);
    expect(show, greaterThan(fn));
    expect(ctrl.lastIndexOf('if (byDriver && mounted) {', show), greaterThan(fn));
    expect(ctrl.indexOf('duration: kDeclinedOfferBannerDuration,', show),
        greaterThan(show));
    final screen = read('lib/screens/driver/driver_online_screen.dart');
    expect(screen, contains('_rejectOffer(_pendingOffers[idx], byDriver: true);'),
        reason: 'the X is the driver declining');
    final widgets = read('lib/screens/driver/driver_online_widgets.dart');
    expect(widgets, contains('_rejectOffer(offer);'),
        reason: 'the countdown running out is not a decline — no banner');
    final l10n = read('lib/l10n/app_localizations.dart');
    expect(l10n, contains("'Rechazaste una solicitud de viaje'"));
    expect(l10n, contains("'You declined a ride request'"));
  });
}
