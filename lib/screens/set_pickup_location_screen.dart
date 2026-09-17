import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../l10n/app_localizations.dart';
import '../map/map_surface_coordinator.dart';
import '../services/haptic_service.dart';
import '../services/places_service.dart';
import '../widgets/neu_style.dart';

/// "Set your pickup location" — the pickup-confirm page between "Select
/// {tier}" and payment (2026-08-22 spec).
///
/// Lyft mechanics in navy/gold: the pin is a fixed Flutter widget and the
/// map slides underneath (no marker churn = no lag). The pin's TIP is the
/// camera focal point — bottom camera padding lifts the focal point to the
/// pin's anchor (0.33 H, above the sheet), so the pin always points at
/// exactly the coordinate the logic reads (fix 2026-08-30: before, the pin
/// floated at 0.33 H while the logic used raw screen centre, so the pin
/// pointed ~150 m away from the address the client had picked). The pin
/// OPENS anchored on the client's selected pickup — the anchor circle is
/// dropped under the tip on map create and it never auto-moves elsewhere.
/// Small dots suggest the nearest points ON the street grid (queried from
/// the style's road layers — never on water or open land); dropping the pin
/// within 25 m of a suggestion snaps to it and morphs the pin into the
/// "Recommended" pin; dropping it anywhere ELSE spawns a circle anchored
/// at the pin's tip that same instant, with the same morph (user spec
/// 2026-08-25); dragging again turns it back into the plain pin. BOTH
/// states are pins — stem + anchor dot at the tip (2026-08-30 spec). The
/// field opens with the exact address text the client entered; a city-level
/// label ("Pelham, AL 35124") sharpens to the street address of the pin's
/// coordinates, and only a label with a leading street number is
/// forward-geocoded on open so the pin starts on the doorstep — never
/// dragged to the city centroid. The pay button goes white for Apple Pay.
///
/// The Pay button calls [onConfirm] with the final pin + note — the caller
/// (ride_request) runs the existing hold → createTrip pipeline from there.
/// This page never talks to the backend itself.
class SetPickupLocationScreen extends StatefulWidget {
  const SetPickupLocationScreen({
    super.key,
    required this.pickup,
    required this.pickupLabel,
    required this.dropoff,
    required this.dropoffLabel,
    required this.tierName,
    required this.priceText,
    required this.paymentLabel,
    required this.isApplePay,
    required this.onConfirm,
  });

  final PlaceDetails pickup;
  final String pickupLabel;
  final PlaceDetails dropoff;
  final String dropoffLabel;
  final String tierName;
  final String priceText;
  final String paymentLabel;
  final bool isApplePay;

  /// Runs the existing payment + booking pipeline with the confirmed pin
  /// and note. Returns `true` once the pipeline has been handed off (its
  /// own UI takes over from the caller's screen), `false` when the payment
  /// failed or was cancelled — in that case this page stays open so the
  /// rider can retry instead of popping into a black screen.
  final Future<bool> Function(PlaceDetails pickup, String note) onConfirm;

  @override
  State<SetPickupLocationScreen> createState() =>
      _SetPickupLocationScreenState();
}

