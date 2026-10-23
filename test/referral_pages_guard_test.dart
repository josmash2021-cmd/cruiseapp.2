import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the two-page referral screen (owner spec 2026-10-23,
/// literal: "la primera pagina de refer friend no quiero que tenga scroll —
/// ajusta para que se vea completa y bien adaptada. Página 1 completa,
/// página 2 al deslizar"). Page 1 = banner + code/Share + balance + how it
/// works (ONE card, 3 compact rows), never scrollable; page 2 = redeem +
/// referees + activity, swipe over.
void main() {
  final src = File('lib/screens/referral_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('horizontal PageView of 2 pages with the guide-style dots', () {
    expect(src, contains('PageView('));
    expect(src, contains('physics: const BouncingScrollPhysics()'));
    expect(src, contains('_buildMainPage()'));
    expect(src, contains('_buildActivityPage()'));
    expect(src, contains('onPageChanged: (i) => setState(() => _page = i)'));
    // Dots: active = elongated gold pill, inactive = grey dot (driver-guide
    // idiom).
    expect(src, contains('width: active ? 22 : 7'));
    expect(src, contains('_pageCtrl.dispose();'));
  });

  test('page 1 has NO scrollable inside its builder', () {
    final start = src.indexOf('Widget _buildMainPage()');
    final end = src.indexOf('Widget _buildActivityPage()');
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final page1 = src.substring(start, end);
    expect(page1.contains('ListView'), isFalse,
        reason: 'owner spec literal — page 1 must never scroll');
    expect(page1.contains('SingleChildScrollView'), isFalse,
        reason: 'not even with NeverScrollableScrollPhysics');
    expect(page1, contains('LayoutBuilder('),
        reason: 'belt and braces: the gaps scale below ~640 pt (iPhone SE)');
    expect(page1, contains('const Spacer()'),
        reason: 'the column distributes free space instead of scrolling');
  });

  test('page 1 keeps its blocks and the cascade entry', () {
    final start = src.indexOf('Widget _buildMainPage()');
    final end = src.indexOf('Widget _buildActivityPage()');
    final page1 = src.substring(start, end);
    expect(page1, contains('if (_myPendingBonus != null)'),
        reason: 'the pending-bonus banner stays conditional');
    expect(page1, contains('_entryItem(0, _buildPendingBonusBanner())'));
    expect(page1, contains('_entryItem(1, _buildCodeCard())'));
    expect(page1, contains('_entryItem(2, _buildBalanceCard())'));
    expect(page1, contains('_entryItem(3, _buildHowItWorks())'));
    expect(page1.contains('_buildRedeemBlock()'), isFalse,
        reason: 'redeem moved to page 2');
  });

  test('how-it-works is ONE card with 3 compact rows (icons cured)', () {
    final start = src.indexOf('Widget _buildHowItWorks()');
    final end = src.indexOf('Widget _buildRedeemBlock()');
    final hiw = src.substring(start, end);
    expect(hiw, contains('decoration: neuBox(radius: 16)'),
        reason: 'a single neuBox card wraps the three steps');
    expect(hiw.split('Divider(').length - 1, 2,
        reason: 'hairline dividers between the 3 rows');
    for (final i in [
      'const Icon(Icons.share_rounded',
      'const Icon(Icons.directions_car_rounded',
      'const Icon(Icons.savings_rounded',
    ]) {
      expect(src, contains(i),
          reason: '$i — icons are const Icon widgets at the call site');
    }
    expect(src, isNot(contains('Widget _step(int index, IconData icon')),
        reason: 'a loose IconData param tree-shakes to "?" in release');
    expect(src, contains('fontSize: 30'),
        reason: 'the balance amount compacted 36 → 30');
    expect(src, contains('EdgeInsets.fromLTRB(16, 14, 16, 14)'),
        reason: 'the balance card padding compacted 22/20 → 16/14');
  });

  test('page 2 scrolls and keeps the three activity blocks', () {
    final start = src.indexOf('Widget _buildActivityPage()');
    final end = src.indexOf('Widget _buildDots()');
    final page2 = src.substring(start, end);
    expect(page2, contains('ListView('));
    expect(page2, contains('_buildRedeemBlock()'));
    expect(page2, contains('_buildRefereesSection()'));
    expect(page2, contains('_buildTransactionsSection()'));
  });

  test('the logic is untouched', () {
    for (final fn in [
      'Future<void> _load()',
      'Future<void> _redeem()',
      'Future<void> _share()',
      'Future<void> _copyCode()',
      'Future<void> _openTransfer()',
    ]) {
      expect(src, contains(fn), reason: '$fn must survive the re-layout');
    }
    expect(src, contains('RefreshIndicator('),
        reason: 'pull-to-refresh wraps the PageView (vertical pull never '
            'fights the horizontal swipe)');
  });
}
