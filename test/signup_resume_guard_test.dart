import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the abandoned-signup resume (user report 2026-09-27).
///
/// The account row is created when the SMS code verifies — with EMPTY
/// names. Bailing at the name page and re-entering the number later used to
/// land on a blank home ("New rider", default photo) because the backend
/// reported `is_new_user` as "row did not exist". Now "new" means "never
/// finished onboarding", and both welcome screens carry a local belt on top
/// of the backend flag. Rider and driver share the fix.
void main() {
  final auth =
      File('backend/routers/auth.py').readAsStringSync();
  final riderWelcome =
      File('lib/screens/rider_welcome_screen.dart').readAsStringSync();
  final driverWelcome =
      File('lib/screens/driver/driver_welcome_screen.dart').readAsStringSync();

  test('backend: a nameless existing row still routes to onboarding', () {
    expect(
      auth.contains(
          'is_new_user = user is None or not (user.first_name or "").strip()'),
      isTrue,
      reason: 'is_new_user must mean "profile incomplete", not "row just '
          'created" — an abandoned signup re-entering its number must go '
          'back to the name page',
    );
  });

  test('rider welcome: blank first_name forces the name page', () {
    expect(
      riderWelcome.contains("data['is_new_user'] == true ||\n"
          '        (user[\'first_name\'] ?? \'\').toString().trim().isEmpty'),
      isTrue,
      reason: 'the app-side belt catches ANY path that yields a blank '
          'profile (social, older backend) — never a blank home',
    );
    expect(riderWelcome.contains('RiderNameScreen(user: user)'), isTrue);
  });

  test('driver welcome: blank first_name forces the name page', () {
    expect(
      driverWelcome.contains("data['is_new_user'] == true ||\n"
          '        (user[\'first_name\'] ?? \'\').toString().trim().isEmpty'),
      isTrue,
    );
    expect(driverWelcome.contains('DriverNameScreen(user: user)'), isTrue);
  });
}
