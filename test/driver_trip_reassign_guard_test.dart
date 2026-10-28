import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch REASSIGN exit (2026-10-28): when the panel calls
/// `POST /admin/trips/{id}/reassign` the backend puts the trip back to
/// `requested` with no driver, mirrors it to Firestore with a fresh
/// `releasedAt`, and pushes `trip_reassigned` to the old driver. That phone
/// must LEAVE the trip screen and land on the online map with the "Viaje
/// reasignado" notice — before this, only `completed` / `cancelled` moved
/// the driver off a trip, so a reassigned driver kept driving to a pickup
/// that was no longer theirs.
void main() {
  final trip = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();

  group('trip screen leaves when dispatch takes the trip away', () {
    test('the backend poll reacts to requested / another owner', () {
      final poll = trip.indexOf('void _startStatusPoll() {');
      expect(poll, isNonNegative);
      final body = trip.substring(poll, trip.indexOf('void _onExternalCompletion', poll));
      expect(body, contains("_tripTakenAwayByDispatch(status, trip['driver_id'])"),
          reason: 'the 8 s poll is the authoritative exit path');
      expect(body, contains('_exitAfterRemoteCancel(reassigned: true)'));

      final helper = trip.indexOf('bool _tripTakenAwayByDispatch(');
      expect(helper, isNonNegative);
      final helperBody = trip.substring(helper, helper + 600);
      expect(helperBody, contains("if (status == 'requested')"));
      expect(helperBody, contains('owner != me'),
          reason: 'a trip now owned by someone else is also gone');
    });

    test('the Firestore fast path is gated on a fresh releasedAt', () {
      final listener = trip.indexOf('void _listenForRiderConfirmation() {');
      expect(listener, isNonNegative);
      final body = trip.substring(listener, trip.indexOf('void _startStatusPoll', listener));
      expect(body, contains("status == 'requested' &&"));
      expect(body, contains("_releasedAfterOpen(data['releasedAt'])"),
          reason: 'right after accept the mirror can lag on "requested" — '
              'only a release stamp newer than the screen means reassigned');
      expect(body, contains('_exitAfterRemoteCancel(reassigned: true)'));
      expect(trip, contains('final DateTime _screenOpenedAt = DateTime.now();'));
      expect(trip, contains('bool _releasedAfterOpen(Object? raw)'));
    });

    test('the exit carries the reassigned flag to the online screen', () {
      expect(trip, contains('void _exitAfterRemoteCancel({bool reassigned = false})'));
      expect(trip, contains("nav.pop(reassigned ? 'reassigned' : 'cancelled')"));
      expect(trip, contains('showReassignedNotice: reassigned'));
    });
  });

  group('online screen shows "Viaje reasignado"', () {
    test('the controller consumes the reassigned pop result', () {
      expect(ctrl, contains("result == 'cancelled' || result == 'reassigned'"));
      expect(ctrl, contains("_resetToSearchingOnRemoteCancel(reassigned: result == 'reassigned')"));
      expect(ctrl, contains('void _showCancelledNotice({bool reassigned = false})'));
      expect(ctrl, contains('_cancelledNoticeReassigned = reassigned;'));
    });

    test('the rebuilt screen honours showReassignedNotice', () {
      expect(screen, contains('final bool showReassignedNotice;'));
      expect(screen, contains('this.showReassignedNotice = false,'));
      expect(screen, contains('widget.showCancelledNotice || widget.showReassignedNotice'));
      expect(screen, contains('S.of(context).tripReassigned'));
      expect(screen, contains('S.of(context).driverTripReassignedReturning'));
    });

    test('both wordings exist in the localizations', () {
      expect(l10n, contains('String get tripReassigned =>'));
      expect(l10n, contains('String get driverTripReassignedReturning =>'));
      expect(l10n, contains('Viaje reasignado'));
    });

    test('the trip_reassigned push is known to the app', () {
      expect(mainDart, contains("'trip_reassigned'    => isEs ? 'Viaje reasignado'"));
      expect(mainDart, contains("type == 'trip_reassigned'"));
    });
  });
}
