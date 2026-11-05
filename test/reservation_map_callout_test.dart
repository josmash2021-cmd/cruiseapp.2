import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:cruise_app/map/map_callout.dart';
import 'package:cruise_app/screens/driver/reservation_map_card.dart';
import 'package:cruise_app/widgets/map/map_callout_bubble.dart';

/// The driver's own reservation on the map before it starts (owner
/// 2026-11-05, Lyft's "Reserved Lyft · 5:55 PM"): a callout on its pickup;
/// tapped, it turns gold and the "Scheduled Ride" card takes the sheet's
/// place, with More info opening the reservation's page.
void main() {
  group('the reserved callout', () {
    test('calendar, no tile, 22 → 26', () {
      const titleH = kCalloutTitleSize * kCalloutLineHeight;
      const subH = kCalloutSubtitleSize * kCalloutLineHeight;
      final layout = CalloutLayout.of(
        CalloutVariant.reserved,
        const CalloutText(
          keepWidth: 100, // "Reserved Cruise"
          titleHeight: titleH,
          subtitleWidth: 50, // "5:55 PM"
          subtitleHeight: subH,
        ),
      );
      expect(calloutSpecOf(CalloutVariant.reserved), kReservedCalloutSpec);
      expect(layout.expandedBox.width, closeTo(9 + 22 + 8 + 100 + 12, 1e-9));
      expect(layout.frameAt(0).tileRadius, 0, reason: 'no tile behind it');
      expect(layout.frameAt(0).glyph, closeTo(26, 1e-9));
      expect(layout.frameAt(1).glyph, closeTo(22, 1e-9));
    });

    // A plain style: google_fonts would try the network in tests.
    TextStyle font(FontWeight w) => TextStyle(fontWeight: w);
    Widget bubble({required bool selected, VoidCallback? onTap}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [
            Positioned(
              left: 200,
              top: 300,
              child: MapCalloutBubble(
                variant: CalloutVariant.reserved,
                title: 'Reserved Cruise',
                subtitle: '5:55 PM',
                expanded: true,
                selected: selected,
                onTap: onTap,
                font: font,
              ),
            ),
          ]),
        );
    Color? textColor(WidgetTester t, String s) =>
        t.widget<Text>(find.text(s)).style?.color;
    Color? iconColor(WidgetTester t) =>
        t.widget<Icon>(find.byIcon(kReservedCalloutGlyph)).color;

    testWidgets('black with white text; selected, gold with black', (t) async {
      var taps = 0;
      await t.pumpWidget(bubble(selected: false, onTap: () => taps++));
      expect(find.byIcon(kReservedCalloutGlyph), findsOneWidget);
      expect(textColor(t, 'Reserved Cruise'), Colors.white);
      expect(textColor(t, '5:55 PM'), Colors.white);
      expect(iconColor(t), Colors.white);

      await t.tap(find.text('Reserved Cruise'));
      expect(taps, 1);

      // Gold, black text — "en vez de blanco dorado" (owner 2026-11-05).
      expect(kCalloutFillSelected, kTripCalloutTileGold);
      expect(kCalloutInkSelected, const Color(0xFF000000));
      await t.pumpWidget(bubble(selected: true, onTap: () => taps++));
      await t.pump(const Duration(milliseconds: 250));
      expect(textColor(t, 'Reserved Cruise'), kCalloutInkSelected);
      expect(textColor(t, '5:55 PM'), kCalloutInkSelected);
      expect(iconColor(t), kCalloutInkSelected);

      await t.pumpWidget(bubble(selected: false, onTap: () => taps++));
      await t.pump(const Duration(milliseconds: 250));
      expect(textColor(t, 'Reserved Cruise'), Colors.white,
          reason: 'closing the card turns it dark again');
    });
  });

  group('the callout time', () {
    final now = DateTime(2026, 11, 5, 9, 0);
    final en = S(const Locale('en'));
    final es = S(const Locale('es'));
    test('today: the time alone, as Lyft', () {
      expect(
          reservationCalloutWhen(en, DateTime(2026, 11, 5, 17, 55), now: now),
          '5:55 PM');
    });
    test('tomorrow and later', () {
      expect(
          reservationCalloutWhen(es, DateTime(2026, 11, 6, 17, 55), now: now),
          'Mañana · 5:55 PM');
      expect(reservationCalloutWhen(en, DateTime(2026, 11, 6, 7, 5), now: now),
          'Tomorrow · 7:05 AM');
      // 2026-11-08 is a Sunday.
      expect(
          reservationCalloutWhen(es, DateTime(2026, 11, 8, 17, 55), now: now),
          'Dom · 5:55 PM');
      expect(
          reservationCalloutWhen(en, DateTime(2026, 11, 8, 17, 55), now: now),
          'Sun · 5:55 PM');
    });
  });

  testWidgets('the card: title, address, More info and the X', (t) async {
    var closed = 0, info = 0;
    await t.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      home: Scaffold(
        backgroundColor: const Color(0xFF0A1128),
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ReservationMapCard(
            address: '1824 Montgomery Hwy S, Hoover, AL',
            bottomInset: 34,
            onClose: () => closed++,
            onMoreInfo: () => info++,
          ),
        ),
      ),
    ));
    await t.pump(); // the localizations load
    expect(find.text('Viaje reservado'), findsOneWidget);
    expect(find.text('1824 Montgomery Hwy S, Hoover, AL'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    await t.tap(find.text('Más info'));
    expect(info, 1);
    await t.tap(find.byKey(ReservationMapCard.closeKey));
    expect(closed, 1);
  });

  test('the driver map wires it in', () {
    String read(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');
    final callouts = read('lib/screens/driver/driver_online_callouts.dart');
    final screen = read('lib/screens/driver/driver_online_screen.dart');
    final widgets = read('lib/screens/driver/driver_online_widgets.dart');
    final ctrl = read('lib/screens/driver/driver_online_controller.dart');

    // The callout: the reservation's pickup, gold while its card is open.
    expect(callouts, contains('variant: CalloutVariant.reserved,'));
    expect(callouts, contains('selected: _resvCardOpen,'));
    expect(callouts, contains("calloutNum(r['pickup_lat'])"));
    expect(widgets, contains('_reservationCalloutOverlay()'));
    // More info = the reservation's own page; the X puts the sheet back.
    expect(callouts, contains('onMoreInfo: () => _openReservationDetail(r),'));
    expect(callouts, contains('onClose: _closeReservationCard,'));
    expect(screen, contains('_reservationCardLayer(),'));
    // The card takes the sheet's place: sheet, GO and side buttons step away.
    expect(screen,
        contains('_pendingOffers.isNotEmpty || _resvCardShown || _acceptedOverlay != null;'));
    expect(screen, contains('offset: _sheetStepsAway ? const Offset(0, 1) : Offset.zero,'));
    expect(screen, contains('hidden: _driverOnline || _resvCardShown'));
    expect(widgets, contains('_panelFrac > 0.04 || _resvCardShown'));
    // Another reservation (or none) never inherits an open card; a trip
    // callout's offer closes it.
    expect(
        ctrl,
        contains(
            "if (next?['id'] != _nextReservation?['id']) _resvCardOpen = false;"));
    expect(callouts,
        contains('_resvCardOpen = false;\n      _pendingOffers = [offer];'));
  });
}
