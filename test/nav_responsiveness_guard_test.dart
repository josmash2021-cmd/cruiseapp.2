import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner report 2026-11-05: in navigation the panel "a veces cuesta" to
/// swipe up, after opening and closing it a few times "el mapa pierde la
/// flecha y la ubicación de la flecha", and a status set from dispatch
/// (arrived, picked up, finished) "funciona lento, no responde a veces".
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final nav = read('lib/screens/driver/driver_nav_view.dart');
  final panel = read('lib/screens/driver/nav_trip_panel.dart');
  final trip = read('lib/screens/driver/driver_trip_accept_screen.dart');

  String bodyOf(String src, String head, {int maxLen = 2000}) {
    final i = src.indexOf(head);
    expect(i, isNot(-1), reason: 'missing: $head');
    return src.substring(i, (i + maxLen).clamp(0, src.length));
  }

  group('the arrow keeps its place under an open panel', () {
    test('the lift on the camera is capped', () {
      final pad = bodyOf(nav, 'double get _camBottomPad {', maxLen: 700);
      // The whole trip covers the screen: uncapped, the focus (and the
      // arrow drawn at it) left the top of the screen and the padding grew
      // past the map's own height.
      expect(pad, contains('final cap = math.min(2 * (focus - (mq.padding.top + 190)), h - topPad - 40);'));
      expect(pad, contains('.clamp(0.0, math.max(0.0, cap))'));
    });

    test('parked, a new lift is written to the camera too', () {
      final lift = bodyOf(nav, 'void _onLiftChanged() {', maxLen: 500);
      expect(lift, contains('_camLift.value = lift;'));
      expect(lift, contains('_snapToChasePose();'),
          reason: 'no chase frame comes for a parked car: the arrow moved '
              'and the map did not');
    });

    test('a moving panel rebuilds the arrow only, not the navigation', () {
      final cb = bodyOf(nav, 'onHeightChanged: (h) {', maxLen: 200);
      expect(cb, contains('_onLiftChanged();'));
      expect(cb, isNot(contains('setState')));
      expect(nav, contains('valueListenable: _camLift,'));
    });

    test('the cover card moves the arrow with the camera', () {
      final tick = bodyOf(nav, 'void _onCoverTick(Duration elapsed) {', maxLen: 500);
      expect(tick, contains('_camLift.value = _camBottomPad;'));
    });
  });

  test('the panel re-lays its frame, not the whole trip, every frame', () {
    expect(panel, contains('final grown = open ? body() : null;'));
    expect(panel, contains('child: grown,'));
    expect(panel, contains('child: face,'));
    final builder = bodyOf(panel, 'return AnimatedBuilder(', maxLen: 4000);
    expect(builder, isNot(contains('body()')));
    expect(builder, isNot(contains('_closedBody(s)')));
  });

  group('a status set from dispatch lands at once', () {
    test('the trip socket room runs the status check', () {
      expect(trip, contains('_socketStatusSub ??= SocketService.tripStatusStream.listen((m) {'));
      expect(trip, contains('unawaited(_checkTripStatusNow());'));
      expect(trip, contains('_socketStatusSub?.cancel();'));
      final poll = bodyOf(trip, 'void _startStatusPoll() {', maxLen: 300);
      expect(poll, contains('_checkTripStatusNow()'));
    });

    test('a check asked for mid-flight runs once more after it', () {
      final check =
          bodyOf(trip, 'Future<void> _checkTripStatusNow() async {', maxLen: 700);
      expect(check, contains('_tripStatusCheckAgain = true;'));
      expect(trip, contains('if (_tripStatusCheckAgain && mounted && !_tripFinished) {'));
    });

    test('the trip doc listener is set up again after an error', () {
      final l = bodyOf(trip, 'void _listenForRiderConfirmation() {', maxLen: 200);
      expect(l, contains('_riderConfirmSub?.cancel();'));
      expect(trip, contains('if (mounted && !_tripFinished) _listenForRiderConfirmation();'));
      expect(trip, contains('Duration(seconds: (2 * _tripListenErrors).clamp(2, 30))'));
    });
  });
}
