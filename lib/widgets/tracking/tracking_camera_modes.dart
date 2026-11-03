part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  CAMERA MODES — "Ruta completa" / "Seguir" (owner 2026-11-03,
//  drawing J6zTb8hfeKDqfFbzpx5jXb)
// ════════════════════════════════════════════════════════════

/// Side margins of the route frame; the right one clears the two map
/// buttons (14 from the edge, 46 wide).
const double kTrackFrameSidePad = 44;
const double kTrackFrameButtonsPad = 14 + 46 + 18;

extension _RiderTrackingCameraModes on _RiderTrackingScreenState {
  /// "Seguir" (true): only what is left of the leg, tightening as it
  /// shortens. "Ruta completa" (false): the whole trip, once, held still.
  /// Either hands the camera back if the rider had moved the map.
  void _setCameraFollow(bool follow) {
    _camFollow = follow;
    _userControllingCamera = false;
    _mapCamera?.stopNavigationChase();
    _mapCamera?.resetFollowFraming();
    _setState(() {});
    if (!follow) _fitWholeTrip();
  }

  bool get _camOnTrip =>
      _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;

  bool get _carKnown => _animPos.latitude != 0 || _animPos.longitude != 0;

  /// The drawn leg from the car onward: `_routePts` is the whole leg (the
  /// line on screen is trimmed, the list is not), `_traveledM` is how far
  /// along it the car is.
  List<LatLng> _remainingRoutePts() {
    final pts = _routePts;
    final seg = _segDist;
    if (pts.length < 2 || seg.length != pts.length) return pts;
    var i = 0;
    while (i < seg.length && seg[i] <= _traveledM) {
      i++;
    }
    return pts.sublist(math.min(i, pts.length - 1));
  }

  /// What "Seguir" frames: the car and the road still ahead of it — to the
  /// pickup before it, to the destination after it. Rebuilt a few times a
  /// second (the framer retargets every 350 ms), not every frame.
  List<LatLng> _followFramePoints() {
    final now = DateTime.now();
    if (_followPts.isNotEmpty &&
        now.difference(_followPtsAt).inMilliseconds < 300) {
      return _followPts;
    }
    _followPtsAt = now;
    final List<LatLng> pts;
    if (!_camOnTrip) {
      final approach = _routePts.isNotEmpty &&
          _hav(_routePts.last, widget.pickupLatLng) * 1609.34 < 250;
      pts = <LatLng>[
        widget.pickupLatLng,
        if (_carKnown) _animPos,
        if (approach) ..._remainingRoutePts(),
      ];
    } else {
      pts = <LatLng>[
        _currentDropoffLL,
        if (_carKnown) _animPos,
        ..._remainingRoutePts(),
      ];
    }
    return _followPts = pts;
  }

  /// What "Ruta completa" frames: the whole trip — before pickup the car's
  /// road to the pickup AND the trip after it; once aboard, pickup to
  /// destination with the car.
  List<LatLng> _wholeTripPoints() {
    if (_camOnTrip) return _tripFramePoints();
    return <LatLng>[
      ..._approachFramePoints(),
      ..._tripRoutePts,
      if (_committedStop != null) _committedStop!,
      if (widget.stopLatLng != null) widget.stopLatLng!,
      _currentDropoffLL,
    ];
  }

  /// The box the route is framed in: under the top guide, above the RESTING
  /// sheet (whose height already counts the bottom safe area) — the sheet
  /// never covers the route — and clear of the two map buttons on the right.
  // +56, not +32: a pin's tip anchors at the route end and its body rises
  // ~55 px — +32 let the dropoff pin poke behind the top guide (2026-09-17).
  double get _frameTopPad =>
      (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 10 + _topCardHeight + 56;
  double get _frameBottomPad => _bottomCardHeight + 32;

  /// "Ruta completa": one smooth fit of the whole trip, then the camera
  /// holds still.
  void _fitWholeTrip() {
    final cam = _mapCamera;
    if (cam == null) return;
    final pts = _wholeTripPoints();
    if (pts.isEmpty) return;
    unawaited(cam.fitBounds(
      points: pts,
      topPadding: _frameTopPad,
      bottomPadding: _frameBottomPad,
      leftPadding: kTrackFrameSidePad,
      rightPadding: kTrackFrameButtonsPad,
      durationMs: 1100,
    ));
  }

  /// One frame of "Seguir" (from _onCameraTick): what is left of the leg,
  /// the zoom closing in a little every frame as the gap shrinks; at the
  /// pickup, close on the pickup with the car and the rider in view.
  void _followCameraFrame() {
    final cam = _mapCamera;
    final mq = MediaQuery.maybeOf(context);
    if (cam == null || mq == null) return;
    final arrived = _phase == _TrackPhase.arrived;
    final pts = arrived
        ? <LatLng>[widget.pickupLatLng, if (_carKnown) _animPos]
        : _followFramePoints();
    if (pts.isEmpty) return;
    cam.updateFollowFrame(
      points: pts,
      screenSize: mq.size,
      topPadding: _frameTopPad,
      bottomPadding: _frameBottomPad,
      maxZoom: arrived ? 17.0 : 16.5,
    );
  }
}
