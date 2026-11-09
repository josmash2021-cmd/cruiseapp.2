// The $10 promo and the ride sheet, as Lyft shows them (owner 2026-11-09,
// drawing https://claude.ai/artifact/9pumaYXccAZ4LSZdXfRehz):
//  - no "$10 OFF" / "30% OFF" badge before the prices; since later that day
//    "$10 off aplicado" sits beside the struck fare, and the payment row
//    under the list says "✓ Promo aplicada";
//  - the payment sheet: "Pago", the promo applied on top, "Métodos de
//    pago", the balance apart, no Save button (a tap picks and closes);
//  - the tier list has a ceiling and scrolls, so the sheet stops near half
//    the screen and the map shows the whole route;
//  - a "$10 de descuento" card on Inicio until it is used, and no more
//    fake "New monthly discount!" in the inbox.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('prices carry "\$10 off aplicado", not the old OFF badge', () {
    final src = _read('lib/widgets/quoted_fare_view.dart');
    expect(src.contains('quotedFareBadge'), isFalse);
    expect(src.contains('dollarOff('), isFalse);
    expect(src.contains("% OFF'"), isFalse);
    expect(src.contains('quotedFareOriginal'), isTrue,
        reason: 'the full fare is still struck through');
    // Owner 2026-11-09: "en el precio coloca la etiqueta de $10 off applied".
    expect(src.contains('quotedFareApplied'), isTrue);
    // Green text, no yellow box.
    expect(src.contains('static const green = Color(0xFF22C55E);'), isTrue);
    expect(src.contains('color: green,'), isTrue);
    expect(src.contains('.amountOffApplied('), isTrue);
    final l10n = _read('lib/l10n/app_localizations.dart');
    expect(l10n.contains(r"_es ? '\$$amount off aplicado' : '\$$amount off applied'"),
        isTrue);
  });

  test('the payment row says Promo aplicada when the price has a promo', () {
    final src = _read('lib/screens/ride_request_widgets.dart');
    expect(src.contains('promoApplied: optionHasPromo(option)'), isTrue);
    expect(src.contains('S.of(context).promoApplied'), isTrue);
  });

  test('the payment sheet is Lyft’s: promo on top, no Save', () {
    final src = _read('lib/screens/ride_payment_sheet.dart');
    final list = src.substring(src.indexOf('Widget _buildListPage()'),
        src.indexOf('List<Widget> _methodRows(S s)'));
    expect(list.contains('s.paymentLabel'), isTrue);
    expect(list.contains("ValueKey('paySheetPromo')"), isTrue);
    expect(list.contains('s.promoApplied'), isTrue);
    expect(list.contains('s.paymentMethodsHeader'), isTrue);
    expect(list.contains('s.balanceHeader'), isTrue);
    expect(list.contains('s.save'), isFalse, reason: 'no Save button');
    final pick = src.substring(src.indexOf('void _pick(String id)'));
    expect(pick.substring(0, pick.indexOf('\n  }')).contains('_save()'),
        isTrue,
        reason: 'tapping a method picks it and closes the sheet');
    final ctrl = _read('lib/screens/ride_request_controller.dart');
    expect(ctrl.contains('PaymentSheetPromo(_promoTitle(option))'), isTrue);
  });

  test('the tier list has a ceiling and scrolls inside the sheet', () {
    final src = _read('lib/screens/ride_request_widgets.dart');
    expect(src.contains('double _tierListMaxHeight('), isTrue);
    // Lyft's three heights: half to start, up = every tier, down = only the
    // picked card; a drag on the grabber or on the list moves between them.
    final screen = _read('lib/screens/ride_request_screen.dart');
    expect(screen.contains('enum _TierSheet { collapsed, half, full }'),
        isTrue);
    expect(screen.contains('_TierSheet _tierSheet = _TierSheet.half;'),
        isTrue);
    expect(
        RegExp(r'onVerticalDragEnd: \(d\) => _onTierSheetDragEnd\(d, option\)')
            .allMatches(src)
            .length,
        2,
        reason: 'the grabber and the list both move the sheet');
    final map = _read('lib/screens/ride_request_map.dart');
    // All the way up the whole route is still framed above the sheet
    // (owner 2026-11-09), with a band of map it can always fit in.
    expect(map.contains('if (to == _TierSheet.full) return;'), isFalse,
        reason: 'opening the sheet reframes the route above it');
    expect(map.contains('if (_tierSheet == _TierSheet.full) return;'),
        isFalse);
    expect(map.contains('final inset = _withRouteBand(target'), isTrue);
    expect(
        map.contains('return _withRouteBand(_sheetHeightPx + _sheetScreenGap'),
        isTrue);
    // Up there the labels would slide under the back button at 70.
    expect(
        map.contains(
            '_routeFitTop(_TierSheet size) => size == _TierSheet.full ? 100 : 70'),
        isTrue);
    expect(map.contains('paddingTop: top,'), isTrue);
    // The route is framed above the REAL sheet: the reporter measures the
    // first layout too (SizeChangedLayoutNotifier never does), and a refit
    // that lands during the opening flight waits for it instead of dying.
    final reporter = src.substring(
        src.indexOf('class _SheetSizeReporterState'),
        src.indexOf('class _SheetSizeReporterState') + 1600);
    expect(
        reporter.contains(
            'WidgetsBinding.instance.addPostFrameCallback((_) => _measure());'),
        isTrue);
    expect(map.contains('retryAfter(flying + const Duration('), isTrue);
    expect(src.contains('controller: _tierScrollCtrl'), isTrue);
    expect(src.contains('Scrollable.ensureVisible('), isTrue);
    // Select stays outside the scroll: the action panel follows the list.
    final list = src.indexOf('pickedId: option?.id');
    final panel = src.indexOf('_buildActionPanel(c, option, faresReady)');
    expect(list, greaterThan(0));
    expect(panel, greaterThan(list));
  });

  test('Inicio: a card for the \$10 until used, no fake monthly promo', () {
    final home = _read('lib/screens/home_screen.dart');
    final widgets = _read('lib/screens/home_screen_widgets.dart');
    expect(home.contains("title: '🎉 New monthly discount!'"), isFalse);
    expect(home.contains('generateMonthlyPromoIfNeeded'), isFalse);
    expect(home.contains('Future<void> _loadWelcomePromo()'), isTrue);
    expect(widgets.contains("ValueKey('homeWelcomePromo')"), isTrue);
    expect(widgets.contains('s.amountOffTitle('), isTrue);
  });
}
