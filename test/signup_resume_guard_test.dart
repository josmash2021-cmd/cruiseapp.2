import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the abandoned-signup resume (user report 2026-09-27).
///
/// The account row is created when the SMS code verifies — with EMPTY
/// names. Bailing at the name page and re-entering the number later used to
/// land on a blank home ("New rider", default photo) because the backend
/// reported `is_new_user` as "row did not exist". Now "new" means "never
/// finished onboarding", and the resume is a LADDER — names, then email —
/// applied at every entry: both welcome screens (phone + Apple), and the
/// splash boot for a persisted half-finished session. Rider and driver
/// share the fix.
void main() {
  final auth =
      File('backend/routers/auth.py').readAsStringSync();
  final riderWelcome =
      File('lib/screens/rider_welcome_screen.dart').readAsStringSync();
  final driverWelcome =
      File('lib/screens/driver/driver_welcome_screen.dart').readAsStringSync();
  final splash = File('lib/screens/splash_screen.dart').readAsStringSync();

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

  test('rider welcome: the ladder resumes at email when names are done', () {
    expect(riderWelcome.contains('void _routeByProfile('), isTrue);
    expect(riderWelcome.contains('RiderEmailScreen(user: user)'), isTrue,
        reason: 'names done + no email = abandoned at the email step — '
            'resume there, not at home with no email');
    // The Apple path must run the same ladder (before it keyed off hasPhone
    // and could land home with a blank name).
    final apple = riderWelcome.indexOf('_appleSignIn');
    final appleBlock = riderWelcome.substring(apple, apple + 2600);
    expect(appleBlock.contains('_routeByProfile(user, isNewUser: false)'),
        isTrue);
  });

  test('driver welcome: names then email, then the approval routing', () {
    expect(
      driverWelcome.contains("data['is_new_user'] == true ||\n"
          '        (user[\'first_name\'] ?? \'\').toString().trim().isEmpty'),
      isTrue,
    );
    expect(driverWelcome.contains('DriverNameScreen(user: user)'), isTrue);
    expect(driverWelcome.contains('DriverEmailScreen('), isTrue,
        reason: 'the email step is required (no skip) — a driver who '
            'abandoned there resumes there');
    expect(driverWelcome.contains('routeExistingDriver(context, user)'),
        isTrue,
        reason: 'past email, the to-do hub is the resume surface');
  });

  test('splash boot applies the ladder to a persisted half-finished session',
      () {
    expect(splash.contains('_riderResumeScreen(await UserSession.getUser())'),
        isTrue,
        reason: 'cold start with a saved session must not boot a '
            'half-finished rider into the home screen');
    expect(splash.contains('_driverResumeScreen(await UserSession.getUser())'),
        isTrue);
    expect(splash.contains('RiderNameScreen(user: user)'), isTrue);
    expect(splash.contains('RiderEmailScreen(user: user)'), isTrue);
    expect(splash.contains('DriverNameScreen(user: user)'), isTrue);
    expect(splash.contains('DriverEmailScreen(firstName: firstName)'), isTrue);
  });
}
