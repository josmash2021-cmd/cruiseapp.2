import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner report 2026-10-29: drivers who went offline kept showing as
/// active. Offer polling wrote the location with is_online defaulting to
/// true and was restarted while offline (remote-cancel reset). Polling is
/// an online-only channel.
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();

  test('_startPolling refuses to run while offline', () {
    final i = ctrl.indexOf('void _startPolling({bool force = false}) {');
    expect(i, isNonNegative);
    final head = ctrl.substring(i, i + 700);
    expect(head, contains('if (!_driverOnline) {'));
    expect(head, contains('_pollT?.cancel();'));
  });

  test('_poll never runs (nor re-registers online) for an offline driver', () {
    final i = ctrl.indexOf('Future<void> _poll() async {');
    expect(i, isNonNegative);
    final head = ctrl.substring(i, i + 400);
    expect(head, contains('if (!_driverOnline || _wentOffline) return;'));
    final guard = head.indexOf('if (!_driverOnline || _wentOffline) return;');
    final recover = ctrl.indexOf('_goOnlineBackend(); // Re-establish online status', i);
    expect(recover, greaterThan(i + guard),
        reason: 'the driverId recovery that calls _goOnlineBackend must sit '
            'behind the offline guard');
  });
}
