import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver pickup-PIN card (spec 2026-09-12, mockup
/// docs/mockups/driver_trip_current_mockup.html):
///
///   1. The card exists ONLY in the arrived/waiting-for-rider stage — the
///      same phase condition that routes `_buildCurrentPhaseWidget` to
///      `_buildSlideWaitingForRider()` — and sits right after the pickup
///      address card, before the Spacer.
///   2. 4 letter boxes on a letters keyboard (user spec 2026-09-19 — the
///      code went from 4 digits to 4 letters), 4-char cap, uppercase as you
///      type, auto-submit when the 4th char lands.
///   3. ApiService.confirmPickupPin posts {pin} to /trips/{id}/pickup-pin/confirm.
///   4. Result handling: 200 sets `_riderConfirmedPickup` locally (the pill
///      morphs into Start Ride even if the Firestore flag lands later),
///      403 = red shake + pickupCodeInvalid with cleared boxes, 429 =
///      pickupCodeTooManyAttempts with locked input.
///   5. The PIN is MANDATORY (user spec 2026-09-16): it is the only unlock
///      for Start Ride — the 90 s `_waitingOverride` fallback is gone and
///      the rider's proximity FOUND no longer writes the confirm flag.
///
/// The screen needs a live Mapbox surface, so this pins the source discipline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();

  /// Extracts [maxLen] chars starting at [signature].
  String bodyOf(String signature, {int maxLen = 6500}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, start + maxLen);
  }

  group('card shows only in the waiting-for-rider stage', () {
    test('visibility getter mirrors the _buildSlideWaitingForRider phase', () {
      final m = RegExp(r'bool get _showPickupPinCard =>\s*([^;]+);')
          .firstMatch(src);
      expect(m, isNotNull, reason: '_showPickupPinCard getter not found');
      final cond = m!.group(1)!;
      expect(cond.contains('_arrivedConfirmed'), isTrue,
          reason: 'never show the PIN before arriving');
      expect(cond.contains('!_rideStarted'), isTrue,
          reason: 'never show the PIN after the ride started');
      expect(cond.contains('!_riderConfirmedPickup'), isTrue,
          reason: 'once confirmed the pill is already Start Ride');
      expect(cond.contains('_waitingOverride'), isFalse,
          reason: 'user spec 2026-09-16: the PIN is mandatory — the 90 s '
              'fallback that also unlocked Start Ride is gone');
      // Same four flags gate the phase router.
      final router = bodyOf('Widget _buildCurrentPhaseWidget()', maxLen: 900);
      expect(router.contains('_buildSlideWaitingForRider()'), isTrue);
    });

    test('the 90 s override is gone — the PIN is the only Start Ride unlock',
        () {
      expect(src.contains('_waitingOverride'), isFalse,
          reason: 'user spec 2026-09-16: the rider must give the code; no '
              'timer may morph the pill into Start Ride');
    });

    test('placed right after the pickup address card, before the Spacer', () {
      final pickupCard = src.indexOf('// ── Pickup address card ─');
      final pinCard = src.indexOf('_buildPickupPinCard(),');
      final spacer = src.indexOf('const Spacer(),', pickupCard);
      expect(pickupCard, isNonNegative, reason: 'pickup address card not found');
      expect(pinCard, isNonNegative, reason: 'PIN card not in the main Column');
      expect(pinCard, greaterThan(pickupCard),
          reason: 'mockup: PIN card goes right after the pickup address card');
      expect(spacer, greaterThan(pinCard),
          reason: 'PIN card must sit before the Spacer, not in the bottom zone');
    });
  });

  group('4 boxes, letters keyboard, auto-submit at 4 chars', () {
    test('onChanged submits when the 4th char lands', () {
      final body = bodyOf('void _onPinChanged(String value)', maxLen: 500);
      expect(body.contains('value.length == 4'), isTrue,
          reason: 'auto-submit trigger missing');
      expect(body.contains('_submitPickupPin()'), isTrue);
    });

    test('field takes LETTERS (digits allowed for the cutover), capped at 4, '
        'uppercase as you type (user spec 2026-09-19)', () {
      final body = bodyOf('Widget _buildPickupPinCard()');
      expect(body.contains('TextInputType.number'), isFalse,
          reason: 'the code is 4 letters now — the numeric pad is gone');
      expect(body.contains('FilteringTextInputFormatter.digitsOnly'), isFalse);
      expect(body.contains('TextInputType.visiblePassword'), isTrue,
          reason: 'letters keyboard without suggestions/autocorrect');
      expect(
          body.contains(
              "FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]'))"),
          isTrue,
          reason: 'letters; digits still pass so pre-cutover numeric codes '
              'can be typed during the overlap');
      expect(body.contains('next.text.toUpperCase()'), isTrue,
          reason: 'backend stores A-Z only — uppercase as you type');
      expect(body.contains('LengthLimitingTextInputFormatter(4)'), isTrue);
      expect(body.contains('List.generate(4,'), isTrue,
          reason: 'exactly 4 code boxes');
      expect(body.contains('0xFFE8C547'), isTrue,
          reason: 'mockup gold accent #E8C547');
      expect(body.contains('s.pickupCodeTitle'), isTrue);
      expect(body.contains('s.pickupCodeAskRider'), isTrue);
    });
  });

  group('API wiring', () {
    test('confirmPickupPin posts {pin} to /pickup-pin/confirm', () {
      final m = RegExp(r'confirmPickupPin\(\s*int tripId, String pin\)')
          .firstMatch(api);
      expect(m, isNotNull, reason: 'ApiService.confirmPickupPin not found');
      final body = api.substring(m!.start, m.start + 800);
      expect(body.contains('.post('), isTrue);
      expect(body.contains('/trips/\$tripId/pickup-pin/confirm'), isTrue);
      expect(body.contains("jsonEncode({'pin': pin})"), isTrue);
    });

    test('screen calls it with widget.tripId', () {
      expect(
          src.contains('ApiService.confirmPickupPin(widget.tripId, pin)'),
          isTrue);
    });
  });

  group('result handling', () {
    test('200 flips _riderConfirmedPickup locally + haptic + SnackBar', () {
      final body = bodyOf('Future<void> _submitPickupPin() async {');
      expect(body.contains('_riderConfirmedPickup = true'), isTrue,
          reason: 'the pill must morph into Start Ride immediately, '
              'not a Firestore round-trip later');
      expect(body.contains('HapticService.heavyImpact()'), isTrue);
      expect(body.contains('pickupCodeMatched'), isTrue);
    });

    test('403 → red shake + pickupCodeInvalid, boxes cleared for retry', () {
      final body = bodyOf('Future<void> _submitPickupPin() async {');
      expect(body.contains('e.statusCode == 403'), isTrue);
      expect(body.contains('_pinShakeCtrl.forward(from: 0)'), isTrue,
          reason: 'invalid code must shake the boxes');
      expect(body.contains('_pinCtrl.clear()'), isTrue,
          reason: 'boxes clear so the driver can retype');
      // The red error text renders in the card builder.
      final card = bodyOf('Widget _buildPickupPinCard()');
      expect(card.contains('s.pickupCodeInvalid'), isTrue);
    });

    test('429 → pickupCodeTooManyAttempts + input locked for a while', () {
      final body = bodyOf('Future<void> _submitPickupPin() async {');
      expect(body.contains('e.statusCode == 429'), isTrue);
      expect(body.contains('_pinLocked = true'), isTrue);
      final card = bodyOf('Widget _buildPickupPinCard()');
      expect(card.contains('s.pickupCodeTooManyAttempts'), isTrue);
      expect(card.contains('enabled: !_pinLocked'), isTrue,
          reason: 'locked-out input must not open the keyboard');
    });

    test('409/503/network → neutral SnackBar, retry stays possible', () {
      final body = bodyOf('Future<void> _submitPickupPin() async {');
      expect(body.contains('networkError'), isTrue);
      expect(body.contains('_pinSubmitting = false'), isTrue,
          reason: 'the submitting flag must reset or retry is impossible');
    });

    test('the Firestore flag listener stays untouched', () {
      expect(src.contains("data['rider_confirmed_pickup'] == true"), isTrue,
          reason: 'the listener remains the cross-device source of truth — '
              'the backend PIN-confirm writes that flag');
    });
  });

  group('keyboard dismissal (fix 2026-09-19)', () {
    test('tap on any empty area unfocuses the PIN field', () {
      // The iOS number pad has no dismiss key — without this wrapper the
      // keyboard stayed up until the 4th digit landed.
      final m = RegExp(
              r'child: GestureDetector\(\s*behavior: HitTestBehavior\.translucent,\s*onTap: \(\) \{\s*if \(_pinFocusNode\.hasFocus\) _pinFocusNode\.unfocus\(\);')
          .firstMatch(src);
      expect(m, isNotNull,
          reason: 'tap-outside-to-dismiss wrapper around the Scaffold is '
              'missing — the numeric pad cannot be closed on iOS');
    });

    test('4-digit auto-submit still unfocuses', () {
      final body = bodyOf('void _onPinChanged(String value)', maxLen: 500);
      expect(body.contains('_pinFocusNode.unfocus()'), isTrue);
    });
  });
}
