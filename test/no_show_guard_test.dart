// The red no-show slider (owner design 2026-11-02): the driver's slide
// reaches the server, and the rider is told why the trip ended — never
// the amount.
import 'dart:io';

import 'package:cruise_app/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final rider =
      File('lib/controllers/rider_tracking_controller.dart').readAsStringSync();

  test('the slider calls the server, then leaves like any ended trip', () {
    expect(trip.contains('onNoShow: _reportNoShow,'), isTrue);
    expect(trip.contains('await ApiService.reportNoShow(widget.tripId);'), isTrue);
  });

  test('the rider hears why, at the pickup and at the stop', () {
    expect(rider.contains("cancellationReason.contains('no_show:stop')"), isTrue);
    expect(rider.contains('S.of(context).riderNoShowPickupMsg'), isTrue);
  });

  test('the messages never carry an amount', () {
    for (final code in ['es', 'en']) {
      final s = S(Locale(code));
      for (final m in [s.riderNoShowPickupMsg, s.riderNoShowStopMsg]) {
        expect(m.contains(r'$'), isFalse, reason: m);
        expect(RegExp(r'\d').hasMatch(m), isFalse, reason: m);
      }
    }
  });
}
