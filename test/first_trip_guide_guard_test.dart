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
    expect(src, contains('guide_selfie_\$variant.png'));
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
    expect(src, contains("tier == 'vip' || tier == 'black'"),
        reason: 'VIP = the ACTIVE vehicle is vip or black');
    expect(src, contains("v['is_active'] == true"));
    expect(src, contains("u?['gender'] == 'female'"),
        reason: 'female from the cached profile; null/other → men variant');
  });

  test('the selfie page flashes once per entry, never in a loop', () {
    expect(src, contains('Tween<double>(begin: 0, end: 0.55)'),
        reason: 'the shutter flash peaks at ~0.55 white');
    expect(src, contains('bool _flashFired = false;'),
        reason: 'one shot per entry…');
    expect(src, contains('if (widget.active && !old.active) _fireFlash();'),
        reason: '…fired when the page becomes visible (page == 5)');
    expect(src, contains('if (!widget.active && old.active) _flashFired = false;'));
    expect(src, contains('addPostFrameCallback'));
    expect(src, contains("Icons.face_retouching_natural"),
        reason: 'the gold icon circle of page 6');
  });

  test('chip icons are direct const args (tree-shaker safe)', () {
    // Icons passed straight into a widget/helper arg are kept by the
    // release tree-shaker; the same IconData inside a record literal or a
    // const collection is dropped and paints "?".
    for (final i in [
      'Icons.checkroom',
      'Icons.workspace_premium_outlined',
      'Icons.face_outlined',
      'Icons.wb_sunny_outlined',
      'Icons.visibility_off_outlined',
      'Icons.face_retouching_natural',
      'Icons.sentiment_satisfied_alt',
    ]) {
      expect(src, contains(i));
    }
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
