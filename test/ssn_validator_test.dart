import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/ssn_validator.dart';

/// The SSN structure check, pinned.
///
/// This gate decides whether a driver's application carries a number a human
/// reviewer will later have to chase. It must reject what the SSA has said it
/// never issues, and it must not reject anybody's real number — a false
/// rejection means a driver who cannot finish signing up and has no way to
/// argue with the form.
void main() {
  group('accepts numbers the SSA could have issued', () {
    for (final ssn in const [
      '123-45-6788',
      '001-01-0001', // the lowest number the rules allow
      '665-99-9999', // just below the 666 hole
      '667-01-0001', // just above it
      '899-99-9999', // the highest area ever issued
      '772-12-3456', // an area only issued after 2011 randomization
      '458-22-7391',
    ]) {
      test(ssn, () => expect(ssnProblem(ssn), isNull, reason: ssn));
    }

    test('separators and spacing do not matter', () {
      expect(isPlausibleSsn('458227391'), isTrue);
      expect(isPlausibleSsn('458-22-7391'), isTrue);
      expect(isPlausibleSsn('458 22 7391'), isTrue);
      expect(isPlausibleSsn(' 458.22.7391 '), isTrue);
    });
  });

  group('rejects what is never issued', () {
    for (final ssn in const [
      '000-12-3456', // area 000
      '666-12-3456', // area 666
      '900-12-3456', // the 9xx block
      '999-99-9999',
      '772-00-1234', // group 00
      '772-12-0000', // serial 0000
    ]) {
      test(ssn,
          () => expect(ssnProblem(ssn), SsnProblem.neverIssued, reason: ssn));
    }
  });

  group('rejects the famous fakes', () {
    test('the Woolworth wallet card', () {
      expect(ssnProblem('078-05-1120'), SsnProblem.knownFake);
    });

    test('the voided advert number', () {
      expect(ssnProblem('219-09-9999'), SsnProblem.knownFake);
    });

    test('the placeholder every form receives', () {
      expect(ssnProblem('123-45-6789'), SsnProblem.knownFake);
    });

    test('nine of the same digit, every one of them', () {
      for (var i = 0; i <= 9; i++) {
        expect(isPlausibleSsn('$i' * 9), isFalse, reason: '${i}x9');
      }
      // Which rule catches them differs, and that is fine — 000, 666 and 999
      // are areas the SSA never issues, so they are rejected one step before
      // the repeated-digit check ever runs.
      expect(ssnProblem('111111111'), SsnProblem.knownFake);
      expect(ssnProblem('666666666'), SsnProblem.neverIssued);
      expect(ssnProblem('999999999'), SsnProblem.neverIssued);
    });

    test('the advertising block the SSA reserves', () {
      // 987-65-4320..4329. Rejected as never-issued rather than as a fake,
      // because area 987 is inside the 9xx hole.
      for (var i = 0; i <= 9; i++) {
        expect(ssnProblem('98765432$i'), SsnProblem.neverIssued,
            reason: '98765432$i');
      }
    });
  });

  group('is quiet while they are still typing', () {
    for (final partial in const ['', '4', '458', '458-22', '45822739']) {
      test('"$partial"',
          () => expect(ssnProblem(partial), SsnProblem.incomplete));
    }

    test('and on too many digits', () {
      expect(ssnProblem('4582273911'), SsnProblem.incomplete);
    });

    test('and on letters alone', () {
      expect(ssnProblem('abcdefghi'), SsnProblem.incomplete);
    });
  });

  test('every possible area is decided, none crash', () {
    // Sweep the whole area space against a fixed valid tail.
    for (var a = 0; a < 1000; a++) {
      final ssn = '${a.toString().padLeft(3, '0')}227391';
      final problem = ssnProblem(ssn);
      final shouldPass = a != 0 && a != 666 && a < 900;
      expect(problem == null, shouldPass, reason: ssn);
    }
  });
}
