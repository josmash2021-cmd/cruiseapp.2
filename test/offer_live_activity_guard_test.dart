import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dead-offer / Live Activity fixes (session 2026-08-08).
///
/// The audit found four silent-failure holes in the offer → push / island →
/// reappear-on-return chain, so the guard has five source-grep sections:
///   1. _rejectOffer syncs the Live Activity — a rejected offer used to
///      stay on the lock screen until the 5s clock backstop.
///   2. The SSE and poll handlers no longer early-return on an empty list:
///      that skipped the expiry pass in _applyOffers and left dead offers
///      painted in the card and the Dynamic Island forever.
///   3. The lifecycle resume forces _startPolling — pause cancels _pollT
///      and nothing retried a debounced start, so a quick background →
///      foreground flip left the driver with no SSE and no poll.
///   4. registerLiveActivityToken retries once on failure — a single
///      non-2xx used to leave the island unpainted for the session.
///   5. The push-token hook logs a dropped empty kind/token instead of
///      discarding it mute.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ctrl =
      File('lib/screens/driver/driver_online_controller.dart').readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final liveActivity =
      File('lib/services/live_activity_service.dart').readAsStringSync();

  group('_rejectOffer clears the island', () {
    test('_rejectOffer calls _syncOfferLiveActivity', () {
      final start = ctrl.indexOf('Future<void> _rejectOffer(');
      expect(start, isNonNegative, reason: '_rejectOffer not found');
      final body = ctrl.substring(start, start + 3500);
      expect(body.contains('_syncOfferLiveActivity()'), isTrue,
          reason: 'a rejected offer stays on the lock screen / Dynamic '
              'Island until the clock backstop — mirror _dropPendingOffer');
    });
  });

  group('empty offer lists still expire the pending ones', () {
    test('no bare `if (visible.isEmpty) return;` remains before _applyOffers', () {
      expect(ctrl.contains('if (visible.isEmpty) return;'), isFalse,
          reason: 'skipping _applyOffers on an empty list leaves a dead '
              'offer painted in the card and the Live Activity forever — '
              'the expiry pass inside _applyOffers must always run');
    });

    test('both SSE and poll handlers feed visible into _applyOffers', () {
      expect(
          RegExp(r'_applyOffers\(visible\)').allMatches(ctrl).length,
          greaterThanOrEqualTo(2),
          reason: 'the SSE listener and the poll must both run the expiry '
              'pass, even when the list arrives empty');
    });
  });

  group('resume forces the poll/SSE restart', () {
    test('_startPolling accepts a force flag that skips the debounce', () {
      expect(ctrl.contains('void _startPolling({bool force = false})'), isTrue,
          reason: 'the 1s debounce kills the restart after a quick resume '
              'and nothing retries it');
      final start = ctrl.indexOf('void _startPolling(');
      final body = ctrl.substring(start, start + 700);
      expect(body.contains('!force'), isTrue,
          reason: 'force must bypass the debounce check');
    });

    test('the lifecycle resume path forces the start', () {
      final resume = screen.indexOf('AppLifecycleState.resumed');
      expect(resume, isNonNegative, reason: 'resume handler not found');
      final window = screen.substring(resume, resume + 2500);
      expect(window.contains('_startPolling(force: true)'), isTrue,
          reason: 'pause cancels _pollT; a debounced _startPolling on '
              'resume is never retried — the driver loses SSE and poll');
    });
  });

  group('registerLiveActivityToken retries once', () {
    test('a non-2xx or network error schedules a delayed retry', () {
      final start = api.indexOf('registerLiveActivityToken({');
      expect(start, isNonNegative,
          reason: 'registerLiveActivityToken not found');
      final body = api.substring(start, start + 2200);
      expect(body.contains('isRetry'), isTrue,
          reason: 'the retry must not schedule another retry');
      expect(body.contains('Future.delayed(const Duration(seconds: 10)'),
          isTrue,
          reason: 'a single failed save left the island unpainted for the '
              'whole session — one delayed retry is the fix');
    });
  });

  group('the push-token hook never discards mute', () {
    test('empty kind or token is logged', () {
      final hook = liveActivity.indexOf("call.method == 'pushToken'");
      expect(hook, isNonNegative, reason: 'pushToken hook not found');
      final body = liveActivity.substring(hook, hook + 900);
      expect(body.contains('debugPrint'), isTrue,
          reason: 'an empty kind/token from the native side was dropped '
              'silently — the island never registers and nothing says why');
    });
  });

  // Session 2026-08-09: tapping the offer push on iOS landed on "Finding
  // trips" with no card. Root cause: SSE only streams offers cut AFTER
  // subscribe (no backend snapshot) and the 5s poll stands down the moment
  // SSE is active — so an offer created while iOS had the socket dead was
  // never delivered by either channel. Two guards pin the fix.
  group('offer cut while SSE was dead still reaches the card', () {
    test('_startPolling fires a one-shot _poll on every (re)start', () {
      final start = ctrl.indexOf('void _startPolling(');
      expect(start, isNonNegative, reason: '_startPolling not found');
      final body = ctrl.substring(start, start + 1800);
      final sse = body.indexOf('_connectSse();');
      expect(sse, isNonNegative, reason: '_connectSse call not found');
      final oneShot = body.indexOf('_poll();', sse);
      expect(oneShot, isNonNegative,
          reason: 'without a one-shot fetch, an offer created while the SSE '
              'socket was dead (iOS background/killed) is never replayed — '
              'SSE sends no snapshot and the timer skips while SSE is up');
    });

    test('a late lookup answer is injected, not dropped', () {
      final main_ = File('lib/main.dart').readAsStringSync();
      final start = main_.indexOf('lookup.then((result)');
      expect(start, isNonNegative, reason: 'late-lookup handler not found');
      final body = main_.substring(start, start + 900);
      expect(
          body.contains('DriverOnlineScreen.deepLinkOfferNotifier.value = late'),
          isTrue,
          reason: 'the screen goes up bare when the lookup outruns its '
              'budget; an offer found after that must still be handed over, '
              'not dropped to a bare "Finding trips" screen');
    });
  });
}
