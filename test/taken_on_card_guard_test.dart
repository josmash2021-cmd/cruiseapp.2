import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-06 (approved demo
/// https://claude.ai/artifact/1ysaVs28Z9MD3pAqVoAbEg): when another driver
/// beats an accept, the card the driver accepted frosts in place, "Otro
/// conductor lo tomó" rises onto it, and both leave together — no separate
/// box in the middle of the screen.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final screen = read('lib/screens/driver/driver_online_screen.dart');
  final ctrl = read('lib/screens/driver/driver_online_controller.dart');
  final widgets = read('lib/screens/driver/driver_online_widgets.dart');
  final line = read('lib/map/gradient_route_line.dart');

  String body(String src, String start, [int len = 2600]) {
    final i = src.indexOf(start);
    expect(i, isNonNegative, reason: '$start not found');
    return src.substring(i, (i + len).clamp(0, src.length));
  }

  test('a lost accept plays the notice on the card, then resets quietly', () {
    final lost = body(ctrl, '// The card the driver accepted says it on itself', 1200);
    expect(lost, contains('await _playTakenOnCard(takenId);'));
    expect(lost, contains('_resetToSearchingOnRemoteCancel(notice: false);'));
    expect(lost, contains('_resetToSearchingOnRemoteCancel(taken: true);'),
        reason: 'a card already gone still gets the centred notice');
    final reset = body(ctrl, 'void _resetToSearchingOnRemoteCancel(', 4000);
    expect(reset,
        contains('if (notice) _showCancelledNotice(reassigned: reassigned, taken: taken);'));
  });

  test('a lost claim from a map callout does the same on its card', () {
    final claim = body(ctrl, 'Future<bool> _claimTrip(', 3200);
    expect(claim, contains("await _playTakenOnCard((boardCard['offer_id'] ?? '').toString());"));
  });

  test('the card never flashes back: it leaves the list in the frame that ends it', () {
    final reset = body(ctrl, 'void _resetToSearchingOnRemoteCancel(', 2400);
    expect(reset, contains('_pendingOffers = [];'));
    expect(reset, contains('_takenCardId = null;'));
    final close = body(ctrl, 'void _closeBoardOffer(', 1200);
    expect(close, contains('_takenCardId = null;'));
  });

  test('nothing pulls the card away mid-animation', () {
    final apply = body(ctrl, 'void _applyOffers(', 900);
    expect(apply, contains('if (_takenCardId != null) return;'),
        reason: 'the poll drops an accepted offer id — the card would vanish');
    final expiry = body(widgets, 'onExpired: () {', 300);
    expect(expiry, contains('_takenCardId != null'),
        reason: 'the countdown must not reject a card that is leaving');
  });

  test('the frost is the card\'s own pixels, clipped, and takes no tap', () {
    // The look lives in the shared TakenOverCard (2026-11-16).
    final shared = read('lib/widgets/taken_over_card.dart');
    expect(shared, contains('IgnorePointer('));
    expect(shared, contains('ImageFiltered('));
    expect(shared, isNot(contains('BackdropFilter(')),
        reason: 'a backdrop blur would have to see the native map (rule 43)');
    expect(shared, contains('ClipRRect('));
    expect(shared, contains('\nconst int kTakenOverCardMs = 3390;'));
    expect(shared, contains('\nconst int kTakenOverCardExitMs = 2940;'));
    final w = body(widgets, 'Widget _takenOnCard(', 1200);
    expect(w, contains('return TakenOverCard('));
    expect(w, contains('S.of(context).rideTakenByAnotherDriver'));
    expect(w, contains('S.of(context).driverRideTakenReturning'));
    expect(w, contains('totalMs: _kTakenMs'));
    expect(w, contains('exitMs: _kTakenExitMs'));
    expect(widgets, contains('return _takenOnCard(taken, card, _buildAcceptButton(offer, oid));'));
  });

  test('a reservation claimed a moment too late says it on its card too', () {
    // Owner 2026-11-16 ("sí", drawing 2616qkJe6Tub8W6oNk4Xwg): the red bar
    // gave way to the instant offers' look.
    final resv = read('lib/screens/driver/scheduled_rides_map_screen.dart');
    final claim = body(resv, 'Future<void> _claimTrip(', 3600);
    expect(claim, contains("if (taken && _selected != null && _selected!['id'] == tripId) {"));
    expect(claim, contains('await _playTakenOnCard(tripId);'));
    final detail = body(resv, 'Widget _buildFloatingDetail(', 2400);
    expect(detail, contains('TakenOverCard('));
    expect(detail, contains('s.rideTakenByAnotherDriver'));
    expect(detail, contains('s.scheduledRideTakenBody'));
    expect(resv, contains('_takenCtrl?.dispose();'));
  });

  test('timeline constants are top-level (CLAUDE.md #16) and match the demo', () {
    expect(screen, contains('\nconst int _kTakenMs = 3390;'));
    expect(screen, contains('\nconst int _kTakenExitMs = 2940;'));
    expect(screen, contains('_takenCtrl?.dispose();'));
  });

  test('the route fades with the card and comes back full for the next offer', () {
    expect(ctrl, contains('unawaited(_offerRouteLine.setOpacity(map, o));'));
    final hide = body(line, 'Future<void> hide(', 700);
    expect(hide, contains("'line-opacity', 1.0"),
        reason: 'a faded layer left at 0 would draw the next offer invisible');
  });
}
