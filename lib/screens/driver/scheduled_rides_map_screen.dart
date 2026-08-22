import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/api_keys.dart';
import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../map/map_surface_coordinator.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/directions_service.dart';
import '../../services/haptic_service.dart';
import '../../utils/mapbox_safe.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/static_route_preview.dart';
import '../../widgets/tier_badge.dart';
import 'scheduled_rides_screen.dart';

/// Full-screen map marketplace for scheduled rides (Uber-style):
/// dark map, "$N" price bubbles at each pickup, and a draggable sheet with
/// the available list. Tapping a bubble or a card opens detail mode — the
/// real route is drawn and framed once, and the Reserve pill floats over
/// the map OUTSIDE the card.
class ScheduledRidesMapScreen extends StatefulWidget {
  const ScheduledRidesMapScreen({super.key});

  @override
  State<ScheduledRidesMapScreen> createState() =>
      _ScheduledRidesMapScreenState();
}

enum _DateFilter { all, today, tomorrow }

enum _TimeFilter { all, morning, afternoon, night }

class _ScheduledRidesMapScreenState extends State<ScheduledRidesMapScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _airport = Color(0xFF4285F4);
  static const _cacheKey = 'sched_avail_cache';

  // Sheet extents: collapsed peek, detail card, full list.
  static const _sheetMin = 0.12;
  static const _sheetInitial = 0.22;
  static const _sheetDetail = 0.42;
  static const _sheetMax = 0.8;

  // Unique per instance: this screen can sit on top of (or under) other
  // screens that also hold a MapWidget, and a shared static id makes the
  // coordinator skip the revoke — the old surface stays alive underneath
  // and two native maps crash iOS. Same pattern as ride_request_screen's
  // _mapSurfaceOwner.
  static int _nextMapSurfaceId = 0;
  late final String _mapSurfaceOwner =
      'ScheduledRidesMap-${++_nextMapSurfaceId}';
  bool _mapMounted = false;

  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _bubbleMgr;
  mapbox.PolylineAnnotationManager? _routeMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.Cancelable? _bubbleTap;

  /// annotation.id → trip, so a bubble tap resolves to its ride.
  final Map<String, Map<String, dynamic>> _bubbleTrips = {};

  /// label → rendered pill bytes; "$12" only gets rasterised once.
  final Map<String, Uint8List> _bubbleByteCache = {};

  // ── Data state ──
  List<Map<String, dynamic>> _available = [];
  bool _loadingAvail = true;
  String? _errorAvail;
  DateTime? _lastAvailFetch; // throttle: min 10 s between fetches
  bool _fetchingAvail = false; // guard concurrent calls
  int _myRidesCount = 0;
  int? _claimingId;
  bool _routeFetching = false;

  // ── Filters ──
  bool _airportOnly = false;
  _DateFilter _dateFilter = _DateFilter.all;
  _TimeFilter _timeFilter = _TimeFilter.all;

  // ── Selection / detail mode ──
  Map<String, dynamic>? _selected;

  // ── "Search this area" ──
  // Latched by the gesture callbacks, NOT onCameraChangeListener — that one
  // also fires for our own flyTo, and it would show the button on the very
  // camera move the detail fit performs.
  bool _userPanned = false;
  bool _showSearchArea = false;
  LatLng? _lastCamCenter;

  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();
  Timer? _countdownTimer;

  // Houston fallback when neither GPS nor cached trips can seed the camera.
  static const _fallbackCenter = LatLng(29.7604, -95.3698);

  LatLng _initialCenter = _fallbackCenter;

  @override
  void initState() {
    super.initState();
    _seedInitialCenter();
    _loadAvailable();
    _loadMyRidesCount();
    _acquireMapSurface();
    // Refresh countdown text every minute, same as the list screen.
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _countdownTimer?.cancel();
    _bubbleTap?.cancel();
    _sheetCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  Map surface (one native MapWidget app-wide — coordinator)
  // ─────────────────────────────────────────────

  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        // Every annotation handle belongs to the PlatformView being
        // destroyed — null them here so nothing writes to a dead native
        // channel, and onMapCreated re-seeds them on remount.
        _map = null;
        _bubbleMgr = null;
        _routeMgr = null;
        _routeAnnot = null;
        _bubbleTap = null;
        _bubbleTrips.clear();
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

  /// Last-known GPS wins; a cached trip's pickup is the fallback so the map
  // still opens where the rides are on a cold start with no fix yet.
  Future<void> _seedInitialCenter() async {
    try {
      final pos = await Geolocator.getLastKnownPosition()
          .timeout(const Duration(milliseconds: 400), onTimeout: () => null);
      if (pos != null && mounted) {
        setState(() {
          _initialCenter = LatLng(pos.latitude, pos.longitude);
        });
        return;
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        for (final t in list) {
          final lat = (t['pickup_lat'] as num?)?.toDouble();
          final lng = (t['pickup_lng'] as num?)?.toDouble();
          if (isValidLatLng(lat, lng)) {
            setState(() => _initialCenter = LatLng(lat!, lng!));
            return;
          }
        }
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Data loaders (throttle + cache, same contract as the list screen)
  // ─────────────────────────────────────────────

  Future<void> _loadAvailable({bool force = false, double? lat, double? lng}) async {
    if (_fetchingAvail) return;
    if (!force &&
        _lastAvailFetch != null &&
        DateTime.now().difference(_lastAvailFetch!).inSeconds < 10) {
      return;
    }
    _fetchingAvail = true;
    // Cached data paints instantly while fresh data loads in background.
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        setState(() {
          _available = list;
          _loadingAvail = false;
        });
        _syncBubbles();
      }
    } catch (_) {}

    try {
      double qlat = lat ?? 0, qlng = lng ?? 0;
      if (lat == null || lng == null) {
        try {
          final pos = await Geolocator.getLastKnownPosition()
              .timeout(const Duration(milliseconds: 400), onTimeout: () => null);
          if (pos != null) {
            qlat = pos.latitude;
            qlng = pos.longitude;
          }
        } catch (_) {}
      }
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: qlat,
        lng: qlng,
        radiusKm: 50,
      );
      if (!mounted) return;
      // Save to cache for next open.
      SharedPreferences.getInstance()
          .then((p) => p.setString(_cacheKey, jsonEncode(trips)));
      setState(() {
        _available = trips;
        _loadingAvail = false;
      });
      _syncBubbles();
    } catch (e) {
      if (!mounted) return;
      if (_available.isEmpty) {
        setState(() {
          _errorAvail = e.toString();
          _loadingAvail = false;
        });
      } else {
        setState(() {
          _loadingAvail = false;
        }); // keep showing cache on error
      }
    } finally {
      _fetchingAvail = false;
      _lastAvailFetch = DateTime.now();
    }
  }

  /// Only the count is needed (the "Your rides (N)" chip) — the full list
  /// lives in ScheduledRidesScreen, one tap away.
  Future<void> _loadMyRidesCount() async {
    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) return;
      final trips = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      setState(() => _myRidesCount = trips.length);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Claim (same 403/409 mapping as the list screen)
  // ─────────────────────────────────────────────

  Future<void> _claimTrip(int tripId) async {
    setState(() => _claimingId = tripId);
    try {
      final result = await ApiService.claimScheduledTrip(tripId);
      if (!mounted) return;
      HapticService.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result['message'] ?? S.of(context).scheduledRideConfirmed,
          style:
              const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      _dismissSelection();
      _loadAvailable(force: true);
      _loadMyRidesCount();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        // The one refusal the driver can act on gets its own sentence.
        // Everything else keeps the raw server reason.
        content: Text(
          e is ApiException && e.statusCode == 403
              ? S.of(context).scheduledOutOfState
              // 409: the row lock gave it to whoever asked first. The
              // loser was reading a raw exception for what is an ordinary
              // outcome of two drivers wanting the same ride.
              : e is ApiException && e.statusCode == 409
                  ? S.of(context).scheduledRideTaken
                  : '${S.of(context).error}: $e',
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      // The list still shows a ride that has just gone to someone else.
      if (mounted) _loadAvailable();
    } finally {
      if (mounted) setState(() => _claimingId = null);
    }
  }

  // ─────────────────────────────────────────────
  //  Filters
  // ─────────────────────────────────────────────

  DateTime? _parseScheduledAt(Map<String, dynamic> trip) {
    final raw = trip['scheduled_at'];
    if (raw == null) return null;
    try {
      return DateTime.parse(raw.toString());
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> get _filtered {
    return _available.where((t) {
      if (_airportOnly && t['is_airport'] != true) return false;
      if (_dateFilter != _DateFilter.all || _timeFilter != _TimeFilter.all) {
        final st = _parseScheduledAt(t);
        if (st == null) return false;
        final local = st.toLocal();
        if (_dateFilter != _DateFilter.all) {
          final now = DateTime.now();
          final day = DateTime(local.year, local.month, local.day);
          final today = DateTime(now.year, now.month, now.day);
          final diff = day.difference(today).inDays;
          if (_dateFilter == _DateFilter.today && diff != 0) return false;
          if (_dateFilter == _DateFilter.tomorrow && diff != 1) return false;
        }
        if (_timeFilter != _TimeFilter.all) {
          final h = local.hour;
          final match = switch (_timeFilter) {
            _TimeFilter.morning => h >= 5 && h < 12,
            _TimeFilter.afternoon => h >= 12 && h < 18,
            _TimeFilter.night => h >= 18 || h < 5,
            _TimeFilter.all => true,
          };
          if (!match) return false;
        }
      }
      return true;
    }).toList();
  }

  // ─────────────────────────────────────────────
  //  Map callbacks
  // ─────────────────────────────────────────────

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    // Each call stands alone so one refusal does not skip the rest.
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
    _bubbleMgr = await ctrl.annotations.createPointAnnotationManager();
    _routeMgr = await ctrl.annotations.createPolylineAnnotationManager();
    // Bubbles must stack freely — two pickups on the same block would
    // otherwise hide each other at low zoom.
    try {
      final lid = _bubbleMgr!.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
      await ctrl.style
          .setStyleLayerProperty(lid, 'icon-ignore-placement', true);
    } catch (_) {}
    _bubbleTap?.cancel();
    _bubbleTap = _bubbleMgr?.tapEvents(onTap: _onBubbleTap);
    await _syncBubbles();
    // A revoke while the detail was open took the drawn route with the old
    // surface — redraw it on the fresh one.
    final sel = _selected;
    if (sel != null) await _drawSelectedRoute(sel);
  }

  void _onCameraChanged(mapbox.CameraChangedEventData event) {
    final coords = event.cameraState.center.coordinates;
    _lastCamCenter = LatLng(coords.lat.toDouble(), coords.lng.toDouble());
  }

  void _onMapIdle(mapbox.MapIdleEventData _) {
    if (!_userPanned) return;
    _userPanned = false;
    if (_selected == null && mounted) {
      setState(() => _showSearchArea = true);
    }
  }

  void _onBubbleTap(mapbox.PointAnnotation annot) {
    final trip = _bubbleTrips[annot.id];
    if (trip != null) _selectTrip(trip);
  }

  // ─────────────────────────────────────────────
  //  Price bubbles
  // ─────────────────────────────────────────────

  /// Renders the "$N" pill as a bitmap: dark rounded pill, gold text.
  /// A bare textField cannot draw the pill background (the text halo is
  /// capped at a quarter of the font size and is not rounded), so the Uber
  /// look is rasterised here instead.
  Future<Uint8List?> _bubbleBytes(String label) async {
    final cached = _bubbleByteCache[label];
    if (cached != null) return cached;
    const scale = 3.0; // raster density — the pill stays crisp on retina
    const hPad = 13.0, vPad = 6.0;
    const borderW = 1.2;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: _gold,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width + hPad * 2 + borderW * 2;
    final h = tp.height + vPad * 2 + borderW * 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      Radius.circular(h / 2),
    );
    canvas.drawRRect(rect, Paint()..color = neuSurface);
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderW
        ..color = _gold.withValues(alpha: 0.55),
    );
    tp.paint(canvas, Offset(hPad + borderW, vPad + borderW));
    final img = await recorder
        .endRecording()
        .toImage((w * scale).ceil(), (h * scale).ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final raw = bytes?.buffer.asUint8List();
    if (raw != null) _bubbleByteCache[label] = raw;
    return raw;
  }

  Future<void> _syncBubbles() async {
    final mgr = _bubbleMgr;
    if (mgr == null || !mounted) return;
    try {
      await mgr.deleteAll();
    } catch (_) {}
    _bubbleTrips.clear();
    for (final trip in _filtered) {
      final lat = (trip['pickup_lat'] as num?)?.toDouble();
      final lng = (trip['pickup_lng'] as num?)?.toDouble();
      if (!isValidLatLng(lat, lng)) continue;
      final point = safePoint(lng!, lat!);
      if (point == null) continue;
      final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
      final bytes = await _bubbleBytes('\$${fare.round()}');
      if (!mounted) return;
      if (bytes == null) continue;
      try {
        final annot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          // The bitmap is rendered at 3× density — 1/3 lands it at logical size.
          iconSize: 1 / 3.0,
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
        _bubbleTrips[annot.id] = trip;
      } catch (_) {}
      if (!mounted) return;
    }
  }

  // ─────────────────────────────────────────────
  //  Selection / detail mode
  // ─────────────────────────────────────────────

  void _selectTrip(Map<String, dynamic> trip) {
    HapticService.lightImpact();
    setState(() {
      _selected = trip;
      _showSearchArea = false;
    });
    if (_sheetCtrl.isAttached) {
      _sheetCtrl.animateTo(
        _sheetDetail,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    _drawSelectedRoute(trip);
  }

  void _dismissSelection() {
    setState(() => _selected = null);
    _clearRouteAnnotation();
    if (_sheetCtrl.isAttached) {
      _sheetCtrl.animateTo(
        _sheetInitial,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Real pickup→dropoff route behind the detail card. Framed ONCE — the
  /// driver moving or the sheet dragging is not a reason to move the map.
  Future<void> _drawSelectedRoute(Map<String, dynamic> trip) async {
    if (_routeFetching) return;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();
    if (!isValidLatLng(pickupLat, pickupLng) ||
        !isValidLatLng(dropoffLat, dropoffLng)) {
      return;
    }
    final pickup = LatLng(pickupLat!, pickupLng!);
    final dropoff = LatLng(dropoffLat!, dropoffLng!);
    _routeFetching = true;
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      final result = await ds.getRoute(origin: pickup, destination: dropoff);
      if (!mounted || _selected != trip) return;
      // Straight line as fallback so the frame still has something to show
      // when every directions provider is down.
      final pts = (result != null && result.points.length >= 2)
          ? result.points
          : <LatLng>[pickup, dropoff];
      await _setRouteAnnotation(pts);
      if (!mounted || _selected != trip) return;
      await _fitRouteOnce(pts);
    } finally {
      _routeFetching = false;
    }
  }

  Future<void> _setRouteAnnotation(List<LatLng> pts) async {
    final mgr = _routeMgr;
    if (mgr == null) return;
    final geom = safeLineString(pts);
    if (geom == null) return;
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try {
        await mgr.update(_routeAnnot!);
      } catch (_) {}
    } else {
      try {
        _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
          geometry: geom,
          lineColor: _gold.toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (_) {}
    }
  }

  Future<void> _clearRouteAnnotation() async {
    final mgr = _routeMgr;
    final annot = _routeAnnot;
    _routeAnnot = null;
    if (mgr == null || annot == null) return;
    try {
      await mgr.delete(annot);
    } catch (_) {}
  }

  Future<void> _fitRouteOnce(List<LatLng> pts) async {
    final m = _map;
    if (m == null || pts.isEmpty) return;
    final media = MediaQuery.of(context);
    final coords = pts
        .where((p) => isValidLatLng(p.latitude, p.longitude))
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    if (coords.isEmpty) return;
    // The detail sheet plus the floating Reserve pill cover the bottom half;
    // reserve it so the route frames in the strip that is actually visible.
    final bottom = media.size.height * (_sheetDetail + 0.08);
    final top = media.padding.top + 120; // top bar + chips row
    try {
      final cam = await m.cameraForCoordinatesPadding(
        coords,
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MbxEdgeInsets(top: top, left: 48, bottom: bottom, right: 48),
        null,
        null,
      );
      if (mounted) {
        await m.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
      }
    } catch (e) {
      debugPrint('[SchedRidesMap] fit route failed: $e');
    }
  }

  // ─────────────────────────────────────────────
  //  Actions
  // ─────────────────────────────────────────────

  /// The My Rides cards can claim the one live map surface while this screen
  /// sits underneath — take it back on return.
  void _openMyRides() {
    Navigator.of(context)
        .push(slideFromRightRoute(const ScheduledRidesScreen(initialTab: 1)))
        .then((_) {
      if (!mounted) return;
      if (!_mapMounted) _acquireMapSurface();
      _loadMyRidesCount();
    });
  }

  void _searchThisArea() {
    setState(() => _showSearchArea = false);
    final c = _lastCamCenter;
    // Not forced — the 10 s throttle still applies.
    _loadAvailable(lat: c?.latitude, lng: c?.longitude);
  }

  String _countdown(DateTime? scheduledAt) {
    if (scheduledAt == null) return '';
    final diff = scheduledAt.difference(DateTime.now());
    if (diff.isNegative) return S.of(context).nowLabel;
    if (diff.inDays > 0) return 'In ${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return 'In ${diff.inHours}h ${diff.inMinutes % 60}m';
    return 'In ${diff.inMinutes}m';
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
      body: Stack(
        children: [
          // ── Map (the ONE native surface, claimed via coordinator) ──
          Positioned.fill(
            child: _mapMounted && !kIsWeb
                ? RepaintBoundary(
                    child: mapbox.MapWidget(
                      textureView: true,
                      styleUri: MapboxConfig.styleDark,
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                            coordinates: mapbox.Position(
                                _initialCenter.longitude,
                                _initialCenter.latitude)),
                        zoom: 10.5,
                      ),
                      onMapCreated: _onMapCreated,
                      onStyleLoadedListener: (_) async {
                        final m = _map;
                        if (m != null) await MapTheme.applyNavyGold(m);
                      },
                      // Gesture callbacks, not onCameraChangeListener: the
                      // latter also fires for our own flyTo and would arm
                      // "Search this area" on the detail fit.
                      onScrollListener: (_) => _userPanned = true,
                      onZoomListener: (_) => _userPanned = true,
                      onCameraChangeListener: _onCameraChanged,
                      onMapIdleListener: _onMapIdle,
                    ),
                  )
                : const NeuDotsBackdrop(),
          ),

          // ── Top bar: X + title, then the filter chips ──
          Positioned(
            top: media.padding.top + 8,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 14),
                    _roundButton(
                      icon: Icons.close_rounded,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          s.schedMapTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 54), // balance the X button
                  ],
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      _chipFilter(
                        icon: Icons.event_available_rounded,
                        label: s.schedMapYourRides(_myRidesCount),
                        active: false,
                        onTap: _openMyRides,
                      ),
                      const SizedBox(width: 8),
                      _chipFilter(
                        icon: Icons.flight_takeoff_rounded,
                        label: s.schedMapAirport,
                        active: _airportOnly,
                        onTap: () {
                          setState(() => _airportOnly = !_airportOnly);
                          _syncBubbles();
                        },
                      ),
                      const SizedBox(width: 8),
                      _chipFilter(
                        icon: Icons.calendar_today_rounded,
                        label: _dateFilterLabel(s),
                        active: _dateFilter != _DateFilter.all,
                        onTap: () {
                          setState(() {
                            _dateFilter = _DateFilter
                                .values[(_dateFilter.index + 1) % 3];
                          });
                          _syncBubbles();
                        },
                      ),
                      const SizedBox(width: 8),
                      _chipFilter(
                        icon: Icons.schedule_rounded,
                        label: _timeFilterLabel(s),
                        active: _timeFilter != _TimeFilter.all,
                        onTap: () {
                          setState(() {
                            _timeFilter = _TimeFilter
                                .values[(_timeFilter.index + 1) % 4];
                          });
                          _syncBubbles();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Dismiss pill (detail mode) ──
          if (_selected != null)
            Positioned(
              top: media.padding.top + 108,
              right: 14,
              child: _buildDismissPill(s),
            ),

          // ── "Search this area" (list mode, after a user pan) ──
          if (_showSearchArea && _selected == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: media.size.height * _sheetInitial + 16,
              child: Center(
                child: GestureDetector(
                  onTap: _searchThisArea,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: neuSurface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: _gold.withValues(alpha: 0.45), width: 1.2),
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
                        const Icon(Icons.search_rounded,
                            color: _gold, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          s.schedMapSearchArea,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Draggable bottom sheet ──
          DraggableScrollableSheet(
            controller: _sheetCtrl,
            initialChildSize: _sheetInitial,
            minChildSize: _sheetMin,
            maxChildSize: _sheetMax,
            builder: (ctx, scrollCtrl) => Container(
              decoration: BoxDecoration(
                color: neuBase,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 24,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: _selected != null
                  ? _buildDetailSheet(scrollCtrl)
                  : _buildListSheet(scrollCtrl),
            ),
          ),

          // ── Reserve pill — floating over the map, OUTSIDE the card ──
          //
          // Spec: no dark box behind it, full width with horizontal margins,
          // riding just above the detail sheet. It is a sibling of the sheet
          // in this Stack, never a child of the card — the card stays a pure
          // summary and the one action of the screen floats on its own.
          if (_selected != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedBuilder(
                animation: _sheetCtrl,
                builder: (ctx, _) {
                  final extent = _sheetCtrl.isAttached
                      ? _sheetCtrl.size
                      : _sheetDetail;
                  return Padding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: media.size.height * extent + 12,
                    ),
                    child: _buildReservePill(s, _selected!),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: neuSurface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _chipFilter({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _gold : neuSurface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? _gold : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14, color: active ? Colors.black : Colors.white70),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dateFilterLabel(S s) {
    return switch (_dateFilter) {
      _DateFilter.today => s.schedMapDateToday,
      _DateFilter.tomorrow => s.schedMapDateTomorrow,
      _DateFilter.all => s.schedMapDate,
    };
  }

  String _timeFilterLabel(S s) {
    return switch (_timeFilter) {
      _TimeFilter.morning => s.schedMapTimeMorning,
      _TimeFilter.afternoon => s.schedMapTimeAfternoon,
      _TimeFilter.night => s.schedMapTimeNight,
      _TimeFilter.all => s.schedMapTime,
    };
  }

  Widget _buildDismissPill(S s) {
    return GestureDetector(
      onTap: _dismissSelection,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: neuSurface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(22),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.close_rounded, color: Colors.white70, size: 15),
            const SizedBox(width: 5),
            Text(
              s.schedMapDismiss,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The one CTA of detail mode. Gold pill, full width, floating — no card,
  /// no dark container behind it (see the Stack sibling note above).
  Widget _buildReservePill(S s, Map<String, dynamic> trip) {
    final tripId = trip['id'] as int? ?? 0;
    final claiming = _claimingId == tripId;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: claiming ? null : () => _claimTrip(tripId),
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          disabledBackgroundColor: _gold.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.5),
        ),
        child: claiming
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.black87),
              )
            : Text(
                s.schedMapReserve,
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    letterSpacing: 0.4),
              ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Sheet contents
  // ─────────────────────────────────────────────

  Widget _sheetHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildDetailSheet(ScrollController scrollCtrl) {
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _sheetHandle(),
        // No StaticRoutePreview here: the live map right above is already
        // drawing this exact route — a thumbnail of it adds nothing.
        _rideCard(_selected!, showPreview: false),
      ],
    );
  }

  Widget _buildListSheet(ScrollController scrollCtrl) {
    final s = S.of(context);
    final trips = _filtered;
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _sheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.schedMapAvailable,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                s.schedMapMoveToSearch,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_loadingAvail)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child:
                  CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
            ),
          )
        else if (_errorAvail != null)
          _errorState(s)
        else if (trips.isEmpty)
          _emptyState(s)
        else
          ...trips.map((t) => GestureDetector(
                onTap: () => _selectTrip(t),
                child: _rideCard(t, showPreview: true),
              )),
      ],
    );
  }

  Widget _errorState(S s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.white24, size: 44),
          const SizedBox(height: 10),
          Text(
            _errorAvail!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => _loadAvailable(force: true),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: _gold.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                s.retry,
                style: const TextStyle(
                    color: _gold, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(S s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(Icons.event_busy_rounded,
                color: _gold, size: 30),
          ),
          const SizedBox(height: 16),
          Text(
            s.noScheduledTrips,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            s.scheduledTripsHint,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white38, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Ride card (same visual language as ScheduledRidesScreen)
  // ─────────────────────────────────────────────

  Widget _rideCard(Map<String, dynamic> trip, {required bool showPreview}) {
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final vehicleType = trip['vehicle_type'] as String? ?? 'standard';
    final distKm = (trip['distance_km'] as num?)?.toDouble() ?? 0;
    final isAirport = trip['is_airport'] == true;
    final airportCode = trip['airport_code'] as String?;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    final scheduledAt = _parseScheduledAt(trip);
    final dateStr = scheduledAt != null
        ? DateFormat('EEE d MMM, h:mm a').format(scheduledAt.toLocal())
        : '';
    final countdownStr = _countdown(scheduledAt);
    final hasPickup = pickupLat != null && pickupLng != null;

    return _cardShell(
      isAirport: isAirport,
      children: [
        // 1) Header: clock + date + countdown left, gold fare pill right
        _cardHeader(
          dateStr: dateStr,
          countdown: countdownStr,
          fare: fare,
          isAirport: isAirport,
          airportCode: airportCode,
        ),
        // 2) One row: tier badge + chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            TierBadge(rideName: vehicleType),
            if (countdownStr.isNotEmpty)
              _chip(Icons.timer_rounded, countdownStr, _gold),
            if (distKm > 0)
              _chip(Icons.near_me_rounded, '${distKm.toStringAsFixed(1)} km',
                  Colors.blue),
          ]),
        ),
        // 3) Route preview — a still, not a live map. One of these is
        // mounted per card, and a native Mapbox surface per card is the
        // crash that closed the app.
        if (showPreview && hasPickup)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: _previewWithFade(
                StaticRoutePreview(
                  pickupLat: pickupLat,
                  pickupLng: pickupLng,
                  dropoffLat: dropoffLat,
                  dropoffLng: dropoffLng,
                  borderRadius: 14,
                ),
              ),
            ),
          ),
        // 4) Route row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: _routeRow(pickup, dropoff, isAirport: isAirport),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  Shared card parts (mirrors of the list screen's private builders)
  // ─────────────────────────────────────────────

  Widget _cardShell({
    required bool isAirport,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      // Airport trips keep their blue edge; everything else takes the
      // shared neu border.
      decoration: neuBox(
        radius: 20,
        borderColor: isAirport ? _airport.withValues(alpha: 0.25) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  /// Map thumbnail with its bottom edge fading into the card surface.
  Widget _previewWithFade(Widget map) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          map,
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    neuSurface.withValues(alpha: 0.95),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardHeader({
    required String dateStr,
    required String countdown,
    double? fare,
    required bool isAirport,
    String? airportCode,
  }) {
    final accentColor = isAirport ? _airport : _gold;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.05),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isAirport ? Icons.flight_takeoff_rounded : Icons.schedule_rounded,
              color: accentColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (countdown.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    countdown,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (fare != null && fare > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '\$${fare.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
          if (isAirport && airportCode != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _airport.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.flight_rounded, size: 13, color: _airport),
                  const SizedBox(width: 3),
                  Text(
                    airportCode,
                    style: const TextStyle(
                      color: _airport,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _routeRow(String pickup, String dropoff, {required bool isAirport}) {
    final dropColor = isAirport ? _airport : Colors.white;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
                border:
                    Border.all(color: _gold.withValues(alpha: 0.3), width: 2.5),
              ),
            ),
            Container(width: 1.5, height: 26, color: Colors.white12),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: dropColor,
                shape: BoxShape.circle,
                border: Border.all(
                    color: dropColor.withValues(alpha: 0.3), width: 2.5),
              ),
            ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pickup.isNotEmpty ? pickup : S.of(context).pickupLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                dropoff.isNotEmpty ? dropoff : S.of(context).dropOffLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
