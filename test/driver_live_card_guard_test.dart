import 'dart:io';

import 'package:cruise_app/services/driver_trip_island.dart';
import 'package:flutter_test/flutter_test.dart';

/// The driver's lock-screen card / Dynamic Island, as the owner-approved
/// drawing (2026-11-09, https://claude.ai/artifact/DoSsRsv83hW7ULJWJgoetK
/// §5): in big what the driver does next and how long, the address (or the
/// pickup code to ask for), the leg's bar, and the closed island with the
/// number that matters now. The widget is Swift — it builds only in the
/// Codemagic iOS build — so its source is pinned here.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final widget = read('ios/CruiseLiveActivity/CruiseLiveActivityBundle.swift');
  final attrs = read('ios/CruiseLiveActivity/CruiseActivityAttributes.swift');
  final appDelegate = read('ios/Runner/AppDelegate.swift');
  final service = read('lib/services/live_activity_service.dart');
  final ctrl = read('lib/screens/driver/driver_online_controller.dart');
  final trip = read('lib/screens/driver/driver_trip_accept_screen.dart');
  final nav = read('lib/screens/driver/driver_nav_view.dart');

  test('every moment of the drawing has its line', () {
    for (final line in [
      r'"Buscando viajes"',
      r'"En línea · \(dur)"',
      r'"Recoge a \(who) en \(mins) min"',
      r'"Esperando a \(who)"',
      r'"Parada en \(mins) min"',
      r'"Deja a \(who) en \(mins) min"',
      r'"Ganaste \(s.tripEarned)"',
      r'"Espera gratis "',
      r'"código de recogida"',
    ]) {
      expect(widget.contains(line), isTrue, reason: line);
    }
    // No minutes known yet → what to do, never "Llegando".
    expect(widget.contains(r'"Recoge a \(who)"'), isTrue);
  });

  test('lock screen and open island draw the driver card', () {
    expect(widget.contains('DriverCard(state: context.state)'), isTrue);
    expect(widget.contains('DriverCard(state: state, compact: true)'), isTrue);
    // The closed island: minutes, the wait clock, "+$14.20", today's money.
    expect(widget.contains(r'return "\(m) min"'), isTrue);
    expect(widget.contains('"+" + state.tripEarned'), isTrue);
    expect(widget.contains('state.status == "online" && !state.earnedToday.isEmpty'),
        isTrue);
    // The offer card stays as it was.
    expect(widget.contains('OfferCard(state: context.state)'), isTrue);
  });

  test('the new fields decode from an older card or a server push', () {
    for (final f in [
      'phase', 'riderName', 'riderRating', 'riderPhotoUrl', 'address',
      'waitRate', 'earnedToday', 'tripsToday', 'tripEarned',
    ]) {
      expect(
          attrs.contains(
              '$f = try c.decodeIfPresent(String.self, forKey: .$f) ?? ""'),
          isTrue,
          reason: f);
    }
    for (final f in ['legStart', 'legEnd', 'freeWaitEnd', 'onlineSince']) {
      expect(attrs.contains('$f = try c.decodeIfPresent(Date.self, forKey: .$f)'),
          isTrue,
          reason: f);
    }
  });

  test('Dart → channel → card, with a fallback for older binaries', () {
    expect(appDelegate.contains('case "driverState":'), isTrue);
    expect(appDelegate.contains('func driverState(_ state: CruiseActivityAttributes.ContentState)'),
        isTrue);
    expect(appDelegate.contains('"Nueva oferta de viaje" : "New ride offer"'),
        isTrue,
        reason: 'the offer alert in the driver\'s language');
    expect(service.contains("_channel.invokeMethod('driverState'"), isTrue);
    final fallback = service.substring(
        service.indexOf('} on MissingPluginException {'));
    expect(
        fallback
            .substring(0, 80)
            .contains("await _invoke('update', status);"),
        isTrue);
  });

  test('who paints what: the shift, the trip leg, "Ganaste"', () {
    expect(ctrl.contains('_sendShiftIsland(done: false, force: force);'), isTrue);
    expect(ctrl.contains('done: DateTime.now().difference(at) < const Duration(seconds: 15)'),
        isTrue);
    expect(ctrl.contains('DriverTripIsland.push(force: force);'), isTrue);
    expect(ctrl.contains('onlineSince: _shiftStartedAt,'), isTrue);
    final timer = trip.substring(trip.indexOf('_islandTimer = Timer.periodic('));
    expect(timer.substring(0, 120).contains('Duration(seconds: 5)'), isTrue);
    expect(timer.substring(0, 120).contains('_syncIsland()'), isTrue);
    expect(trip.contains('_islandTimer?.cancel();'), isTrue);
    expect(nav.contains('DriverTripIsland.reportEtaSeconds(secs);'), isTrue);
  });

  test('the wait fee mirrors the server (_WAIT_POLICY_BY_TYPE)', () {
    expect(DriverTripIsland.waitRateFor('comfort'), r'$0.40/min');
    expect(DriverTripIsland.waitRateFor('Standard'), r'$0.40/min');
    expect(DriverTripIsland.waitRateFor('premium'), r'$0.60/min');
    expect(DriverTripIsland.waitRateFor('VIP'), r'$1.00/min');
    expect(DriverTripIsland.waitRateFor('SUV XL'), r'$1.00/min');
    expect(DriverTripIsland.waitRateFor('black'), r'$1.00/min');
    final server = read('backend/routers/trips.py');
    expect(server.contains('"premium":  (5, 0.60)'), isTrue);
    expect(server.contains('"vip":      (5, 1.00)'), isTrue);
  });
}
