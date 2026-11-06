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
      final body = ctrl.substring(start, start + 1500);
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
      final body = ctrl.substring(start, start + 2600);
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

  // Session 2026-08-09 (bis): two offer-lifecycle leaks the driver reported
  // — the yellow route staying painted after the card was gone, and the
  // "Go" chime replaying at every trip end.
  group('a dismissed offer never leaves its route behind', () {
    // Owner 2026-11-06: the offer's route is ONE gold→white line (a style
    // layer, _offerRouteLine) instead of two flat gold annotations — the
    // same leak rules, through the layer.
    test('the draw ticker takes the line off on !stillWanted()', () {
      final map =
          File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
      final start = map.indexOf('Future<void> _drawOfferLine(');
      expect(start, isNonNegative, reason: '_drawOfferLine not found');
      final body = map.substring(start, start + 2400);
      final tickerStart = body.indexOf('createTicker((_) {');
      expect(tickerStart, isNonNegative, reason: 'ticker not found');
      final guard = body.indexOf(
          'if (!mounted || !stillWanted() || !identical(map, _map)) {',
          tickerStart);
      expect(guard, isNonNegative, reason: 'ticker guard not found');
      final branch = body.substring(guard, guard + 400);
      expect(branch, contains('_offerRouteLine.hide(map)'),
          reason: 'a draw stopped by a dismiss must take its half-drawn '
              'line with it — the yellow route stayed with the card gone');
    });

    test('whatever kills the draw, every clear reaches the line', () {
      // A ticker killed before it notices the dismiss (_closePreview
      // disposes it, the 8 s draw timeout after an iOS background freeze)
      // used to orphan an annotation. The layer has no handle to lose: the
      // clear funnel hides it (awaited, so the next offer's first write
      // cannot land before the hide), the orphan sweep looks at it, and a
      // lost surface forgets it.
      final map = File('lib/screens/driver/driver_online_map.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final clear = map.substring(
          map.indexOf('Future<void> _clearRouteAnnotation() async {'),
          map.indexOf('Future<void> _restoreOfferPreviewOnFreshSurface()'));
      expect(clear, contains('await _offerRouteLine.hide(map);'));
      expect(clear, contains('_offerRouteLine.forget();'));
      final sweep = map.substring(
          map.indexOf('Future<void> _sweepPreviewOrphans() async {'));
      expect(sweep.substring(0, 900), contains('!_offerRouteLine.isShown &&'));
      for (final f in [
        'lib/screens/driver/driver_online_controller.dart',
        'lib/screens/driver/driver_online_widgets.dart',
      ]) {
        expect(File(f).readAsStringSync(), contains('_offerRouteLine.forget();'),
            reason: '$f resets the surface: the layer died with it');
      }
    });

    test('the offer draws the gold→white line, not flat gold annotations', () {
      final map = File('lib/screens/driver/driver_online_map.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final screen = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(screen,
          contains('final GradientRouteLine _offerRouteLine = GradientRouteLine('));
      final seq = map.substring(
          map.indexOf('Future<void> _offerCardTapSequence('),
          map.indexOf('Future<void> _previewOfferRouteWeb('));
      expect(seq, contains('final whole = _offerWholeLine();'));
      expect('_drawOfferLine('.allMatches(seq).length, 2,
          reason: 'car → pickup, then pickup → destination');
      expect(seq, isNot(contains('PolylineAnnotationOptions')));
      expect(map, isNot(contains('_drawGoldGlossRoute')));
    });

    test('the fresh-surface restore bails only when the preview is GONE', () {
      // All three mid-restore guards were typed `!= null` — but the restore
      // only RUNS when a preview is up, so it drew seg1 and returned: no
      // seg2, no pins, no reframe. They must be `== null` like the pin
      // guard between them (which was the only correct one).
      final map =
          File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
      final start =
          map.indexOf('Future<void> _restoreOfferPreviewOnFreshSurface(');
      expect(start, isNonNegative, reason: 'restore fn not found');
      final end = map.indexOf('Future<void> _setPickupAnnotation(', start);
      final body = map.substring(start, end > start ? end : start + 4500);
      expect(body.contains('_previewingOffer != null'), isFalse,
          reason: 'an != null guard inside the restore returns immediately '
              'after seg1 — inverted: it must bail only when the preview '
              'went AWAY (== null)');
      expect(body.contains('_previewingOffer == null'), isTrue,
          reason: 'the restore needs its dismiss bails pointing at GONE');
    });

    test('the first bail after pin creation sweeps the just-created pins',
        () {
      // X landing while PHASE 2's pin creates are in flight: the reject
      // clear already ran before the pins existed, so they used to float
      // over "Finding trips" with no card — the pin-shaped twin of the
      // orphaned gold line.
      final map =
          File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
      final start = map.indexOf('Future<void> _onOfferCardTap(');
      expect(start, isNonNegative, reason: '_onOfferCardTap not found');
      final pinCreate = map.indexOf('_prevDropoffAnnot = await pointMgr.create',
          start);
      expect(pinCreate, isNonNegative, reason: 'pin creation not found');
      final bail = map.indexOf(
          'if (!mounted || _previewingOffer == null) {', pinCreate);
      expect(bail, isNonNegative, reason: 'post-pin-creation bail not found');
      final bailBody = map.substring(bail, bail + 800);
      expect(bailBody.contains('_clearPickupDropoffAnnotations()'), isTrue,
          reason: 'the first bail after the pin creates must sweep them — '
              'the dismiss clear had no handle to pins that did not exist '
              'yet when it ran');
    });
  });

  group('trip end never replays the Go chime', () {    test('every return-to-online from a trip is a resume', () {
      final rate =
          File('lib/screens/driver/driver_rate_rider_screen.dart').readAsStringSync();
      final ratePush = rate.indexOf('pageBuilder: (_, anim, __) => DriverOnlineScreen(');
      expect(ratePush, isNonNegative,
          reason: 'rate-rider → DriverOnlineScreen not found');
      expect(
          rate.substring(ratePush, ratePush + 700).contains('resuming: true'),
          isTrue,
          reason: 'coming back from a trip is a RESUME, not a go-online — '
              'without it _armOnlineChime fires the "Go" sound at every '
              'trip end');

      final trip =
          File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
      final pushes =
          RegExp(r'DriverOnlineScreen\(').allMatches(trip).length;
      // Each push may carry other flags first (showCancelledNotice /
      // showReassignedNotice, one per line since 2026-10-28): what matters
      // is that `resuming: true` sits inside that constructor call.
      final resumes = RegExp(r'DriverOnlineScreen\(')
          .allMatches(trip)
          .where((m) {
            final close = trip.indexOf(')', m.end);
            return close > 0 &&
                trip.substring(m.end, close).contains('resuming: true');
          })
          .length;
      expect(resumes, pushes,
          reason: 'every DriverOnlineScreen the trip screen builds is a '
              'return from a trip the driver is still online for — each one '
              'must carry resuming: true or the chime replays');
    });
  });

  // Session 2026-08-09 (ter): the offer tap must show the card INSTANTLY.
  // The push payload carries every card field; the server only reconciles
  // after — replaces with the full offer, or takes the provisional card
  // down when the ride already went elsewhere.
  group('offer tap draws the card before the network answers', () {
    test('push_data carries every field the card reads', () {
      final dispatch =
          File('backend/routers/dispatch.py').readAsStringSync();
      final start = dispatch.indexOf('push_data = {');
      expect(start, isNonNegative, reason: 'push_data not found');
      final body = dispatch.substring(start, start + 1800);
      for (final field in [
        'rider_name',
        'pickup_lat',
        'pickup_lng',
        'dropoff_lat',
        'dropoff_lng',
        'dropoff_address',
        'vehicle_type',
        'driver_earnings',
        'offer_timeout_seconds',
      ]) {
        expect(body.contains('"$field"'), isTrue,
            reason: '"$field" missing from push_data — the tap cannot draw '
                'the card instantly without it');
      }
    });

    test('the tap builds and shows a provisional card before the lookup', () {
      final main_ = File('lib/main.dart').readAsStringSync();
      expect(main_.contains('_provisionalOfferFromPush'), isTrue,
          reason: 'the payload → card builder is gone');
      final start = main_.indexOf('if (provisional != null) {');
      expect(start, isNonNegative, reason: 'instant branch not found');
      final instant = main_.indexOf('_fetchPendingOffer(offerId, tripId)', start);
      final push = main_.indexOf('pushScreen(provisional)', start);
      final inject = main_.indexOf(
          'DriverOnlineScreen.deepLinkOfferNotifier.value = provisional',
          start);
      expect(instant, isNonNegative);
      // The card must go up BEFORE the first server round trip.
      expect(push == -1 || push < instant, isTrue,
          reason: 'the push happens after the lookup — back to seconds of '
              'nothing on tap');
      expect(inject == -1 || inject < instant, isTrue,
          reason: 'the injection happens after the lookup — same regression');
    });

    test('a reconcile-gone offer is removed, never while an accept runs', () {
      final screen =
          File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
      expect(screen.contains('removeOfferNotifier'), isTrue,
          reason: 'the removal bridge is gone');
      final start = screen.indexOf('void _applyRemoveInjectedOffer()');
      expect(start, isNonNegative, reason: 'removal handler not found');
      final body = screen.substring(start, start + 1300);
      expect(body.contains('_acceptedOfferIds.contains(oid)'), isTrue,
          reason: 'the driver can beat the reconcile to Accept — removing '
              'the card then would kill a ride that is already theirs');
      expect(body.contains('_clearAllAnnotations()'), isTrue,
          reason: 'removing the card without the route leaves the yellow '
              'line painted with no offer behind it');
    });
  });
}
