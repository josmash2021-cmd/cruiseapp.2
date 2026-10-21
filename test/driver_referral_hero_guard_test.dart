import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the driver referral redesign: real milestones, hero artwork,
/// timeline and one fixed Share button.
void main() {
  final screen = File('lib/screens/driver/driver_referral_screen.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('the new hero image is bundled', () {
    expect(File('assets/images/referral_hero.png').existsSync(), isTrue);
    expect(screen, contains("assets/images/referral_hero.png"));
  });

  test('the rewards card reads live backend milestone values', () {
    for (final field in [
      '_refereeBonusCents',
      '_refereeBonusRides',
      '_m1Cents',
      '_m1Rides',
      '_m2Cents',
      '_m2Rides',
    ]) {
      expect(screen, contains(field), reason: '$field missing');
    }
    expect(screen, contains('_buildRewardsCard'));
    expect(screen, contains('driverReferralWinsTitle'));
    expect(screen, contains('driverYouEarnTitle'));
  });

  test('How It Works uses the four-step timeline', () {
    expect(screen, contains('_buildHowItWorksTimeline'));
    expect(screen, contains('driverHowShareTitle'));
    expect(screen, contains('driverHowSignupTitle'));
    expect(screen, contains('driverHowRidesTitle'));
    expect(screen, contains('driverHowPaidTitle'));
    expect(screen, contains('_timelineDashedLine'));
  });

  test('Share Referral Link is the fixed bottom action', () {
    expect(screen, contains('Positioned('));
    expect(screen, contains('_buildBottomShareButton'));
    expect(screen, contains('s.shareReferralLinkBtn'));
    expect(screen.contains('s.shareInviteLinkBtn'), isFalse,
        reason: 'the old in-card share button must not duplicate the fixed action');
    expect(l10n, contains('Share Referral Link'));
    expect(l10n, contains('Compartir enlace de referido'));
  });
}
