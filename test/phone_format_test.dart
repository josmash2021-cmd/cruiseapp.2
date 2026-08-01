import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/utils/phone_format.dart';

void main() {
  group('formatUsPhone', () {
    test('formats what the server stores', () {
      expect(formatUsPhone('+13854612042'), '+1 (385) 461-2042');
    });

    test('formats a ten-digit number with no country code', () {
      expect(formatUsPhone('3854612042'), '+1 (385) 461-2042');
    });

    test('formats progressively as the driver types', () {
      expect(formatUsPhone('3'), '+1 (3');
      expect(formatUsPhone('385'), '+1 (385');
      expect(formatUsPhone('3854'), '+1 (385) 4');
      expect(formatUsPhone('385461'), '+1 (385) 461');
      expect(formatUsPhone('3854612'), '+1 (385) 461-2');
    });

    test('an empty field stays empty rather than becoming "+1 ("', () {
      expect(formatUsPhone(''), '');
      expect(formatUsPhone('+'), '');
    });

    test('re-formatting its own output is stable', () {
      const once = '+1 (385) 461-2042';
      expect(formatUsPhone(once), once);
      expect(formatUsPhone(formatUsPhone(once)), once);
    });

    test('a non-US number is left alone, not forced into the mask', () {
      // Thirteen digits — a UK mobile. Grouping it as (xxx) xxx-xxxx would
      // be a lie about where the breaks are.
      expect(formatUsPhone('+447911123456'), '+447911123456');
    });
  });

  group('usPhoneToE164', () {
    test('gives back the storage form', () {
      expect(usPhoneToE164('+1 (385) 461-2042'), '+13854612042');
    });

    test('accepts an unformatted ten-digit number', () {
      expect(usPhoneToE164('3854612042'), '+13854612042');
    });

    test('refuses a half-typed number', () {
      // This is what stops Save from firing on an incomplete field.
      expect(usPhoneToE164('+1 (385) 461'), '');
      expect(usPhoneToE164('385'), '');
      expect(usPhoneToE164(''), '');
    });

    test('refuses more digits than a US number has', () {
      expect(usPhoneToE164('+1 (385) 461-20429'), '');
    });

    test('round-trips through the formatter', () {
      expect(usPhoneToE164(formatUsPhone('+13854612042')), '+13854612042');
    });
  });
}
