import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for audit tanda 3 (session 2026-08-09): the buttons do what
/// they promise, the driver never goes ghost, and tips are computed on the
/// real fare.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final rating =
      File('lib/screens/rider_rating_screen.dart').readAsStringSync();

  group('a cancelled trip hands the chained booking back', () {
    test('_resetToSearchingOnRemoteCancel consumes the handoff', () {
      final start = ctrl.indexOf('void _resetToSearchingOnRemoteCancel()');
      expect(start, isNonNegative);
      final body = ctrl.substring(start, start + 2200);
      expect(body.contains('_handoffChainedOffer()'), isTrue,
          reason: 'the pop(cancelled) path stashes the booking in '
              'chainedHandoffOffer — without consuming it here the ride '
              'stays locked on the backend and never starts (audit #13)');
    });
  });

  group('a failed chained accept never resurrects the card', () {
    test('the offer id joins _chainedRejectedIds on failure', () {
      final start = trip.indexOf('Future<void> _acceptChained()');
      final body = trip.substring(start, start + 1500);
      final catchAt = body.indexOf('catch (e)');
      expect(catchAt, isNonNegative);
      expect(
          body.substring(catchAt, catchAt + 500)
              .contains('_chainedRejectedIds.add(offerId)'),
          isTrue,
          reason: 'the next SSE/poll delivery paints the same dead offer '
              'again (audit #19)');
    });
  });

  group('every return to searching restarts the GPS stream', () {
    test('both paths call _startPosStream', () {
      for (final marker in [
        'void _resetToSearchingOnRemoteCancel()',
        'void _decline()',
      ]) {
        final start = ctrl.indexOf(marker);
        expect(start, isNonNegative, reason: '$marker not found');
        final body = ctrl.substring(start, start + 2200);
        expect(body.contains('_startPosStream()'), isTrue,
            reason: '$marker returns to searching with the GPS stream '
                'stopped at accept time — dispatch sees a frozen car for '
                'the rest of the shift (audit #16)');
      }
    });
  });

  group('pause really pauses', () {
    test('_applyOffers is gated on _isPaused', () {
      final start = ctrl.indexOf('void _applyOffers(');
      final body = ctrl.substring(start, start + 400);
      expect(body.contains('if (_isPaused) return;'), isTrue,
          reason: 'the gate is the guarantee — SSE was never stopped by '
              'the old pause (audit #14)');
    });

    test('pause stops SSE, not only the backup poll', () {
      final start = ctrl.indexOf('void _pauseAvailability()');
      final body = ctrl.substring(start, start + 1200);
      expect(body.contains('_offerSseSub?.cancel()'), isTrue,
          reason: 'cancelling only _pollT left the primary channel live — '
              'cards kept arriving the whole "pause"');
      expect(body.contains('_sseReconnectTimer?.cancel()'), isTrue,
          reason: 'the reconnect timer would bring SSE back within 500 ms');
    });
  });

  group('offline without GPS still goes offline', () {
    test('_goOfflineBackend never early-returns on _pos == null', () {
      final start = ctrl.indexOf('void _goOfflineBackend()');
      final body = ctrl.substring(start, start + 900);
      expect(body.contains("LocalCache.get<double>('last_driver_lat')"),
          isTrue,
          reason: 'last-known coords carry the is_online: false — the '
              'early return left a ghost driver online (audit #15)');
      expect(body.contains('_pos == null) return'), isFalse,
          reason: 'the ghost-online early return is back');
    });
  });

  group('tips are computed on the real fare', () {
    test('no invented 23.0 fallback remains', () {
      expect(rating.contains('widget.fare > 0 ? widget.fare : 23.0'), isFalse,
          reason: 'percentages of a fiction are real dollars wrong '
              '(audit #18)');
      expect(rating.contains('if (fare > 0)'), isTrue,
          reason: 'unknown fare hides the percentage buttons');
    });

    test('a failed submit does not navigate as if it succeeded', () {
      final start = rating.indexOf('Future<void> _submit()');
      final body = rating.substring(start, start + 1100);
      final catchAt = body.indexOf('catch (_)');
      expect(catchAt, isNonNegative);
      final catchBody = body.substring(catchAt, catchAt + 600);
      expect(catchBody.contains('SnackBar'), isTrue,
          reason: 'the rating and the TIP are money — they do not fail '
              'silently');
      expect(catchBody.contains('return;'), isTrue,
          reason: 'the failed submit must not fall through to '
              '_navigateToHome as if it had been sent');
    });
  });
}
