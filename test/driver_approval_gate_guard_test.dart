import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/screens/driver/driver_welcome_screen.dart';

/// Guardian for the driver approval gate (user report 2026-10-06): an
/// UNAPPROVED driver landed on the approved UI because the app read account
/// LIVENESS (status='active' — every normal account) as approval, then
/// stamped 'approved' into the local cache, so cold starts skipped the live
/// re-check forever. Approval comes ONLY from the verification fields now;
/// the server side gates too (online flip 403 + dispatch candidate filter).
void main() {
  group('isApprovedDriverMap — approval only from verification fields', () {
    test('a live, never-reviewed account is NOT approved', () {
      expect(
        DriverWelcomeScreen.isApprovedDriverMap(const {
          'status': 'active',
          'verification_status': 'none',
          'is_verified': false,
        }),
        isFalse,
        reason: 'status=active is account liveness, not approval — this '
            'exact map is what let the unapproved driver in',
      );
    });

    test('approved verification_status passes', () {
      expect(
        DriverWelcomeScreen.isApprovedDriverMap(const {
          'status': 'active',
          'verification_status': 'approved',
          'is_verified': false,
        }),
        isTrue,
      );
    });

    test('is_verified passes (either casing)', () {
      expect(
        DriverWelcomeScreen.isApprovedDriverMap(const {
          'verification_status': 'none', 'is_verified': true,
        }),
        isTrue,
      );
      expect(
        DriverWelcomeScreen.isApprovedDriverMap(const {
          'verification_status': 'none', 'isVerified': true,
        }),
        isTrue,
      );
    });

    test('pending and rejected do not pass', () {
      for (final s in const ['pending', 'rejected', 'none', '']) {
        expect(
          DriverWelcomeScreen.isApprovedDriverMap(
              {'verification_status': s, 'is_verified': false}),
          isFalse,
          reason: '$s must not open the approved UI',
        );
      }
    });
  });

  group('source pins — the tolerant liveness sets stay gone', () {
    test('welcome routing: no accountStatus in the approval decision', () {
      final s = File('lib/screens/driver/driver_welcome_screen.dart')
          .readAsStringSync();
      expect(s.contains("'active', 'online', 'clear', 'verified'"), isFalse,
          reason: 'the tolerant set that admitted status=active');
      expect(s, contains('isApprovedDriverMap'));
    });

    test('splash: approved-only live status', () {
      final s = File('lib/screens/splash_screen.dart').readAsStringSync();
      expect(s.contains("s == 'active'"), isFalse);
      expect(s.contains("s == 'online'"), isFalse);
    });

    test('to-do hub: approved-only re-check', () {
      final s = File('lib/screens/driver/onboarding/driver_todo_screen.dart')
          .readAsStringSync();
      expect(s.contains("'active', 'online', 'clear', 'verified'"), isFalse);
    });
  });
}
