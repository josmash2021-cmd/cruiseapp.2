import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-10-29 (owner: a new reservation never appeared while Scheduled
/// rides was open, and the push did not arrive either). The list must not
/// depend on the push alone.
void main() {
  final src = File('lib/screens/driver/scheduled_rides_map_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the open list refreshes itself on a timer', () {
    expect(src, contains('_availPollTimer = Timer.periodic(_availPollEvery'));
    expect(src, contains('_availPollTimer?.cancel();'),
        reason: 'the poll dies with the screen');
    expect(src, contains('AppLifecycleState.resumed'),
        reason: 'no polling while the app is in the background');
  });

  test('the poll replays the area the driver is looking at', () {
    expect(src,
        contains('force: true, lat: _lastQLat, lng: _lastQLng, bbox: _lastQBbox'));
    final load = src.substring(src.indexOf('Future<void> _loadAvailable('));
    expect(load.substring(0, 900), contains('_lastQBbox = bbox;'));
  });

  test('a refresh never flashes the cached list over fresh data', () {
    expect(src, contains('if (cached != null && mounted && !_freshLoaded) {'));
  });
}
