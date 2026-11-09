import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider trip Live Activity widget (user spec 2026-09-17).
///
/// The widget is Swift — it builds only in the Codemagic iOS build — so this
/// pins the source discipline that made the lock-screen card what it is:
///   1. The car is a GLYPH on a gold disc (the top-down PNG read as a pale
///      box at bar size — "en vez de un cuadrado, un carrito").
///   2. The destination end is the dropoff pin glyph, not a ring.
///   3. The bar and the island minutes repaint every 1 s (30 s made the car
///      jump twice a minute — "paso a paso") and the minutes ceil like the
///      in-app ETA.
void main() {
  final swift = File('ios/CruiseLiveActivity/CruiseRideLiveActivityWidget.swift')
      .readAsStringSync();

  test('the bar car is a glyph on a gold disc, never the pale PNG box', () {
    expect(swift.contains('Image(systemName: "car.fill")'), isTrue,
        reason: 'an SF glyph can never fail to render — the asset-catalog '
            'PNG read as a square at bar size');
    expect(swift.contains('Image(state.carImage'), isFalse,
        reason: 'the top-down PNG at 40 px read as a gray square');
  });

  test('the destination end is the dropoff pin glyph, not a ring', () {
    expect(swift.contains('Image(systemName: "mappin.circle.fill")'), isTrue);
    expect(swift.contains('.strokeBorder(rideGold'), isFalse,
        reason: 'the hollow ring is gone');
  });

  test('bar and island minutes repaint every second and ceil honestly', () {
    final ticks = RegExp(r'TimelineView\(\.periodic\(from: \.now, by: 1\)')
        .allMatches(swift)
        .length;
    expect(ticks, greaterThanOrEqualTo(2),
        reason: 'both the route bar and the ETA minutes tick at 1 s — '
            'the car glides, the minutes never sit stale for half a minute');
    expect(swift.contains('by: 30'), isFalse,
        reason: 'the 30 s tick made the car jump twice a minute');
    expect(swift.contains('.rounded(.up)'), isTrue,
        reason: 'ceil like the in-app ETA — flooring read 1.9 min as "1 min"');
  });

  group('the card dies with the trip (user report 2026-09-23)', () {
    final ctrl = File('lib/controllers/rider_tracking_controller.dart')
        .readAsStringSync();
    final buttons = File('lib/widgets/tracking/trip_action_buttons.dart')
        .readAsStringSync();

    test('the end is UNCONDITIONAL — it kills cards from previous sessions', () {
      final start = ctrl.indexOf(
          'void _syncRideLiveActivity({bool end = false,');
      expect(start, isNonNegative);
      final body = ctrl.substring(start, start + 700);
      expect(body.contains('if (_laStarted)'), isFalse,
          reason: 'the _laStarted gate made the end a no-op for a card '
              'started by a PREVIOUS app session — the orphaned card then '
              'outlived the trip on the lock screen');
      expect(body.contains('LiveActivityService.endRide()'), isTrue,
          reason: 'the native end clears every ride activity either way');
    });

    test('the rider\'s own cancel ends the card NOW, not on the next poll', () {
      final start = buttons.indexOf('_finishCancelTransition() async {');
      expect(start, isNonNegative);
      final body = buttons.substring(start, start + 500);
      expect(body.contains('_syncRideLiveActivity(end: true)'), isTrue);
    });

    test('past the ETA the card goes stale and says so (2026-10-02/11-09)',
        () {
      final appDelegate =
          File('ios/Runner/AppDelegate.swift').readAsStringSync();
      // Both RIDE paths carry the bounded staleDate. It does NOT remove
      // the card (iOS keeps an activity up to 12 h): it turns it stale,
      // and the widget then reads "Abre Cruise para ver tu viaje" instead
      // of a finished trip's minutes. The driver's presence island keeps
      // its own discipline and is out of scope here.
      expect(
          'dropoffAt.addingTimeInterval(90 * 60)'.allMatches(appDelegate).length,
          2);
      expect(appDelegate.contains('self-terminates'), isFalse,
          reason: 'staleDate never ended a card — the comment lied');
      expect(swift.contains('if #available(iOS 16.2, *) { return context.isStale }'),
          isTrue);
      expect(swift.contains('"Abre Cruise para ver tu viaje"'), isTrue);
      expect('stale: rideIsStale(context)'.allMatches(swift).length, 3,
          reason: 'lock screen, expanded island and the minutes slot');
    });

    test('an orphan card comes down when the app opens (2026-11-09)', () {
      final service =
          File('lib/services/live_activity_service.dart').readAsStringSync();
      final main = File('lib/main.dart').readAsStringSync();
      final api = File('lib/services/api_service.dart').readAsStringSync();
      // Cold start and every resume.
      expect('unawaited(LiveActivityService.endOrphanRideCard());'
              .allMatches(main)
              .length,
          2);
      // Only when this phone showed a card, and only on the server's word:
      // a failed read (redeploy 502, timeout) is null and changes nothing.
      final body = service.substring(
          service.indexOf('static Future<void> endOrphanRideCard()'));
      expect(body.contains('if (!await rideCardMaybeUp()) return;'), isTrue);
      expect(
          body.contains(
              'if (status == null || _kRideCardStatuses.contains(status)) return;'),
          isTrue);
      expect(api.contains('static Future<String?> activeTripStatusOrNull()'),
          isTrue);
      expect(api.contains("if (res.statusCode != 200) return null;"), isTrue);
      // The flag goes up with the card and down with every end.
      final ctrl = File('lib/controllers/rider_tracking_controller.dart')
          .readAsStringSync();
      expect(ctrl.contains('unawaited(LiveActivityService.markRideCard(true));'),
          isTrue);
      expect(service.contains('unawaited(markRideCard(false));'), isTrue);
    });
  });

  group('the card as Lyft shows it (owner 2026-11-09)', () {
    final attrs =
        File('ios/CruiseLiveActivity/CruiseRideActivityAttributes.swift')
            .readAsStringSync();
    final appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final dart =
        File('lib/services/live_activity_service.dart').readAsStringSync();
    final ctrl = File('lib/controllers/rider_tracking_controller.dart')
        .readAsStringSync();

    test('how long in big, then the plate box and the car', () {
      expect(swift.contains('"Llega en \\(mins) min"'), isTrue);
      expect(swift.contains('"\\(name) llegó"'), isTrue);
      expect(swift.contains('"Llegas en \\(mins) min"'), isTrue);
      expect(swift.contains('private struct RideCarRow: View'), isTrue);
      expect(
          swift.contains(
              '.background(RoundedRectangle(cornerRadius: 6).fill(Color.white))'),
          isTrue,
          reason: 'the plate sits in a white box');
      expect(swift.contains('Tu driver'), isFalse,
          reason: '"conductor" in Spanish, never "driver"');
    });

    test('the lock screen stays under its 160 pt', () {
      expect(swift.contains('private var carW: CGFloat { compact ? 26 : 30 }'),
          isTrue);
      expect(swift.contains('.padding(14)'), isTrue);
      expect(swift.contains('if !compact { Spacer(minLength: 0) }'), isFalse);
    });

    test('carLine and plate ride every hop: Dart → channel → state', () {
      expect(dart.contains("'carLine': carLine,"), isTrue);
      expect(dart.contains("'plate': plate,"), isTrue);
      expect('carLine: args?["carLine"] as? String ?? ""'
              .allMatches(appDelegate)
              .length,
          2);
      expect(
          attrs.contains(
              'carLine = try c.decodeIfPresent(String.self, forKey: .carLine) ?? ""'),
          isTrue,
          reason: 'an activity from an older build still decodes');
      expect(ctrl.contains('carLine: carLine, plate: plate,'), isTrue);
    });

    test('Android says the same, without "driver" in Spanish', () {
      expect(ctrl.contains("'Cruise · Tu driver llegó'"), isFalse);
      expect(ctrl.contains("es ? '\$who llega en \$etaMin min'"), isTrue);
      expect(ctrl.contains("es ? 'Busca el \$carText'"), isTrue);
    });
  });
}
