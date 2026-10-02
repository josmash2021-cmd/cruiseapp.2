import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the unclaimed-trips marketplace (user spec 2026-10-02):
/// after the cascade rang everyone once, the trip sits on the board — the
/// pill above the online sheet counts it, the sheet morphs into the claim
/// card, and the first grab keeps it (backend answers 409 for the loser).
void main() {
  test('backend endpoints exist: available list + atomic claim', () {
    final d = File('backend/routers/dispatch.py').readAsStringSync();
    expect(d.contains('@router.get("/dispatch/available"'), isTrue);
    expect(d.contains('@router.post("/dispatch/claim"'), isTrue);
    expect(d.contains('trip_no_longer_available'), isTrue,
        reason: 'the loser of the race must read "ya no está disponible"');
    expect(d.contains('.with_for_update()'), isTrue,
        reason: 'the claim locks the trip row — two grabs never both win');
  });

  test('guardian retry rings each driver ONCE (no re-offer to passers)',
      () {
    final g = File('backend/guardian_agent.py').readAsStringSync();
    expect(g.contains('One ring per driver, ever'), isTrue,
        reason: 'a driver who passed must never be rung again for the '
            'same trip — the board is the fallback');
  });

  test('app: pill + morph + claim call wired', () {
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w.contains('_marketplacePill'), isTrue);
    expect(w.contains('availableTrips('), isTrue);
    expect(w.contains('_claimTrip('), isTrue);
    expect(w.contains('AnimatedSize'), isTrue,
        reason: 'the spec: the sheet morphs animated, not a hard swap');
    final c = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(c.contains('_startMarketplacePoll'), isTrue);
    expect(c.contains('getUnclaimedTrips'), isTrue);
    expect(c.contains('claimUnclaimedTrip'), isTrue);
    expect(c.contains('alreadyAcceptedOnBackend: true'), isTrue,
        reason: 'a claimed trip enters the same accepted flow as a ring');
    final api = File('lib/services/api_service.dart').readAsStringSync();
    expect(api.contains('/dispatch/available'), isTrue);
    expect(api.contains('/dispatch/claim'), isTrue);
  });
}
