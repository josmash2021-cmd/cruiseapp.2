import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android review (owner 2026-11-09, "revisa y verifica tú"): what looked
/// or behaved wrong on an Android phone and not on the iPhone. Captured at
/// 360×800 and 412×915 and read through the Android-only code.
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('Android 12+: the theme Stripe needs (adding a card failed)', () {
    for (final p in [
      'android/app/src/main/res/values-v31/styles.xml',
      'android/app/src/main/res/values-night-v31/styles.xml',
    ]) {
      final s = read(p);
      expect(s.contains('@android:style/Theme.'), isFalse, reason: p);
      expect(
          'parent="Theme.MaterialComponents.DayNight.NoActionBar"'
              .allMatches(s)
              .length,
          2,
          reason: p);
      expect(s.contains('windowSplashScreenBackground'), isTrue, reason: p);
    }
  });

  test('notifications: a white silhouette, not the white square', () {
    expect(File('android/app/src/main/res/drawable/ic_stat_cruise.xml').existsSync(),
        isTrue);
    expect(read('android/app/src/main/AndroidManifest.xml'),
        contains('android:resource="@drawable/ic_stat_cruise"'));
    final svc = read('lib/services/notification_service.dart');
    // Gated by build: a Dart patch on an older binary has no such resource.
    expect(svc, contains('const int kFirstStatIconAndroidBuild = 760;'));
    expect(svc, contains("if (build >= kFirstStatIconAndroidBuild) icon = '@drawable/ic_stat_cruise';"));
    expect(svc.contains("icon: '@mipmap/ic_launcher'"), isFalse);
  });

  test('Android back never ends a shift nor leaves a sheet behind', () {
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');
    expect(ctrl, contains('void _goBack() {}'));
    final rider = read('lib/screens/rider_tracking_screen.dart');
    final back = rider.substring(rider.indexOf('onPopInvokedWithResult'));
    expect(back.substring(0, 700).contains('_tripSheet.close();'), isTrue);
  });

  test('bars and insets', () {
    expect(read('lib/screens/rider_tracking_screen.dart'),
        contains('padding: EdgeInsets.only(bottom: bottomPad),\n'
            '                      child: _buildSearchingDriverCard(),')
            .or(contains('child: _buildSearchingDriverCard(),')));
    expect(read('lib/screens/driver/zone_nav_panel.dart'),
        contains('AppPlatform.isAndroid ? bottomPad : bottomPad * 0.5'));
    final widgets = read('lib/screens/ride_request_widgets.dart');
    expect(widgets.contains('16, 0, 16, 16 + bottomPad'), isFalse,
        reason: 'SafeArea already clears the bar');
  });

  test('Material defaults that showed only on Android', () {
    final theme = read('lib/config/app_theme.dart');
    // Both ThemeData plus the ElevatedButton style that already had it.
    expect('splashFactory: InkRipple.splashFactory,'.allMatches(theme).length,
        greaterThanOrEqualTo(3));
    expect(theme, contains('outline: Color(0x33FFFFFF),'));
    expect(read('lib/screens/driver/driver_trip_accept_screen.dart'),
        contains('textureView: true,'));
  });

  test('the picked tier fits a 360-wide phone', () {
    final widgets = read('lib/screens/ride_request_widgets.dart');
    expect(widgets, contains("key: const ValueKey('tierEtaLine'),"),
        reason: 'the long ETA line lives on its own row, not in the price column');
    expect(widgets, contains('width: selected ? (narrowCard ? 88 : 108) : 60,'));
    expect(widgets, contains('final iconOnly = sched == null &&'));
  });
}

extension on Matcher {
  Matcher or(Matcher other) => anyOf(this, other);
}
