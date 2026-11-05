import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mapScreen = File('lib/screens/driver/scheduled_rides_map_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final mixin = File('lib/screens/driver/driver_rest_gate_mixin.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final service = File('lib/services/driver_rest_service.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  // The list page no longer claims (2026-11-03): the gate guards the map.
  for (final entry in {'map': mapScreen}.entries) {
    group('${entry.key} scheduled rest gate', () {
      final screen = entry.value;

      test('shares the home rest state and disposes its listener', () {
        expect(screen, contains('DriverRestGate'));
        expect(screen, contains('initDriverRestGate()'));
        expect(screen, contains('disposeDriverRestGate()'));
      });

      test('keeps cards visible but swaps accept for the grey timer', () {
        expect(screen, contains('driverIsResting'));
        expect(screen, contains('driverRestLabel'));
        // The grey lives in the offer-style Reservar (2026-11-04).
        expect(screen, contains('resting: driverIsResting,'));
        expect(
            File('lib/screens/driver/reservation_offer_card.dart')
                .readAsStringSync(),
            contains('const Color(0xFF6B6B70)'));
        expect(screen, contains('showDriverRestRemaining'));
      });

      test('handles the server refusal as rest, not out of state', () {
        expect(screen, contains("e.message == 'shift_rest_required'"));
        expect(screen, contains('syncDriverRestRefusal()'));
      });
    });
  }

  test('one timer per screen restores accept when rest expires', () {
    expect(mixin, contains('Timer.periodic(const Duration(seconds: 1)'));
    expect(mixin, contains('DriverRestService.set(null)'));
    expect(mixin, contains('DriverRestService.refresh()'));
    expect(mixin, contains('_driverRestSyncTicks >= 15'));
  });

  test('rest persists locally and follows the server authority', () {
    expect(service, contains('prefs.setInt('));
    expect(service, contains('driver_rest_until'));
    expect(service, contains("result.containsKey('rest_until')"));
    expect(service, contains('ApiService.canGoOnline()'));
  });
}
