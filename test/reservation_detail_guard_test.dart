import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: tapping the gold "Viaje reservado" card opens the
/// reservation's own page ON TOP, in see-through blurred glass, laid out like
/// Lyft's scheduled-ride detail.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  final page = read('lib/screens/driver/reservation_detail_page.dart');
  final offline = read('lib/screens/driver/driver_online_offline.dart');

  test('the card opens the detail page, not the rides list', () {
    expect(offline, contains('onTap: () => _openReservationDetail(r),'));
    expect(offline, contains('unawaited(showReservationDetail('));
  });

  test('a see-through page over the screen, frosted', () {
    expect(page, contains('opaque: false,'),
        reason: 'the driver screen and its map stay visible behind');
    expect(page, contains('filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),'));
    expect(page, isNot(contains('MapWidget')),
        reason: 'never a second Mapbox surface');
  });

  test('Lyft layout: header, plan note, ride steps, more info, cancel', () {
    for (final k in [
      's.resDetailWith(firstName)',
      's.resDetailPlanTitle',
      's.resDetailRideDetails',
      's.goOnlineBy(_time(goBy))',
      's.resDetailPickupAt(_time(at))',
      's.trackDestination',
      's.resDetailMoreInfo',
      "ValueKey('res-how-to')",
      "ValueKey('res-cancel-policy')",
      "ValueKey('res-faq')",
      "ValueKey('res-cancel')",
    ]) {
      expect(page, contains(k), reason: k);
    }
  });

  test('owner 2026-11-03: CRUISE in capitals and gold', () {
    expect(page, contains("text: 'CRUISE', style: TextStyle(color: _gold)"));
    expect(page, isNot(contains(" Cruise'")));
  });

  test('"More info" rows open their own pages in the same glass', () {
    expect(page, contains('() => _openSub(_ResSub.how),'));
    expect(page, contains('() => _openSub(_ResSub.policy),'));
    expect(page, contains('() => _openSub(_ResSub.faq),'));
    expect(page, isNot(contains('showDriverHelpSheet')),
        reason: 'the FAQ row used to open the general Help sheet');
    expect(page, contains('canPop: _sub == null,'),
        reason: 'system back on a sub page returns to the reservation');
  });

  test('cancel asks first and hands the ride back to the board', () {
    expect(page, contains('await ApiService.cancelScheduledTrip(id);'));
    expect(page, contains('s.resDetailCancelConfirm'));
    expect(page, contains('s.resDetailCancelTooLate'),
        reason: 'inside 1 hour the server answers 400');
  });

  test('Spanish dates without DateFormat locales (it throws here)', () {
    expect(page, isNot(matches(RegExp(r"DateFormat\([^)]*'es'"))),
        reason: 'initializeDateFormatting is never called in this app');
    expect(page, contains('const _kMonthsEs = ['));
    expect(page, contains("'ene',"));
  });

  test('lookups off build() use maybeOf (rule 26)', () {
    expect(page, isNot(contains('Navigator.of(')));
    expect(page, isNot(contains('ScaffoldMessenger.of(')));
  });
}
