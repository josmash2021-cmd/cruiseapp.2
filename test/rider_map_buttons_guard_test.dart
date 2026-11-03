import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03 (drawing J6zTb8hfeKDqfFbzpx5jXb): the rider's map has two
/// buttons — the arrow ("Seguir": only what is left, closing in as the car
/// nears) and the zigzag ("Ruta completa": the whole trip, held still) that
/// fades in only while following (or after the rider moved the map) and
/// fades out when tapped. The route is always framed above the resting
/// sheet; the old "Show route" pill is gone.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final ind = read('lib/widgets/tracking/trip_phase_indicator.dart');
  final modes = read('lib/widgets/tracking/tracking_camera_modes.dart');
  final screen = read('lib/screens/rider_tracking_screen.dart');
  final view = read('lib/widgets/tracking/tracking_map_view.dart');

  test('the arrow is always there; the zigzag fades in and out', () {
    expect(ind, contains('final showFull = _camFollow || _userControllingCamera;'));
    expect(ind, contains('opacity: showFull ? 1 : 0,'));
    expect(ind, contains('duration: const Duration(milliseconds: 450),'));
    expect(ind, contains("key: const ValueKey('map-full-route'),"));
    expect(ind, contains('onTap: () => _setCameraFollow(false),'));
    expect(ind, contains("key: const ValueKey('map-follow'),"));
    expect(ind, contains('onTap: () => _setCameraFollow(true),'));
    expect(ind, isNot(contains('Widget _buildResumeButton()')),
        reason: 'the "Show route" pill is gone');
  });

  test('the buttons sit above the resting sheet, under the open one', () {
    final buttons = screen.indexOf('child: _buildMapButtons(),');
    final sheet = screen.indexOf("key: const ValueKey('rider-trip-sheet'),");
    expect(buttons, isNonNegative);
    expect(sheet, greaterThan(buttons),
        reason: 'the open sheet and its blur cover the buttons');
    expect(screen, contains('bottom: _bottomCardHeight + 14,'));
  });

  test('"Seguir" frames what is left; "Ruta completa" the whole trip', () {
    expect(modes, contains('if (approach) ..._remainingRoutePts(),'));
    expect(modes, contains('..._remainingRoutePts(),'));
    expect(modes, contains('..._tripRoutePts,'));
    expect(modes, contains('cam.updateFollowFrame('));
    expect(modes, contains('if (!follow) _fitWholeTrip();'));
    // The route is framed above the resting sheet and clear of the buttons.
    expect(modes, contains('double get _frameBottomPad => _bottomCardHeight + 32;'));
    expect(modes, contains('rightPadding: kTrackFrameButtonsPad,'));
    expect(view, contains('final pts = _wholeTripPoints();'));
    expect(view, contains('if (_camFollow && _phase != _TrackPhase.completed) {'));
    expect(modes, contains('List<LatLng> _remainingRoutePts()'),
        reason: 'what is LEFT of the leg, not the whole leg');
    expect(view, contains('_followCameraFrame();'));
  });

  test('the sheet reports its resting height to the framing', () {
    expect(screen,
        contains('if (!_searchingNewDriver && _sheetRestH > 0) return _sheetRestH;'));
  });
}
