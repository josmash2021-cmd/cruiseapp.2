import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Apple Pay / payment-sheet label (owner spec 2026-10-18:
/// "standard debe decir CRUISE IN RIDE - STANDARD, COMPACT, PREMIUM O VIP
/// dependiendo del que seleccionó").
void main() {
  final ctrl =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();
  final screen =
      File('lib/screens/ride_request_screen.dart').readAsStringSync();
  final style =
      File('lib/utils/vehicle_tier_style.dart').readAsStringSync();

  test('the payment label is CRUISE IN RIDE - {TIER} from the selected tier',
      () {
    expect(ctrl, contains("'CRUISE IN RIDE - \${tripTierLabel(option.id)}'"),
        reason: 'the sheet reads the canonical tier, uppercase');
    expect(ctrl, isNot(contains("'Cruise · \${option.name}'")),
        reason: 'the old "Cruise · Sedan" label is dead');
    expect(screen, contains('vehicle_tier_style.dart'),
        reason: 'tripTierLabel is imported');
  });

  test('tripTierLabel maps booking names to the canonical tier, uppercase',
      () {
    expect(style, contains('String tripTierLabel(String? raw)'));
    expect(style, contains('tripTierKey(raw)'),
        reason: 'bookings use tripTierKey — "Sedan" (camry) is Compact and '
            '"SUV XL" is Premium, which tierKey gets backwards for bookings');
    // tripTierKey carries every mapping this label depends on:
    for (final needle in [
      "k.contains('camry')",
      "k.contains('suburban')",
      "k.contains('suv')",
      "k.contains('electric')",
    ]) {
      expect(style, contains(needle), reason: needle);
    }
  });
}