class _SetPickupLocationScreenState extends State<SetPickupLocationScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF0A1128);

  /// Snap radius to a suggested street point.
  static const _snapMeters = 25.0;

  // Unique per instance — see ride_request_screen's _mapSurfaceOwner.
  static int _nextMapSurfaceId = 0;
  late final String _mapSurfaceOwner = 'SetPickupLoc-${++_nextMapSurfaceId}';
  bool _mapMounted = false;

  mapbox.MapboxMap? _map;
  mapbox.CircleAnnotationManager? _suggestMgr;

  final _places = PlacesService(ApiKeys.webServices);

  late PlaceDetails _pin;
  bool _userMovedMap = false;
  Timer? _geocodeDebounce;
  bool _geocoding = false;

  // ── Suggested street points ──
  List<LatLngSafe> _suggested = const [];

  // ── Drop-anchored circle (user spec 2026-08-25) ──
  // Wherever the pin is released, a circle is born THAT instant under the
  // pin's tip and the pin anchors to it, exactly like a suggested point.
  // Only the latest drop keeps its circle — dragging around must not
  // litter the map with one circle per stop.
  LatLngSafe? _droppedPoint;
  mapbox.CircleAnnotation? _droppedCircle;

  // ── Pin animation state ──
  // lift while dragging → drop bounce on release; morph to the pill on snap.
  late final AnimationController _pinDropCtrl;
  late final Animation<double> _pinDropAnim;
  bool _snappedToSuggestion = false;

  /// Camera-event gate for the opening settle (user spec 2026-09-16):
  /// creating the map applies center+padding, loads the style and lays the
  /// PlatformView out — all of which can emit scroll/idle events that are
  /// NOT the rider dragging. While false, neither _onScroll nor _onIdle
  /// may run the snap cycle, or the pin re-anchors off the client's pickup
  /// onto whatever suggestion the camera drifted past on its way in.
  bool _bootSettled = false;

  bool _paying = false;
  String _note = '';

  @override
  void initState() {
    super.initState();
    // The field opens with the exact address text the client typed/picked
    // on the search page — the PlaceDetails address can be coarser and
    // must not replace what the client just confirmed.
    final label = widget.pickupLabel.trim();
    _pin = label.isNotEmpty
        ? PlaceDetails(
            address: label, lat: widget.pickup.lat, lng: widget.pickup.lng)
        : widget.pickup;
    _pinDropCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _pinDropAnim = CurvedAnimation(
      parent: _pinDropCtrl,
      curve: Curves.bounceOut,
    );
    _acquireMapSurface();
    // A generic "Current location" placeholder resolves to the real street
    // address right away instead of after the first drag; a city-level
    // label ("Pelham, AL 35124") names a ZIP, not a doorstep, so it
    // sharpens to the street address of the pin's exact coordinates.
    final address = _pin.address.trim();
    if (address.isEmpty || address.toLowerCase() == 'current location') {
      _reverseGeocodeDebounced(_pin.lat, _pin.lng);
    } else if (_isCityLevel(address)) {
      unawaited(_sharpenCityLevelLabel());
    }
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _geocodeDebounce?.cancel();
    _pinDropCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  Map surface (one native map app-wide)
  // ─────────────────────────────────────────────

  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        _map = null;
        _suggestMgr = null;
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    for (final step in <Future<void> Function()>[
      () => ctrl.scaleBar
          .updateSettings(mapbox.ScaleBarSettings(enabled: false)),
      () =>
          ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)),
      () => ctrl.attribution
          .updateSettings(mapbox.AttributionSettings(enabled: false)),
      () => ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)),
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _suggestMgr = await ctrl.annotations.createCircleAnnotationManager();
    // The pin OPENS anchored on the pickup the client already selected —
    // the anchor circle drops under the tip on open so the spot reads
    // pinned to the map from the first frame, and tiny accidental drags
    // (≤25 m) re-anchor to the client's spot instead of wandering.
    _droppedPoint = LatLngSafe(_pin.lat, _pin.lng);
    await _refreshSuggestions();
    // NOTE: the pin NEVER re-geocodes at open (user spec 2026-09-17) — the
    // search page already hands exact Places-details coordinates; a forward
    // geocode of the label dragged the pin tens of metres off the client's
    // spot. City-level TEXT still sharpens (initState), coordinates never.
    // The opening camera settles within about a second of creation — every
    // scroll/idle before that is the map initializing, not the rider.
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (mounted) _bootSettled = true;
    });
  }

  /// Bottom camera padding = the sheet's height share, so the camera focal
  /// point lands on the pin's tip (0.33 H) instead of raw screen centre.
  /// EVERY camera move must carry it or the pin drifts off the coordinate
  /// it points at.
  mapbox.MbxEdgeInsets _cameraPadding() {
    final h = MediaQuery.of(context).size.height;
    return mapbox.MbxEdgeInsets(top: 0, left: 0, bottom: h * 0.34, right: 0);
  }

  /// True for a city-level label — "Pelham, AL 35124" / "Pelham, AL" —
  /// which names a ZIP or a town, not a doorstep. POI names ("Oak
  /// Mountain …") deliberately do NOT match: a place name is exact
  /// information the driver wants to see.
  static bool _isCityLevel(String address) {
    return RegExp(r'^[^,]+,\s*[A-Z]{2}(\s+\d{5}(-\d{4})?)?$')
        .hasMatch(address.trim());
  }

  /// Opening-address sharpen for city-level seeds: the pin's coordinates
  /// are exact even when the text that came with them is not, so the
  /// field upgrades to the street address of those coordinates
  /// (Google-first via [PlacesService.reverseGeocodeDetailed]). Only a
  /// non-city-level answer is adopted — a second ZIP string is not an
  /// upgrade, and the rider keeps the text they confirmed.
  Future<void> _sharpenCityLevelLabel() async {
    try {
      final exact = await _places
          .reverseGeocodeDetailed(lat: _pin.lat, lng: _pin.lng)
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      if (exact != null &&
          exact.address.trim().isNotEmpty &&
          !_isCityLevel(exact.address)) {
        setState(() {
          _pin = PlaceDetails(
              address: exact.address, lat: _pin.lat, lng: _pin.lng);
        });
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Camera lifecycle: lift while dragging, drop + snap on idle
  // ─────────────────────────────────────────────

  void _onScroll() {
    // The map's opening settle is not the rider dragging: boot camera
    // events run no snap cycle — the pin re-anchors onto a road vertex and
    // reverse-geocodes over the exact label.
    if (!_bootSettled) return;
    _userMovedMap = true;
    if (_snappedToSuggestion) {
      // Dragging away from a suggestion turns the pill back into a pin.
      setState(() => _snappedToSuggestion = false);
    }
  }

  Future<void> _onIdle() async {
    if (!_bootSettled) return;
    if (!_userMovedMap) return;
    _userMovedMap = false;
    final map = _map;
    if (map == null) return;

    LatLngSafe? center;
    try {
      final cam = await map.getCameraState();
      center = LatLngSafe(cam.center.coordinates.lat.toDouble(),
          cam.center.coordinates.lng.toDouble());
    } catch (_) {}
    if (center == null || !mounted) return;

    // Pin drop bounce first — the snap decision rides on the same frame.
    _pinDropCtrl.forward(from: 0);

    // Snap to a nearby suggested street point, if any.
    final nearest = _nearestSuggestion(center);
    final dropped = _droppedPoint;
    if (dropped != null && _meters(center, dropped) <= _snapMeters) {
      // Re-anchoring to the circle this page already dropped: keep the
      // circle, glide the camera back onto it, morph again.
      try {
        await map.easeTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
                coordinates: mapbox.Position(dropped.lng, dropped.lat)),
            padding: _cameraPadding(),
          ),
          mapbox.MapAnimationOptions(duration: 300),
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _snappedToSuggestion = true);
      HapticService.selectionClick();
      _pin = PlaceDetails(
          address: _pin.address, lat: dropped.lat, lng: dropped.lng);
    } else if (nearest != null &&
        _meters(center, nearest) <= _snapMeters) {
      // A real suggestion absorbs the anchor — the drop circle from the
      // last stop would be a second circle under the same pin.
      _clearDroppedCircle();
      try {
        await map.easeTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
                coordinates: mapbox.Position(nearest.lng, nearest.lat)),
            padding: _cameraPadding(),
          ),
          mapbox.MapAnimationOptions(duration: 300),
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _snappedToSuggestion = true);
      HapticService.selectionClick();
      _pin = PlaceDetails(
          address: _pin.address, lat: nearest.lat, lng: nearest.lng);
    } else {
      // Drop-anchored point (user spec 2026-08-25): the circle is born
      // THIS instant, anchored to the pin's tip right where it fell, and
      // the pin anchors to it with the same Recommended morph a suggested
      // point gets. The camera is already there — no easeTo needed.
      final dropPt = LatLngSafe(center.lat, center.lng);
      _pin = PlaceDetails(
          address: _pin.address, lat: center.lat, lng: center.lng);
      _setDroppedCircle(dropPt);
      setState(() => _snappedToSuggestion = true);
      HapticService.selectionClick();
    }

    _refreshSuggestions();
    _reverseGeocodeDebounced(_pin.lat, _pin.lng);
  }

  void _reverseGeocodeDebounced(double lat, double lng) {
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(milliseconds: 400), () async {
      if (_geocoding) return;
      _geocoding = true;
      try {
        final address = await _places
            .reverseGeocode(lat: lat, lng: lng)
            .timeout(const Duration(seconds: 5));
        if (!mounted) return;
        if (address != null && address.isNotEmpty) {
          setState(() {
            _pin = PlaceDetails(address: address, lat: _pin.lat, lng: _pin.lng);
          });
        }
      } catch (_) {
      } finally {
        _geocoding = false;
      }
    });
  }

  // ─────────────────────────────────────────────
  //  Suggested street points (queryRenderedFeatures over road layers)
  // ─────────────────────────────────────────────

  Future<void> _refreshSuggestions() async {
    final map = _map;
    final mgr = _suggestMgr;
    if (map == null || mgr == null || !mounted) return;
    try {
      final size = MediaQuery.of(context).size;
      final cx = size.width / 2;
      // The query box rings the PIN TIP, not raw screen centre — the bottom
      // camera padding lifts the focal point to 0.33 H (above the sheet).
      final cy = size.height * 0.33;
      const r = 130.0; // px around the pin tip
      final features = await map.queryRenderedFeatures(
        mapbox.RenderedQueryGeometry.fromScreenBox(
          mapbox.ScreenBox(
              min: mapbox.ScreenCoordinate(x: cx - r, y: cy - r),
              max: mapbox.ScreenCoordinate(x: cx + r, y: cy + r)),
        ),
        mapbox.RenderedQueryOptions(layerIds: null, filter: null),
      );
      final pts = <LatLngSafe>[];
      for (final f in features) {
        final feat = f?.queriedFeature.feature;
        if (feat == null) continue;
        final props = feat['properties'];
        if (props is! Map) continue;
        final cls = props['class']?.toString() ?? '';
        // Car-usable road classes only — paths/pedestrian/water never
        // suggest a pickup point.
        if (!const {
          'primary',
          'secondary',
          'tertiary',
          'street',
          'street_limited',
          'service',
        }.contains(cls)) {
          continue;
        }
        final geom = feat['geometry'];
        if (geom is! Map) continue;
        final coords = geom['coordinates'];
        if (coords is! List) continue;
        // Nearest vertex of the linestring to the screen centre.
        for (final c in coords) {
          if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
            pts.add(LatLngSafe(
                (c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
        }
      }
      // Keep the closest handful, deduped to ~30 m apart.
      final cam = await map.getCameraState();
      final center = LatLngSafe(cam.center.coordinates.lat.toDouble(),
          cam.center.coordinates.lng.toDouble());
      pts.sort((a, b) =>
          _meters(center, a).compareTo(_meters(center, b)));
      final picked = <LatLngSafe>[];
      for (final p in pts) {
        if (picked.length >= 6) break;
        if (picked.any((q) => _meters(p, q) < 30)) continue;
        // Never draw a circle under the anchored pin — the Recommended
        // pill already marks the spot and the navy fill read as a black
        // hole under the pin during the snap morph.
        if (_snappedToSuggestion &&
            _meters(p, LatLngSafe(_pin.lat, _pin.lng)) <= 30) {
          continue;
        }
        // …nor on top of the drop-anchored circle — two overlapping dots
        // at the pin's tip read as a rendering glitch.
        final anchor = _droppedPoint;
        if (anchor != null && _meters(p, anchor) < 30) continue;
        picked.add(p);
      }
      if (!mounted) return;
      _suggested = picked;
      await mgr.deleteAll();
      for (final p in picked) {
        try {
          await mgr.create(mapbox.CircleAnnotationOptions(
            geometry:
                mapbox.Point(coordinates: mapbox.Position(p.lng, p.lat)),
            circleRadius: 5.0,
            circleColor: _gold.toARGB32(),
            circleStrokeColor: _navy.toARGB32(),
            circleStrokeWidth: 1.5,
          ));
        } catch (_) {}
      }
      // The drop-anchored circle went down with the same deleteAll —
      // redraw it from its coordinate so it survives every refresh.
      final dropped = _droppedPoint;
      if (dropped != null) {
        _droppedCircle = null;
        try {
          _droppedCircle = await mgr.create(mapbox.CircleAnnotationOptions(
            geometry: mapbox.Point(
                coordinates: mapbox.Position(dropped.lng, dropped.lat)),
            circleRadius: 5.0,
            circleColor: _gold.toARGB32(),
            circleStrokeColor: _navy.toARGB32(),
            circleStrokeWidth: 1.5,
          ));
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[SetPickup] suggestion query failed: $e');
    }
  }

  LatLngSafe? _nearestSuggestion(LatLngSafe center) {
    LatLngSafe? best;
    var bestD = double.infinity;
    for (final p in _suggested) {
      final d = _meters(center, p);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }

  /// Draw (or move) the drop-anchored circle at [p]. Same gold/navy style
  /// as the suggested street points so the two read as one system.
  Future<void> _setDroppedCircle(LatLngSafe p) async {
    _droppedPoint = p;
    final mgr = _suggestMgr;
    if (mgr == null || !mounted) return;
    try {
      final existing = _droppedCircle;
      if (existing != null) await mgr.delete(existing);
      _droppedCircle = await mgr.create(mapbox.CircleAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(p.lng, p.lat)),
        circleRadius: 5.0,
        circleColor: _gold.toARGB32(),
        circleStrokeColor: _navy.toARGB32(),
        circleStrokeWidth: 1.5,
      ));
    } catch (_) {}
  }

  Future<void> _clearDroppedCircle() async {
    _droppedPoint = null;
    final mgr = _suggestMgr;
    final existing = _droppedCircle;
    _droppedCircle = null;
    if (mgr == null || existing == null) return;
    try {
      await mgr.delete(existing);
    } catch (_) {}
  }

  double _meters(LatLngSafe a, LatLngSafe b) {
    const r = 6371000.0;
    final dLat = (b.lat - a.lat) * math.pi / 180;
    final dLng = (b.lng - a.lng) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.lat * math.pi / 180) *
            math.cos(b.lat * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
  }

  // ─────────────────────────────────────────────
  //  Note sheet
  // ─────────────────────────────────────────────

  Future<void> _openNoteSheet() async {
    final note = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickupNoteSheet(initial: _note),
    );
    if (note != null && mounted) {
      setState(() => _note = note.trim());
    }
  }

  // ─────────────────────────────────────────────
  //  Pay
  // ─────────────────────────────────────────────

  Future<void> _onPay() async {
    if (_paying) return;
    setState(() => _paying = true);
    try {
      HapticService.mediumImpact();
      final booked = await widget.onConfirm(_pin, _note);
      if (!mounted) return;
      // Payment/booking failed or was cancelled — stay on this page so the
      // rider can retry; popping would dump them into a dead screen.
      if (!booked) return;
      // The scheduled pipeline already replaced the WHOLE stack with the
      // booking-confirmation screen (pushAndRemoveUntil) — popping here
      // would pop THAT screen and leave the navigator empty (black screen
      // of death). Only pop if this page is still the current route.
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  // ─────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // ── Map (moves UNDER the fixed pin — that is the whole trick) ──
          Positioned.fill(
            child: _mapMounted && !kIsWeb
                ? RepaintBoundary(
                    child: mapbox.MapWidget(
                      textureView: true,
                      styleUri: MapboxConfig.styleDark,
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                            coordinates: mapbox.Position(
                                widget.pickup.lng, widget.pickup.lat)),
                        zoom: 16.5,
                        // The client's selected pickup opens EXACTLY under
                        // the pin's tip — the bottom padding lifts the
                        // camera focal point off raw screen centre to the
                        // pin's anchor above the sheet.
                        padding: mapbox.MbxEdgeInsets(
                            top: 0,
                            left: 0,
                            bottom: media.size.height * 0.34,
                            right: 0),
                      ),
                      onMapCreated: _onMapCreated,
                      onStyleLoadedListener: (_) async {
                        final m = _map;
                        if (m != null) await MapTheme.applyNavyGold(m);
                      },
                      onScrollListener: (_) => _onScroll(),
                      onZoomListener: (_) => _onScroll(),
                      onMapIdleListener: (_) => _onIdle(),
                    ),
                  )
                : const NeuDotsBackdrop(),
          ),

          // ── Fixed centre pin / "Recommended" pin ──
          // The sheet covers the bottom, so the pin's anchor sits above the
          // sheet top edge, not at raw screen centre — the bottom camera
          // padding puts the focal point at this region's centre. The
          // FractionalTranslation lifts the graphic by half its height so
          // the column's TIP (the anchor dot) lands exactly on that focal
          // point in both states, whatever each column's height is.
          Positioned.fill(
            bottom: media.size.height * 0.34,
            child: Center(
              child: AnimatedBuilder(
                animation: _pinDropAnim,
                builder: (ctx, _) {
                  // Drop bounce: pin starts 18 px up and lands.
                  final dy = -18.0 * (1 - _pinDropAnim.value);
                  return Transform.translate(
                    offset: Offset(0, dy),
                    child: FractionalTranslation(
                      translation: const Offset(0, -0.5),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        switchInCurve: Curves.easeOutBack,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(scale: anim, child: child),
                        ),
                        child: _snappedToSuggestion
                            ? _buildRecommendedPill(s)
                            : _buildPin(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // ── Close (X, top-left) ──
          Positioned(
            top: media.padding.top + 10,
            left: 14,
            child: GestureDetector(
              onTap: _paying ? null : () => Navigator.of(context).pop(false),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.10)),
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ),

          // ── Bottom sheet card ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildSheet(s, media),
          ),
        ],
      ),
    );
  }

  Widget _buildPin() {
    return Column(
      key: const ValueKey('pin'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _navy,
            shape: BoxShape.circle,
            border: Border.all(color: _gold, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.person_rounded, color: _gold, size: 24),
        ),
        // Stem + anchor dot sell "pinned to the map" — the dot is the
        // pin's tip and lands exactly on the camera focal point.
        Container(width: 3, height: 10, color: _gold),
        _buildAnchorDot(),
      ],
    );
  }

  /// The anchor at the stem's tip — the point that pins the marker to the
  /// map. Same gold/navy language as the suggested street dots, slightly
  /// bigger so the anchored spot reads first.
  Widget _buildAnchorDot() {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: _gold,
        shape: BoxShape.circle,
        border: Border.all(color: _navy, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendedPill(S s) {
    // Recommended is a pin too (2026-08-30 spec): same stem + anchor dot
    // under the pill so the snapped spot stays visually anchored.
    return Column(
      key: const ValueKey('recommended'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: Colors.black, size: 16),
              const SizedBox(width: 6),
              Text(
                s.recommendedPin,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        Container(width: 3, height: 10, color: _gold),
        _buildAnchorDot(),
      ],
    );
  }

  Widget _buildSheet(S s, MediaQueryData media) {
    return Container(
      decoration: BoxDecoration(
        color: neuBase,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 18, 20, media.padding.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.setPickupTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.setPickupSub,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 14),
          // Pickup field — live-updates as the map moves.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: neuBox(radius: 14, pressed: true),
            child: Row(
              children: [
                const Icon(Icons.place_rounded, color: _gold, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.pickupLocationField,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _pin.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Note: chip-with-X once saved, add row before that.
          if (_note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                decoration: neuBox(radius: 12),
                child: Row(
                  children: [
                    const Icon(Icons.sticky_note_2_rounded,
                        color: _gold, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _note = ''),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded,
                            color: Colors.white.withValues(alpha: 0.5),
                            size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            GestureDetector(
              onTap: _openNoteSheet,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.add_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      s.addNoteForDriver,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _paying ? null : _onPay,
              style: ElevatedButton.styleFrom(
                // Apple Pay rides on a WHITE button, Apple-style (user spec
                // 2026-08-25); every other method keeps the Cruise gold.
                backgroundColor: widget.isApplePay ? Colors.white : _gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor:
                    (widget.isApplePay ? Colors.white : _gold)
                        .withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _paying
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.black87),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.isApplePay) ...[
                          const Icon(Icons.apple_rounded,
                              size: 20, color: Colors.black),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          s.payWith(widget.paymentLabel),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small value type so the page never confuses lat/lng argument order.
class LatLngSafe {
  final double lat;
  final double lng;
  const LatLngSafe(this.lat, this.lng);
}

/// The note bottom sheet: X, prompt, 60-char field with counter, quick
/// chips that pre-fill phrases, gold "Add note for driver" button.
class _PickupNoteSheet extends StatefulWidget {
  const _PickupNoteSheet({required this.initial});

  final String initial;

  @override
  State<_PickupNoteSheet> createState() => _PickupNoteSheetState();
}

class _PickupNoteSheetState extends State<_PickupNoteSheet> {
  static const _gold = Color(0xFFE8C547);
  static const _maxLen = 60;

  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _appendChip(String text) {
    final cur = _ctrl.text;
    final base = cur.isEmpty ? '' : (cur.endsWith(' ') ? cur : '$cur ');
    final next = '$base$text ';
    _ctrl.text = next.length > _maxLen ? next.substring(0, _maxLen) : next;
    _ctrl.selection =
        TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final chips = [
      s.noteChipGateCode,
      s.noteChipWearing,
      s.noteChipCorner,
      s.noteChipInFront,
      s.noteChipDoorNumber,
      s.noteChipPickingUp,
    ];
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white70, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              s.noteSheetTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: neuBox(radius: 14, pressed: true),
              child: TextField(
                controller: _ctrl,
                maxLength: _maxLen,
                maxLines: 2,
                minLines: 1,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                cursorColor: _gold,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: s.pickupNoteField,
                  hintStyle: const TextStyle(color: Colors.white38),
                  counterStyle: TextStyle(
                    color: _ctrl.text.length >= _maxLen
                        ? const Color(0xFFEF4444)
                        : Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in chips)
                  GestureDetector(
                    onTap: () => _appendChip(c),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: neuBox(radius: 16),
                      child: Text(
                        c,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _ctrl.text.trim().isEmpty
                    ? null
                    : () =>
                        Navigator.of(context).pop(_ctrl.text.trim()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor:
                      _gold.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: Text(
                  s.addNoteForDriverButton,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
