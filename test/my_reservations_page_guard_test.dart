import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner-approved drawing 2026-11-03: the driver's reservations page as
/// Lyft-style cards — no tabs, no count; a dismissable note; per card the
/// time, pay, go-online deadline, pickup/drop-off, stops (the app's gold
/// stop mark), the rider and the ride type; "Ver detalles" (or "Navegar a
/// la recogida" once confirmed); the FAQ at the end.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final page = read('lib/screens/driver/my_reservations_page.dart');
  final map = read('lib/screens/driver/scheduled_rides_map_screen.dart');

  test('the list and the map count share one filter', () {
    // 2026-11-03: "Tus viajes (N)" counted every row the server sent; a
    // web booking "for now" (scheduled_at < created_at + 3 min) also
    // showed as an EN CAMINO reservation.
    expect(page, contains('final fresh = myReservationRows(all, DateTime.now());'));
    expect(map, contains('myReservationRows(trips, DateTime.now()).length'));
    expect(page, contains("at.isBefore(created.add(const Duration(minutes: 3)))"));
    // A refresh asked for mid-load is queued, not dropped.
    expect(page, contains('_reloadQueued = true;'));
  });

  test('the map opens it; the old tabbed list is gone', () {
    expect(map, contains('slideFromRightRoute(const MyReservationsPage())'));
    expect(File('lib/screens/driver/scheduled_rides_screen.dart').existsSync(),
        isFalse);
    expect(page, isNot(contains('TabBar')));
  });

  test('a card: the CTA follows the ride, the stop mark is the app\'s', () {
    expect(page, contains(
        'onTap: () => enRoute ? unawaited(_navigate(t)) : _openDetails(t),'));
    expect(page, contains('child: FittedBox(child: RiderStopPin()),'));
    expect(page, contains('s.myResStops(stops)'));
    expect(page, contains("enRoute\n                ? s.myResConfirmed"));
  });

  test('details open the glass page; the end opens the FAQ', () {
    expect(page, contains('showReservationDetail(context, trip, onCancelled: _load)'));
    expect(page, contains('unawaited(showReservationFaq(context));'));
  });

  test('the note can be closed, and stays closed', () {
    expect(page, contains("const _kNoteHiddenKey = 'my_res_note_hidden';"));
    expect(page, contains('if (!_noteHidden) _note(s),'));
  });

  test('Spanish dates without DateFormat locales', () {
    expect(page, isNot(matches(RegExp(r"DateFormat\([^)]*'es'"))));
  });
}
