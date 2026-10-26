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

  test('page 1 is complete WITHOUT scroll; page 2 keeps its own', () {
    // Owner spec 2026-10-23: "la primera pagina que no tenga scroll, que se
    // vea completa en 1 pagina; la 2da normal al deslizar". Same gapScale
    // idiom as the rider referral screen (LayoutBuilder scales gaps and the
    // hero on short phones — fonts never scale).
    final mainPage = screen
        .split('Widget _buildMainReferralPage(S s) {')
        .last
        .split('  Widget _buildHeroArtwork(double height) {')
        .first;
    expect(mainPage, contains('LayoutBuilder('));
    expect(mainPage, contains('gapScale = (box.maxHeight / 700)'));
    expect(mainPage, isNot(contains('ListView(')),
        reason: 'page 1 has NO scrollable of any kind');
    expect(mainPage, isNot(contains('RefreshIndicator')));
    expect(
        mainPage,
        contains('const Spacer(),\n              _buildBottomShareButton(s),'),
        reason: 'Share is the last column child — pinned to the bottom by '
            'the Spacer; the floating Positioned overlay died with the '
            'scroll');
    expect(screen, isNot(contains('ignoring: _pageIndex != 0')),
        reason: 'no fade-out overlay anymore — the PageView swipes Share '
            'away with the page');
    final page2 = screen.split('Widget _buildMyReferralsPage(S s) {').last;
    expect(page2, contains('ListView('),
        reason: 'page 2 ("My Referrals") keeps its normal scroll');
    expect(page2, contains('RefreshIndicator'));
  });

  test('Share Referral Link is the fixed bottom action', () {
    expect(screen, contains('_buildBottomShareButton'));
    expect(screen, contains('s.shareReferralLinkBtn'));
    expect(screen.contains('s.shareInviteLinkBtn'), isFalse,
        reason: 'the old in-card share button must not duplicate the fixed action');
    expect(l10n, contains('Share Referral Link'));
    expect(l10n, contains('Compartir enlace de referido'));
  });
}
