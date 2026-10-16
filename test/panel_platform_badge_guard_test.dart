import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch install split (user request 2026-10-14:
/// "quiero saber en dispatch todos los que tienen android y todos los que
/// tienen ios"). The app reports Platform.operatingSystem at boot; the
/// backend stores users.platform, mirrors it to Firestore and serves
/// /admin/platform-stats; the panel's people grid shows an Android/iOS
/// badge per card and the two count tiles in the filters submenu.
void main() {
  test('app reports platform at boot', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains("'platform': Platform.operatingSystem"),
        reason: 'android/ios verbatim from dart:io');
    expect(main, contains("'os_version': Platform.operatingSystemVersion"));
  });

  test('backend stores, caps, mirrors and exposes the platform', () {
    final auth = File('backend/routers/auth.py').readAsStringSync();
    expect(auth, contains('"platform"'),
        reason: 'platform is an accepted device field in PATCH /auth/me');
    expect(auth, contains('"platform": db_user.platform'),
        reason: 'the Firestore user doc gets the platform mirror');
    final model = File('backend/models/database.py').readAsStringSync();
    expect(
        model
            .split('platform = Column(String(10), nullable=True)')
            .length,
        greaterThan(1));
    expect(
        model
            .split('("users", "platform", "VARCHAR(10)")')
            .length,
        3,
        reason: 'the column goes in the model AND both migration lists '
            '(SQLite ensure + Postgres boot) — trap #0');
    final admin = File('backend/routers/admin.py').readAsStringSync();
    expect(admin, contains('/admin/platform-stats'));
    final helpers = File('backend/utils/helpers.py').readAsStringSync();
    expect(helpers, contains('"platform": getattr(u, \'platform\', None)'));
  });

  test('panel people grid carries the platform through to the card', () {
    final mainChunk = Directory('backend/dispatch_panel/assets')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('index-CuQT_62K'))
        .single
        .readAsStringSync();
    expect(mainChunk, contains('platform:c(t.platform)??null'),
        reason: 'the Firestore mappers keep the field');
    expect(mainChunk, contains('platform:c(e.platform)??null'),
        reason: 'the backend-roster mappers keep it too');
    expect(mainChunk, contains('guard-pin panel_platform_badge_guard_test'),
        reason: 'the bundle edit carries its guard-pin for the next '
            'out-of-repo rebuild');

    final gridChunk = Directory('backend/dispatch_panel/assets')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
        .map((f) => f.readAsStringSync())
        .firstWhere((s) => s.contains('PeopleGridScreen'), orElse: () => '');
    expect(gridChunk, isNotEmpty);
    expect(gridChunk, contains('s.platform==="android"?"Android":"iOS"'),
        reason: 'the card badge');
    expect(
        gridChunk,
        contains(
            'statTile("Android",w.filter(d=>d.platform==="android").length'),
        reason: 'the Android count tile in the filters submenu');
    expect(
        gridChunk,
        contains(
            'statTile("iOS",w.filter(d=>d.platform==="ios").length'),
        reason: 'the iOS count tile in the filters submenu');
  });
}
