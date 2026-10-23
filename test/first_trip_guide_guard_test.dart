import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 6-page first-trip guide (user spec 2026-10-23, owner
/// mockup): page 1 = tier×gender dress code gated by an Entendido morph,
/// pages 2–5 = the original four re-numbered, page 6 = the 24 h selfie
/// verification with a one-shot camera flash.
void main() {
  final src =
      File('lib/screens/driver/onboarding/first_trip_guide_screen.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
  final card = File('lib/widgets/selfie_verify_card.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final variantUtil = File('lib/utils/selfie_variant.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('six pages: dress code first, selfie last, the four originals '
      're-numbered 2–5', () {
    final dress = src.indexOf('_DressCodePage(');
    final selfie = src.indexOf('_SelfieVerifyPage(');
    expect(dress, greaterThan(-1));
    expect(selfie, greaterThan(dress));
    var prev = dress;
    for (final n in ['number: 2', 'number: 3', 'number: 4', 'number: 5']) {
      final i = src.indexOf(n, prev);
      expect(i, greaterThan(prev), reason: 'page $n in order');
      prev = i;
    }
    expect(selfie, greaterThan(prev));
    expect(src, contains('if (_page >= 5)'),
        reason: 'the last page is 6 now — the finish index moved');
  });

  test('the dress-code gate locks Next, Skip AND the swipe', () {
    expect(src, contains('bool _dressAcknowledged = false;'));
    expect(src, contains('_gateLocked => _page == 0 && !_dressAcknowledged'));
    expect(src, contains('? const NeverScrollableScrollPhysics()'),
        reason: 'the swipe cannot bypass the gate');
    expect(src, contains('onPressed: _gateLocked ? null : _next'),
        reason: 'Next and Skip are disabled on page 1 until acknowledged');
    expect(src, contains('if (_gateLocked) return;'),
        reason: 'defensive guard inside _next itself');
    expect(src, contains('onAcknowledged: () => setState(() => _dressAcknowledged = true)'),
        reason: 'the page fires the callback when the morph completes');
  });

  test('the Entendido morph draws a WHITE check and then unlocks', () {
    expect(src, contains('s.onlineIntroUnderstood'),
        reason: 'reuses the existing Entendido string — never duplicated');
    expect(src, contains('AnimatedSwitcher'),
        reason: 'button → gold circle → gone');
    expect(src, contains('class _CheckPainter extends CustomPainter'));
    expect(src, contains('..color = Colors.white'),
        reason: 'the check is white on the gold circle');
    expect(src, contains("const ValueKey('ack-circle')"));
  });

  test('the 8 variant assets exist and are referenced by interpolation', () {
    expect(src, contains('guide_dress_\$variant.png'));
    expect(card, contains('guide_selfie_\${widget.variant}.png'),
        reason: 'page 6 renders the SHARED SelfieVerifyCard — the selfie '
            'asset is referenced there');
    expect(src, contains('SelfieVerifyCard('));
    expect(src, contains('flash: true'),
        reason: 'the guide keeps its shutter flash; the selfie-check screen '
            'passes false');
    expect(
        src,
        contains("'\${widget.vip ? 'vip' : 'std'}_\${widget.female ? 'f' : 'm'}'"),
        reason: 'vip/std × m/f — unknown gender falls back to the men '
            'variant (default false)');
    for (final kind in ['guide_dress', 'guide_selfie']) {
      for (final tier in ['vip', 'std']) {
        for (final g in ['m', 'f']) {
          final p = 'assets/images/onboarding/${kind}_${tier}_$g.png';
          expect(File(p).existsSync(), isTrue, reason: 'missing asset $p');
        }
      }
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/images/onboarding/'));
  });

  test('the variant resolves from the active vehicle tier + cached gender',
      () {
    // One shared source (utils/selfie_variant.dart) — the guide AND the
    // selfie-check screen resolve through it, never inline.
    expect(src, contains('resolveSelfieVariant()'));
    expect(variantUtil, contains("tier == 'vip' || tier == 'black'"),
        reason: 'VIP = the ACTIVE vehicle is vip or black');
    expect(variantUtil, contains("v['is_active'] == true"));
    expect(variantUtil, contains("u?['gender'] == 'female'"),
        reason: 'female from the cached profile; null/other → men variant');
  });

  test('the selfie page flashes once per entry, never in a loop', () {
    // The flash machinery lives in the shared card (flash: true from the
    // guide, false from the selfie-check screen).
    expect(card, contains('Tween<double>(begin: 0, end: 0.55)'),
        reason: 'the shutter flash peaks at ~0.55 white');
    expect(card, contains('bool _flashFired = false;'),
        reason: 'one shot per entry…');
    expect(card, contains('if (widget.active && !old.active) _fireFlash();'),
        reason: '…fired when the page becomes visible (page == 5)');
    expect(card, contains('if (!widget.active && old.active) _flashFired = false;'));
    expect(card, contains('addPostFrameCallback'));
    expect(card, isNot(contains('_FaceIconBadge')),
        reason: 'the top-right icon circle stays removed (owner spec '
            '2026-10-23) — the face_retouching glyph itself came BACK for '
            'chip 1 and the photo stand-in (it exists in the store font)');
  });

  test('chip icons are direct const args AND in the store-era font', () {
    // 2026-10-23 device proof: IconData passed through a helper param or a
    // ternary is INVISIBLE to the release tree-shaker and paints "?" — the
    // weak version of this pin only checked the names appeared in source and
    // the first store build shipped broken chips. The rule is const Icon(...)
    // widgets at the call site.
    for (final i in [
      'const Icon(Icons.auto_awesome_rounded',
      'const Icon(Icons.workspace_premium_rounded',
      'const Icon(Icons.thumb_up_rounded',
      'const Icon(Icons.access_time_rounded',
      'const Icon(Icons.straighten_rounded',
    ]) {
      expect(src, contains(i), reason: '$i must be a const Icon construction');
    }
    // SECOND RULE, same date, device-proven on the owner's phone: the store
    // build's MaterialIcons font is TREE-SHAKEN — a glyph first used by
    // OTA-delivered code paints "?". Every icon must ALSO exist in the
    // store-era font (auto_awesome_rounded was in; auto_awesome was NOT;
    // verified_user_outlined and visibility_off_outlined rendered).
    for (final i in [
      'const Icon(Icons.face_retouching_natural',
      'const Icon(Icons.person_outline_rounded',
      'const Icon(Icons.workspace_premium_rounded',
      'const Icon(Icons.lightbulb_outline_rounded',
      'const Icon(Icons.visibility_off_outlined',
    ]) {
      expect(card, contains(i), reason: '$i must be a const Icon construction');
    }
    // The glyphs that painted "?" on store-font devices stay OUT.
    for (final dead in [
      'Icons.checkroom',
      'Icons.sentiment_satisfied_alt',
      'Icons.workspace_premium_outlined',
      'Icons.face_outlined',
      'Icons.wb_sunny_outlined',
    ]) {
      expect(src, isNot(contains(dead)),
          reason: '$dead is not in the store-era font');
      expect(card, isNot(contains(dead)),
          reason: '$dead is not in the store-era font');
    }
    expect(card, isNot(contains('_FaceIconBadge')),
        reason: 'the top-right icon circle stays removed (owner spec '
            '2026-10-23: "el emoji de la esquina quítalo")');
    // …and the helpers must take the built widget, never a loose IconData.
    expect(src, isNot(contains('IconData icon')),
        reason: 'helpers taking IconData get tree-shaken to "?" in release');
    expect(card, isNot(contains('IconData icon')));
    expect(src, isNot(contains('_chip(Icons.')));
    expect(card, isNot(contains('_chip(Icons.')));
    expect(src, isNot(contains('_metric(Icons.')));
  });

  test('missing-photo stand-in: OTA patches carry no new assets', () {
    // Proven on the owner's phone 2026-10-23: a store build that predates
    // the guide_selfie/guide_dress PNGs shows an empty void. errorBuilder
    // keeps the page dignified until the next store build lands the files.
    expect(src, contains('errorBuilder: (context, error, stackTrace)'),
        reason: 'the dress card never paints a void');
    expect(card, contains('errorBuilder: (context, error, stackTrace)'),
        reason: 'the selfie card never paints a void');
    expect(src, contains('guide_dress_\$variant.png'));
    expect(card, contains('guide_selfie_\${widget.variant}.png'));
  });

  test('the new l10n strings exist in ES and EN', () {
    for (final g in [
      "String get dressVipTitle =>",
      "String get dressStdTitle =>",
      "String get dressBodyVipM =>",
      "String get dressBodyVipF =>",
      "String get dressBodyStdM =>",
      "String get dressBodyStdF =>",
      "String get dressChipElegant =>",
      "String get dressChipProfessional =>",
      "String get dressChipPremium =>",
      "String get dressChipCleanM =>",
      "String get dressChipCleanF =>",
      "String get dressChipPresentable =>",
      "String get dressChipComfortable =>",
      "String get selfieVerifyTitle =>",
      "String get selfieVerifyEvery24h =>",
      "String get selfieBodyStd =>",
      "String get selfieBodyVip =>",
      "String get selfieChipFaceVisible =>",
      "String get selfieChipDressStd =>",
      "String get selfieChipDressVip =>",
      "String get selfieChipLighting =>",
      "String get selfieChipNoGlasses =>",
    ]) {
      expect(l10n, contains(g), reason: 'missing getter $g');
    }
    expect(l10n, contains("'Cada 24 horas'"));
    expect(l10n, contains("'Every 24 hours'"));
  });
}
