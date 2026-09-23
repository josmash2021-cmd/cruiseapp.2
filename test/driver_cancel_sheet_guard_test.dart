import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver cancel-at-any-stage flow (user spec 2026-09-19):
///
///   1. Cancel Trip shows in the support menu at EVERY stage — to-pickup
///      (backend rematches) and in-trip (backend ends the trip, hold
///      released, nobody charged). The pre-pickup-only gate is gone.
///   2. The reason sheet follows the reference layout: X close, big title,
///      the "No se te pagará por este viaje" note, radio reasons, and a
///      "Siguiente" button armed only once a reason is picked.
///   3. Machine strings for the API: 7 reasons in the exact order of the
///      reference, labels localized.
void main() {
  final src = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  group('cancel available at any stage', () {
    test('the menu item is NOT gated on _rideStarted anymore', () {
      final start = src.indexOf('_SheetItem(Icons.cancel_outlined');
      expect(start, isNonNegative, reason: 'cancel menu item not found');
      final before = src.substring(start - 400, start);
      expect(before.contains('if (!_rideStarted)'), isFalse,
          reason: 'user spec 2026-09-19: cancel works in-trip too — the '
              'backend now ends the trip instead of 409ing it');
    });

    test('the sheet gate no longer blocks in-trip', () {
      final body = src.substring(
          src.indexOf('void _showDriverCancelSheet() {'),
          src.indexOf('void _showDriverCancelSheet() {') + 400);
      expect(body.contains('_rideStarted'), isFalse,
          reason: 'in-trip cancel is allowed end to end now');
    });
  });

  group('reference reason sheet', () {
    final start = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync()
        .indexOf('void _showDriverCancelSheet() {');
    final body = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync()
        .substring(start, start + 5200);

    test('X close, big title, no-pay note', () {
      expect(body.contains('Icons.close_rounded'), isTrue,
          reason: 'the reference has the X at top-left');
      expect(body.contains('s.driverCancelChooseTitle'), isTrue);
      expect(body.contains('s.driverCancelNoPay'), isTrue,
          reason: '"No se te pagará por este viaje." is the subtitle');
    });

    test('exactly the 7 reference reasons with their machine strings, in order', () {
      final reasons = [
        'not_desirable',
        'bad_route',
        'difficult_pickup',
        'accepted_by_accident',
        'destination_changed',
        'vehicle_issue',
        'personal',
      ];
      var pos = 0;
      for (final r in reasons) {
        final at = body.indexOf("'$r'", pos);
        expect(at, isNonNegative, reason: '$r missing from the reasons list');
        expect(at, greaterThanOrEqualTo(pos),
            reason: 'reasons out of reference order at $r');
        pos = at;
      }
    });

    test('radio circles and a selection-gated Siguiente button', () {
      expect(body.contains('BoxShape.circle'), isTrue,
          reason: 'the reference uses radio circles, not chevron rows');
      expect(body.contains('onPressed: selected < 0'), isTrue,
          reason: 'Siguiente stays disabled until a reason is picked');
      expect(body.contains('s.nextLabel'), isTrue);
      expect(body.contains('_confirmDriverCancel(reasons[selected].\$2)'),
          isTrue,
          reason: 'Siguiente routes the machine reason into the existing '
              'confirm + API flow');
    });
  });

  group('l10n keys exist', () {
    test('new reference keys are defined', () {
      for (final key in [
        'driverCancelChooseTitle',
        'driverCancelNoPay',
        'driverCancelReasonNotDesirable',
        'driverCancelReasonBadRoute',
        'driverCancelReasonDifficultPickup',
        'driverCancelReasonByAccident',
        'driverCancelReasonDestChanged',
        'driverCancelReasonPersonal',
        'nextLabel',
      ]) {
        expect(l10n.contains('String get $key'), isTrue,
            reason: '$key missing from app_localizations.dart');
      }
    });
  });
}
