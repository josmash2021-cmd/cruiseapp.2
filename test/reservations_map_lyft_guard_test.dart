import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03 (Lyft's Scheduled rides, three photos): Lyft-style
/// cards in the list; a tapped ride floats like an offer card over its full
/// route with Reservar and an X; Reservar asks "¿Reservar este viaje?" on a
/// glass card first, and only its Reservar takes the ride.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final map = read('lib/screens/driver/scheduled_rides_map_screen.dart');
  final confirm = read('lib/screens/driver/reserve_confirm_sheet.dart');

  test('the card: pickup with day and time, the ride\'s own min · mi, the '
      'rider verified with ★', () {
    expect(map, contains('Widget _rideCard(Map<String, dynamic> trip, {bool floating = false}) {'));
    expect(map, contains("pickupTitle: at == null ? '' : _whenShort(s, at, isEs),"));
    expect(map, contains("dropTitle: '\$tripMin min · \${tripMi.toStringAsFixed(1)} mi',"));
    expect(map, contains("var tripMin = (trip['duration_minutes'] as num?)?.round();"));
    expect(map, contains('s.faceVerified,'));
  });

  test('a tapped ride floats with Reservar; an X closes it', () {
    expect(map, contains(': _buildFloatingDetail(s, _selected!),'));
    expect(map, contains('child: _buildDismissX(),'));
    expect(map, isNot(contains('_buildDismissPill(')));
    expect(map, contains(': () => _confirmReserve(trip),'));
  });

  test('Reservar asks first; only the confirm card\'s Reservar claims', () {
    final i = map.indexOf('Future<void> _confirmReserve(');
    final body = map.substring(i, i + 500);
    expect(body, contains('await showReserveConfirm('));
    expect(body, contains('if (!ok || !mounted) return;'));
    expect(body, contains('await _claimTrip(tripId);'));
    expect(confirm, contains("key: const ValueKey('reserve-confirm-ok'),"));
    expect(confirm, contains('close(true);'));
    expect(confirm, contains('filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),'));
  });

  test('the confirm card says only what is true in Cruise', () {
    expect(confirm, contains('s.resvGoOnlineBold(_time(goBy))'));
    expect(confirm, contains('s.resvMissed'));
    expect(confirm, contains('s.resvCancelInfo'));
  });
}
