import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-10-29: drivers Alexis (370) and Fred (490) both got
/// photos/riders/0/profile.jpg after a failed /auth/me — the second upload
/// replaced the first one's face. A profile photo never goes to a guessed
/// owner.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('storage refuses an unknown owner', () {
    final s = read('lib/services/firebase_storage_service.dart');
    final up = s.substring(s.indexOf('static Future<String> uploadProfilePhoto('));
    expect(up.substring(0, 900), contains('if (userId <= 0 || (role != \'rider\' && role != \'driver\'))'));
  });

  test('upload never guesses id 0 or "rider"', () {
    final a = read('lib/services/api_service.dart');
    final up = a.substring(a.indexOf('static Future<String> uploadPhoto('));
    final body = up.substring(0, 1500);
    expect(body, isNot(contains("?? 'rider').toLowerCase()")));
    expect(body, contains("throw StateError('owner unknown"));
  });

  test('edit profile does not default the role', () {
    final e = read('lib/screens/edit_profile_screen.dart');
    expect(e, isNot(contains("user?['role'] ?? 'rider'")));
  });

  test('recovery ignores the old shared id 0', () {
    final r = read('lib/services/photo_recovery_service.dart');
    expect(r, contains("u == '0'"));
    expect(r, contains('if (_isUnknownOwner(uid)) return null;'));
  });
}
