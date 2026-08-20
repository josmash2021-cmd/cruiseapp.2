import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard tests: the in-app legal texts must reflect the Florida rider terms
/// (Cruise in Ride LLC / Fla. Stat. § 627.748), not the retired Alabama drafts.
void main() {
  const legalScreens = [
    'lib/screens/terms_of_service_screen.dart',
    'lib/screens/privacy_policy_screen.dart',
    'lib/screens/driver/driver_agreement_screen.dart',
  ];

  const bannedTerms = [
    'Alabama',
    'Birmingham',
    'BHM',
    'Jefferson County',
    'APSC',
    'Ala. Code',
  ];

  group('Legal screens contain no Alabama-era text', () {
    for (final path in legalScreens) {
      for (final term in bannedTerms) {
        test('$path does not contain "$term"', () {
          final content = File(path).readAsStringSync();
          expect(content.contains(term), isFalse,
              reason: '$path still contains banned term "$term"');
        });
      }
    }
  });

  group('Rider Terms of Service reflect the Florida entity', () {
    final content =
        File('lib/screens/terms_of_service_screen.dart').readAsStringSync();

    test('references Cruise in Ride LLC', () {
      expect(content.contains('Cruise in Ride LLC'), isTrue);
    });

    test('references Florida', () {
      expect(content.contains('Florida'), isTrue);
    });

    test('references Fla. Stat. § 627.748', () {
      expect(content.contains('Fla. Stat. § 627.748'), isTrue);
    });
  });
}
