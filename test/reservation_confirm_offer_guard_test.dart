import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: 1 hour before pickup the driver gets his reservation as
/// an offer to confirm. Accept starts it now (the server sends no
/// `scheduled_at`, so it takes the normal accept path); rejecting it IS
/// cancelling the reservation.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  final card = read('lib/screens/driver/driver_online_widgets.dart');
  final ctrl = read('lib/screens/driver/driver_online_controller.dart');

  test('the card says it is the reservation to confirm, with its pickup', () {
    expect(card,
        contains("final bool isReservationConfirm = offer['reservation_confirm'] == true;"));
    expect(card, contains('label: s.badgeConfirmReservation,'));
    expect(card, contains('icon: Icons.task_alt_rounded,'));
    expect(card, contains("parseServerTime(offer['reservation_pickup_at'])"));
    expect(card,
        contains('s.resDetailPickupAt(_format12Hour(confirmPickupAt)),'));
    expect(card, contains('if (isScheduled || isConfirm) extra += 24;'),
        reason: 'the card height counts the badge row and the time line');
  });

  test('rejecting it says the reservation was cancelled, and the gold card '
      'leaves at once', () {
    expect(ctrl, contains('? S.of(context).resConfirmCancelledBanner'));
    expect(ctrl,
        contains('if (isConfirm && mounted) unawaited(_fetchScheduledCount());'));
  });
}
