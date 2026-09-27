import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the offer-preview route lifecycle (user report 2026-09-26:
/// "cuando el driver recibe una oferta en el mapa queda la ruta dibujada de
/// la oferta pasada, o cuando se rechaza queda dibujada").
///
/// Every dismiss path already funnels through `_clearAllAnnotations`, but
/// the preview is a multi-await cinematic: a handle created mid-flight could
/// land after its clear ran, and a stuck `_isCardAnimating` latch vetoed
/// every later offer's preview so the OLD line outlived the NEW card. The
/// pins below keep the three fixes honest.
void main() {
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();

  group('the cinematic latch can never stick', () {
    test('_onOfferCardTap releases _isCardAnimating in a finally', () {
      final start = map.indexOf('Future<void> _onOfferCardTap(');
      expect(start, isNonNegative);
      final body = map.substring(start, start + 900);
      expect(body.contains('try {'), isTrue);
      expect(
          body.contains('finally') && body.contains('_isCardAnimating = false'),
          isTrue,
          reason: 'a throw mid-sequence used to leave the latch on forever — '
              'every later offer preview was vetoed and the old route stayed '
              'on the map under the new card');
    });

    test('the auto-trigger latch arms only when the trigger actually runs',
        () {
      final start = map.indexOf('void _autoTriggerRoutePreview(');
      expect(start, isNonNegative);
      final body = map.substring(start, start + 1400);
      final guard = body.indexOf('_isCardAnimating)');
      final arm = body.indexOf('_lastAutoTriggeredOfferId = oid;');
      expect(guard, isNonNegative);
      expect(arm, greaterThan(guard),
          reason: 'arming before the post-frame guard meant a skipped '
              'trigger never retried — the new offer never drew and the old '
              'route stayed');
    });
  });

  group('the orphan sweep', () {
    test('exists, gated on no-preview-open, clearing through the funnel', () {
      expect(map.contains('Future<void> _sweepPreviewOrphans()'), isTrue);
      final start = map.indexOf('Future<void> _sweepPreviewOrphans()');
      final body = map.substring(start, start + 900);
      expect(body.contains('_previewingOffer != null'), isTrue,
          reason: 'a preview on screen owns its annotations — the sweep '
              'never touches a live one');
      expect(body.contains('_clearAllAnnotations()'), isTrue);
    });

    test('runs from the offer heartbeat and after reject', () {
      expect(ctrl.contains('unawaited(_sweepPreviewOrphans());'), isTrue,
          reason: 'the poll/SSE heartbeat sweeps survivors of any async '
              'race within seconds');
      final rej = ctrl.indexOf('Future<void> _rejectOffer(');
      expect(rej, isNonNegative);
      final rejBody = ctrl.substring(rej, rej + 2600);
      expect(rejBody.contains('_sweepPreviewOrphans()'), isTrue,
          reason: 'reject sweeps immediately — the route must not outlive '
              'the card by even a frame');
    });
  });
}
