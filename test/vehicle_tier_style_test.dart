import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/vehicle_tier_style.dart';

/// The tier mapping, pinned.
///
/// tierKey decides which photo a rider is shown for the ride they are
/// about to pay for, and it matches on substrings, which is the kind of
/// rule that breaks quietly. Mirrors backend/tests/test_vehicle_tiers.py.
void main() {
  group('the four canonical keys', () {
    test('pass through untouched', () {
      expect(tierKey('standard'), kTierStandard);
      expect(tierKey('compact'), kTierCompact);
      expect(tierKey('premium'), kTierPremium);
      expect(tierKey('black'), kTierBlack);
    });

    test('are case and separator insensitive', () {
      expect(tierKey('BLACK'), kTierBlack);
      expect(tierKey('  Premium  '), kTierPremium);
    });
  });

  group('the strings already in the database', () {
    test('comfort is Standard', () => expect(tierKey('comfort'), kTierStandard));
    test('sedan is Standard', () => expect(tierKey('sedan'), kTierStandard));
    test('vip is Black', () => expect(tierKey('vip'), kTierBlack));
    test('suv is Compact', () => expect(tierKey('suv'), kTierCompact));

    // A Traverse: three rows, six seats. Black is the seven-seat tier.
    test('suv_xl is Premium', () => expect(tierKey('suv_xl'), kTierPremium));
    test('SUV XL, as the rider app sends it', () {
      expect(tierKey('SUV XL'), kTierPremium);
      expect(tierKey('SUV-XL'), kTierPremium);
    });
  });

  group('display names with the tier buried in them', () {
    test('Cruise VIP', () => expect(tierKey('Cruise VIP'), kTierBlack));
    test('Cruise Black', () => expect(tierKey('Cruise Black'), kTierBlack));
    test('Premium SUV', () => expect(tierKey('Premium SUV'), kTierPremium));
    test('Compact SUV', () => expect(tierKey('Compact SUV'), kTierCompact));
    test('Suburban', () => expect(tierKey('Suburban'), kTierBlack));

    // The reason _textTokens is ordered. "suv" appears inside "suv xl";
    // testing it first would send a six-seat booking a RAV4.
    test('an SUV XL is not read as a plain SUV', () {
      expect(tierKey('Cruise SUV XL'), kTierPremium);
    });
  });

  group('nothing to go on', () {
    test('empty is Standard', () => expect(tierKey(''), kTierStandard));
    test('null is Standard', () => expect(tierKey(null), kTierStandard));
    test('nonsense is Standard', () => expect(tierKey('banana'), kTierStandard));
  });

  group('the photos', () {
    test('are the matched cruisert set, one per tier', () {
      expect(tierCarImage('standard'), 'assets/images/cruisert3.png');
      expect(tierCarImage('compact'), 'assets/images/cruisert_compact.png');
      expect(tierCarImage('premium'), 'assets/images/cruisert_suvxl.png');
      expect(tierCarImage('black'), 'assets/images/cruisert1.png');
    });

    test('are four different pictures', () {
      final seen = kVehicleTiers.map(tierCarImage).toSet();
      expect(seen.length, 4);
    });

    test('none of them is from the old three-quarter set', () {
      for (final t in kVehicleTiers) {
        expect(tierCarImage(t), isNot(contains('cruise_')));
      }
    });

    test('an old string still lands on the right photo', () {
      expect(tierCarImage('vip'), tierCarImage('black'));
      expect(tierCarImage('comfort'), tierCarImage('standard'));
      expect(tierCarImage('suv_xl'), tierCarImage('premium'));
    });
  });

  group('the share the driver keeps', () {
    test('climbs with the tier', () {
      expect(tierDriverShare('standard'), 0.60);
      expect(tierDriverShare('compact'), 0.62);
      expect(tierDriverShare('premium'), 0.65);
      expect(tierDriverShare('black'), 0.70);
    });

    test('never goes down as you climb', () {
      var last = 0.0;
      for (final t in kVehicleTiers) {
        expect(tierDriverShare(t), greaterThanOrEqualTo(last));
        last = tierDriverShare(t);
      }
    });
  });

  group('label and colour', () {
    test('the label is the tier, uppercase', () {
      expect(tierLabel('comfort'), 'STANDARD');
      expect(tierLabel('vip'), 'BLACK');
    });

    test('each tier is its own colour', () {
      final colours = kVehicleTiers.map(tierColor).toSet();
      expect(colours.length, 4);
    });

    test('each tier is its own icon', () {
      final icons = kVehicleTiers.map(tierIcon).toSet();
      expect(icons.length, 4);
    });
  });
}
