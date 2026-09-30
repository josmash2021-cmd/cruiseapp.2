import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/utils/date_of_birth.dart';

/// Guardian for the registration date-of-birth gate (user spec 2026-09-27):
/// every registration path collects DOB, riders are 18+, drivers 25+, and
/// the server re-gates every write (register + PATCH /auth/me).
void main() {
  group('computeAge (app side of the gate)', () {
    test('birthday today is the exact age; tomorrow is one year less', () {
      final today = DateTime(2026, 9, 27);
      expect(computeAge(DateTime(2008, 9, 27), today), 18);
      expect(computeAge(DateTime(2008, 9, 28), today), 17);
      expect(computeAge(DateTime(2001, 9, 27), today), 25);
      expect(computeAge(DateTime(2001, 9, 28), today), 24);
    });
  });

  group('the three registration surfaces collect and send DOB', () {
    test('rider name screen: required, 18+, sent in the PATCH', () {
      final s =
          File('lib/screens/rider_name_screen.dart').readAsStringSync();
      expect(s, contains('static const int _minAge = 18;'));
      expect(s, contains('pickDateOfBirth(context, minAge: _minAge'));
      expect(s, contains("'date_of_birth': _dobIso"),
          reason: 'without it in the PATCH the account never carries the '
              'date the age was proven with');
      expect(s.contains('S.of(context).dobMinAge(_minAge)'), isTrue);
    });

    test('driver name screen: required, 25+', () {
      final s = File('lib/screens/driver/driver_name_screen.dart')
          .readAsStringSync();
      expect(s, contains('static const int _minAge = 25;'));
      expect(s, contains("'date_of_birth': _dobIso"));
      expect(s.contains('S.of(context).dobMinAge(_minAge)'), isTrue);
    });

    test('legacy rider register (profile review): gated and sent', () {
      final s = File('lib/screens/profile_review_screen.dart')
          .readAsStringSync();
      expect(s, contains('static const int _minAge = 18;'));
      expect(s, contains('dateOfBirth: _dobIso'),
          reason: 'the register payload carries it — the schema 18+-gates '
              'a rider DOB when present');
      // The social path has no dob field — it goes through PATCH instead.
      expect(s.contains("'date_of_birth': _dobIso"), isTrue);
    });

    test('legacy driver signup: the picker cap moved 21 -> 25', () {
      final s = File('lib/screens/driver/driver_signup_screen.dart')
          .readAsStringSync();
      expect(s, contains('static const int _minDriverAge = 25;'));
      expect(s.contains('_minDriverAge = 21'), isFalse);
    });
  });

  group('every path lands on a DOB step (user spec 2026-09-30)', () {
    test('fresh accounts without DOB route to the name screen — rider AND '
        'driver welcome', () {
      final rider = File('lib/screens/rider_welcome_screen.dart')
          .readAsStringSync();
      final driver = File('lib/screens/driver/driver_welcome_screen.dart')
          .readAsStringSync();
      for (final src in [rider, driver]) {
        expect(src.contains('dobText.isEmpty && freshAccount'), isTrue,
            reason: 'a NEW account (created minutes ago) without a date of '
                'birth completes it at the name screen');
        expect(src.contains('const Duration(minutes: 15)'), isTrue,
            reason: 'scoped to fresh accounts — a legacy user logging in '
                'must not be bounced into registration');
      }
      expect(rider.contains('RiderNameScreen(user: user)'), isTrue);
      expect(driver.contains('DriverNameScreen(user: user)'), isTrue);
    });

    test('the name screens pre-fill the account names', () {
      final rider = File('lib/screens/rider_name_screen.dart')
          .readAsStringSync();
      final driver = File('lib/screens/driver/driver_name_screen.dart')
          .readAsStringSync();
      for (final src in [rider, driver]) {
        expect(src.contains("_firstCtrl.text = first"), isTrue,
            reason: 'the DOB rung must not force re-typing names the '
                'account already has');
        expect(src.contains("first != 'User'"), isTrue,
            reason: 'the Apple placeholder counts as empty');
      }
    });

    test('computeAge uses the UTC ruler, exactly like the server', () {
      final util =
          File('lib/utils/date_of_birth.dart').readAsStringSync();
      expect(util.contains('.toUtc()'), isTrue,
          reason: 'an 18th/25th-birthday evening must not pass the app gate '
              'and then bounce off the server gate (local date behind UTC)');
      expect(computeAge(DateTime(2008, 9, 27), DateTime(2026, 9, 27)), 18);
      expect(computeAge(DateTime(2008, 9, 28), DateTime(2026, 9, 27)), 17);
    });
  });

  group('backend gates (single source of truth in utils/helpers.py)', () {
    final helpers =
        File('backend/utils/helpers.py').readAsStringSync();
    final auth = File('backend/routers/auth.py').readAsStringSync();
    final model =
        File('backend/models/database.py').readAsStringSync();

    test('minimums are 18 rider / 25 driver', () {
      expect(helpers, contains('MIN_DRIVER_AGE = 25'));
      expect(helpers, contains('MIN_RIDER_AGE = 18'));
      expect(helpers, contains('def validate_rider_minimum_age'));
    });

    test('PATCH /auth/me re-gates every write by role', () {
      expect(auth.contains('if "date_of_birth" in updates:'), isTrue);
      final idx = auth.indexOf('if "date_of_birth" in updates:');
      final block = auth.substring(idx, idx + 900);
      expect(block.contains('validate_driver_minimum_age'), isTrue);
      expect(block.contains('validate_rider_minimum_age'), isTrue);
    });

    test('the column ships in the model AND both boot migration lists', () {
      expect(model, contains('date_of_birth = Column(Date, nullable=True)'));
      expect(
          RegExp(r'\("users", "date_of_birth", "DATE"\)')
              .allMatches(model)
              .length,
          2,
          reason: 'SQLite ensure-list AND Postgres boot list — trampa #0: '
              'a column in the model alone never reaches prod');
    });
  });
}
