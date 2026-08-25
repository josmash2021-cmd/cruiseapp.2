import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
import '../../widgets/gold_location_dot.dart';
import '../../widgets/neu_style.dart';
import 'scheduled_rides_screen.dart';

/// Full-screen map marketplace for scheduled rides (Lyft structure, Cruise
/// visual language): navy map, compact "$N" price bubbles at each pickup,
/// floating filter pills, a draggable sheet with offer-style cards, and a
/// detail mode where the real route is drawn and framed once. The Reserve
/// button lives INSIDE the sheet, below the card — never floating over the
/// map.
class ScheduledRidesMapScreen extends StatefulWidget {
  const ScheduledRidesMapScreen({super.key});

  @override
  State<ScheduledRidesMapScreen> createState() =>
      _ScheduledRidesMapScreenState();
}

enum _DateFilter { all, today, tomorrow }

enum _TimeFilter { all, morning, afternoon, night }

class _ScheduledRidesMapScreenState extends State<ScheduledRidesMapScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _airport = Color(0xFF4285F4);
  static const _cacheKey = 'sched_avail_cache';

  // Sheet extents: collapsed peek, browsing list, detail card, full list.
  static const _sheetMin = 0.14;
  static const _sheetInitial = 0.26;
  static const _sheetDetail = 0.52;
  static const _sheetMax = 0.85;

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
  mapbox.PointAnnotationManager? _dotMgr;
  mapbox.PointAnnotation? _dotAnnot;
  mapbox.PolylineAnnotationManager? _routeMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.CircleAnnotationManager? _dotsEndMgr;
  final List<mapbox.CircleAnnotation> _endDots = [];
  mapbox.Cancelable? _bubbleTap;

  /// annotation.id → trip, so a bubble tap resolves to its ride.
  final Map<String, Map<String, dynamic>> _bubbleTrips = {};

  /// label → rendered pill bytes; "$12" only gets rasterised once.
  final Map<String, Uint8List> _bubbleByteCache = {};

  /// The driver's own marker — the same gold badge every other driver
  /// screen paints. Static here: this screen browses, it does not navigate.
  final GoldLocationDot _driverDot = GoldLocationDot(heading: true);
  LatLng? _driverPos;

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

  /// Lyft-style Dismiss: hides the ride for THIS driver, session only.
  /// In-memory on purpose — a fresh open of the screen shows them again.

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
    _driverDot.dispose();
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
        _dotMgr = null;
        _dotAnnot = null;
        _routeMgr = null;
        _routeAnnot = null;
        _dotsEndMgr = null;
        _endDots.clear();
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
          _driverPos = _initialCenter;
        });
        _syncDriverDot();
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

  Future<void> _loadAvailable(
      {bool force = false,
      double? lat,
      double? lng,
      mapbox.CoordinateBounds? bbox}) async {
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
            _driverPos = LatLng(qlat, qlng);
            _syncDriverDot();
          }
        } catch (_) {}
      }
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: qlat,
        lng: qlng,
        radiusKm: 50,
        minLat: bbox?.southwest.coordinates.lat.toDouble(),
        minLng: bbox?.southwest.coordinates.lng.toDouble(),
        maxLat: bbox?.northeast.coordinates.lat.toDouble(),
        maxLng: bbox?.northeast.coordinates.lng.toDouble(),
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
    _dotMgr = await ctrl.annotations.createPointAnnotationManager();
    _routeMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _dotsEndMgr = await ctrl.annotations.createCircleAnnotationManager();
    // Bubbles must stack freely — two pickups on the same block would
    // otherwise hide each other at low zoom.
    for (final mgr in [_bubbleMgr, _dotMgr]) {
      if (mgr == null) continue;
      try {
        final lid = mgr.id;
        await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
        await ctrl.style
            .setStyleLayerProperty(lid, 'icon-ignore-placement', true);
      } catch (_) {}
    }
    _bubbleTap?.cancel();
    _bubbleTap = _bubbleMgr?.tapEvents(onTap: _onBubbleTap);
    await _syncBubbles();
    _syncDriverDot();
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
  //  Driver marker (gold badge, same artwork as the online screen)
  // ─────────────────────────────────────────────

  Future<void> _syncDriverDot() async {
    final mgr = _dotMgr;
    final pos = _driverPos;
    if (mgr == null || pos == null || !mounted) return;
    if (!_driverDot.isReady) {
      // No tick callback needed — the marker does not move on this screen.
      await _driverDot.build(this, () {});
      if (!mounted || !_driverDot.isReady) return;
    }
    _driverDot.snapTo(pos.latitude, pos.longitude);
    final hiRes = _driverDot.currentBytesHiRes;
    final bytes = hiRes ?? _driverDot.currentBytes;
    if (bytes == null) return;
    final point = safePoint(pos.longitude, pos.latitude);
    if (point == null) return;
    final iconSize = GoldLocationDot.driverIconSize /
        (hiRes != null ? GoldLocationDot.rasterScale : 1.0);
    try {
      if (_dotAnnot != null) {
        _dotAnnot!.geometry = point;
        await mgr.update(_dotAnnot!);
      } else {
        _dotAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          iconSize: iconSize,
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Price bubbles
  // ─────────────────────────────────────────────

  /// Renders the marker as ONE bitmap: the compact "$N" pill floating above
  /// a small hailing-person figure (silhouette with a raised arm, gold,
  /// no circle/frame around it, soft shadow). A bare textField cannot draw
  /// the pill background, and a PointAnnotation takes a single image — so
  /// pill + figure are rasterised together here. The feet sit at the
  /// bottom edge so IconAnchor.BOTTOM plants the figure on the pickup.
  Future<Uint8List?> _bubbleBytes(String label, {bool selected = false}) async {
    final key = '$label|${selected ? 's' : 'n'}';
    final cached = _bubbleByteCache[key];
    if (cached != null) return cached;
    const scale = 3.0; // raster density — stays crisp on retina
    const hPad = 10.0, vPad = 4.5;
    const borderW = 1.0;
    const shadowPad = 6.0; // room for the blurred shadow to bleed into
    const gap = 2.0; // air between the pill and the figure's raised hand
    const personW = 16.0, personH = 22.0;
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: selected ? Colors.black : _gold,
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width + hPad * 2 + borderW * 2;
    final h = tp.height + vPad * 2 + borderW * 2;
    final totalW = max(w, personW);
    final totalH = h + gap + personH;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.translate(shadowPad, shadowPad);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH((totalW - w) / 2, 0, w, h),
      Radius.circular(h / 2),
    );
    // Soft shadow first, then the pill on top of it.
    canvas.drawRRect(
      rect.shift(const Offset(0, 1.5)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(rect, Paint()..color = selected ? _gold : neuSurface);
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderW
        ..color = Colors.white.withValues(alpha: selected ? 0.25 : 0.08),
    );
    tp.paint(
        canvas, Offset(rect.left + hPad + borderW, rect.top + vPad + borderW));

    // ── Hailing person: the official Material person-with-raised-arm
    // glyph (2026-08-25 — replaced the hand-drawn stick figure; this
    // Flutter version has no Icons.hailing, emoji_people_rounded is the
    // hailing look). Drawn via the icon font, with the pill's soft shadow.
    const hailingIcon = Icons.emoji_people_rounded;
    final px = (totalW - personW) / 2;
    final py = h + gap;
    TextPainter iconPainter(Color color) {
      return TextPainter(
        text: TextSpan(
          text: String.fromCharCode(hailingIcon.codePoint),
          style: TextStyle(
            fontFamily: hailingIcon.fontFamily,
            package: hailingIcon.fontPackage,
            fontSize: personH - 2,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }

    final shadowPainter = iconPainter(Colors.black.withValues(alpha: 0.45));
    canvas.save();
    canvas.translate(0.6, 1.0);
    shadowPainter.paint(canvas, Offset(px, py));
    canvas.restore();
    iconPainter(selected ? _gold : const Color(0xFFF2DFA0))
        .paint(canvas, Offset(px, py));

    final side = shadowPad * 2;
    final img = await recorder.endRecording().toImage(
        ((totalW + side) * scale).ceil(), ((totalH + side) * scale).ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final raw = bytes?.buffer.asUint8List();
    if (raw != null) _bubbleByteCache[key] = raw;
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
      final isSelected = _selected != null && _selected!['id'] == trip['id'];
      final bytes = await _bubbleBytes('\$${fare.round()}', selected: isSelected);
      if (!mounted) return;
      if (bytes == null) continue;
      try {
        final annot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          // The bitmap is rendered at 3× density — ~1.5× logical size so
          // the pill + figure stay legible at city zoom (was too small).
          // The selected marker gets the Lyft-style pop on top.
          iconSize: (isSelected ? 1.65 : 1.5) / 3.0,
          // The figure's feet are the bottom edge — they plant on the
          // pickup point while the pill floats above.
          iconAnchor: mapbox.IconAnchor.BOTTOM,
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
    _syncBubbles(); // selected marker turns gold + scales up
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
    _syncBubbles(); // the gold selected marker returns to normal
    _clearRouteAnnotation();
    if (_sheetCtrl.isAttached) {
      _sheetCtrl.animateTo(
        _sheetInitial,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Dismiss pill: closes the detail and clears the route — the ride STAYS
  /// on the map and in the list (user spec 2026-08-24: it only goes away
  /// when a driver reserves it, never by dismissing).
  void _hideSelectedTrip() {
    if (_selected == null) return;
    _dismissSelection();
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
      await _setEndpointDots(pickup, dropoff);
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
          lineWidth: 3.5,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (_) {}
    }
  }

  /// Small dots at both ends of the drawn route — gold at pickup, white at
  /// dropoff, mirroring the markers on the card's address rail.
  Future<void> _setEndpointDots(LatLng pickup, LatLng dropoff) async {
    final mgr = _dotsEndMgr;
    if (mgr == null) return;
    await _clearEndpointDots();
    for (final (pt, color) in [
      (pickup, _gold),
      (dropoff, Colors.white),
    ]) {
      final point = safePoint(pt.longitude, pt.latitude);
      if (point == null) continue;
      try {
        final annot = await mgr.create(mapbox.CircleAnnotationOptions(
          geometry: point,
          circleRadius: 5.0,
          circleColor: color.toARGB32(),
          circleStrokeWidth: 2.0,
          circleStrokeColor: const Color(0xFF0A1128).toARGB32(),
        ));
        _endDots.add(annot);
      } catch (_) {}
      if (!mounted) return;
    }
  }

  Future<void> _clearEndpointDots() async {
    final mgr = _dotsEndMgr;
    final dots = List.of(_endDots);
    _endDots.clear();
    if (mgr == null) return;
    for (final d in dots) {
      try {
        await mgr.delete(d);
      } catch (_) {}
    }
  }

  Future<void> _clearRouteAnnotation() async {
    final mgr = _routeMgr;
    final annot = _routeAnnot;
    _routeAnnot = null;
    await _clearEndpointDots();
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
    // The detail sheet covers the bottom half; reserve it so the route
    // frames in the strip that is actually visible.
    final bottom = media.size.height * (_sheetDetail + 0.06);
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

  /// Lyft-style: the search covers exactly what is on screen — the visible
  /// coordinate bounds go to the backend as a bbox (replacing the radius
  /// filter server-side). Falls back to the old centre query if the map is
  /// not there to answer.
  Future<void> _searchThisArea() async {
    setState(() => _showSearchArea = false);
    final m = _map;
    mapbox.CoordinateBounds? bbox;
    if (m != null) {
      try {
        final cam = await m.getCameraState();
        bbox = await m.coordinateBoundsForCamera(cam.toCameraOptions());
      } catch (_) {}
    }
    if (!mounted) return;
    final c = _lastCamCenter;
    // Not forced — the 10 s throttle still applies.
    _loadAvailable(lat: c?.latitude, lng: c?.longitude, bbox: bbox);
  }

  /// Back to the driver: the recenter fab flies the camera home.
  void _recenter() {
    final p = _driverPos;
    final m = _map;
    if (p == null || m == null) return;
    HapticService.lightImpact();
    setState(() => _showSearchArea = false);
    m.flyTo(
      mapbox.CameraOptions(
        center:
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)),
        zoom: 12.5,
      ),
      mapbox.MapAnimationOptions(duration: 600),
    );
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

          // ── Top bar: X + title + filter pills inside ONE solid container
          // (2026-08-25, Lyft reference): they no longer float over the map.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: neuBase,
              padding: EdgeInsets.only(top: media.padding.top + 4, bottom: 10),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      // Flat close — no box, no disc. The map is the
                      // background and the glyph floats on it.
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white, size: 26),
                        splashRadius: 22,
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
                      const SizedBox(width: 48), // balance the X button
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      _pillFilter(
                        icon: Icons.check_rounded,
                        label: s.schedMapYourRides(_myRidesCount),
                        active: false,
                        onTap: _openMyRides,
                      ),
                      const SizedBox(width: 8),
                      _pillFilter(
                        icon: Icons.flight_takeoff_rounded,
                        label: s.schedMapAirport,
                        active: _airportOnly,
                        onTap: () {
                          setState(() => _airportOnly = !_airportOnly);
                          _syncBubbles();
                        },
                      ),
                      const SizedBox(width: 8),
                      _pillFilter(
                        label: _dateFilterLabel(s),
                        active: _dateFilter != _DateFilter.all,
                        chevron: true,
                        onTap: () {
                          setState(() {
                            _dateFilter = _DateFilter
                                .values[(_dateFilter.index + 1) % 3];
                          });
                          _syncBubbles();
                        },
                      ),
                      const SizedBox(width: 8),
                      _pillFilter(
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
          ),

          // ── Dismiss pill (detail mode) ──
          if (_selected != null)
            Positioned(
              top: media.padding.top + 108,
              right: 14,
              child: _buildDismissPill(s),
            ),

          // ── Floating controls riding just above the sheet: the
          // "Search this area" pill (centred) and the recenter fab (right).
          AnimatedBuilder(
            animation: _sheetCtrl,
            builder: (ctx, _) {
              final extent =
                  _sheetCtrl.isAttached ? _sheetCtrl.size : _sheetInitial;
              final bottom = media.size.height * extent + 14;
              return Stack(
                children: [
                  if (_showSearchArea && _selected == null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: bottom,
                      child: Center(child: _buildSearchAreaPill(s)),
                    ),
                  if (_driverPos != null)
                    Positioned(
                      right: 14,
                      bottom: bottom,
                      child: _buildRecenterFab(),
                    ),
                ],
              );
            },
          ),

          // ── Draggable bottom sheet (fluid, snaps to its stops) ──
          DraggableScrollableSheet(
            controller: _sheetCtrl,
            initialChildSize: _sheetInitial,
            minChildSize: _sheetMin,
            maxChildSize: _sheetMax,
            snap: true,
            snapSizes: const [_sheetInitial, _sheetDetail],
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
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: _selected != null
                    ? _buildDetailSheet(scrollCtrl)
                    : _buildListSheet(scrollCtrl),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Floating filter pill — soft shadow, neu surface, gold when active.
  Widget _pillFilter({
    IconData? icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    bool chevron = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: active ? _gold : neuSurface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active ? _gold : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 14, color: active ? Colors.black : Colors.white70),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (chevron) ...[
              const SizedBox(width: 3),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 15, color: active ? Colors.black : Colors.white70),
            ],
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
      onTap: _hideSelectedTrip,
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

  Widget _buildSearchAreaPill(S s) {
    return GestureDetector(
      onTap: _searchThisArea,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: neuSurface,
          borderRadius: BorderRadius.circular(24),
          border:
              Border.all(color: _gold.withValues(alpha: 0.45), width: 1.2),
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
            const Icon(Icons.search_rounded, color: _gold, size: 16),
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
    );
  }

  Widget _buildRecenterFab() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: neuSurface.withValues(alpha: 0.95),
          shape: BoxShape.circle,
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.my_location_rounded, color: _gold, size: 20),
      ),
    );
  }

  /// The one CTA of detail mode. Gold, full width — and a child of the
  /// sheet, right below the card. It never floats over the map.
  Widget _buildReserveButton(S s, Map<String, dynamic> trip) {
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
    final s = S.of(context);
    final trip = _selected!;
    return ListView(
      key: const ValueKey('detail'),
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _sheetHandle(),
        // The card is a pure summary; the one action of the screen rides
        // below it, inside the sheet flow — never floating over the map.
        _rideCard(trip),
        const SizedBox(height: 4),
        _buildReserveButton(s, trip),
      ],
    );
  }

  Widget _buildListSheet(ScrollController scrollCtrl) {
    final s = S.of(context);
    final trips = _filtered;
    return ListView(
      key: const ValueKey('list'),
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _sheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                trips.isEmpty
                    ? s.schedMapAvailable
                    : s.schedMapRidesAvailable(trips.length),
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
                child: _rideCard(t),
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
    // Lyft-style: no giant empty block — the header already says "0 rides
    // available / Move map to search for rides". Just a quiet hint line.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.event_busy_rounded, color: Colors.white24,
              size: 15),
          const SizedBox(width: 8),
          Text(
            s.noScheduledTrips,
            style: const TextStyle(color: Colors.white38, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Ride card — the Cruise offer-card language: big fare + tips, hourly
  //  rate, minutes + miles, connected-dot addresses, rider row at the
  //  bottom. Navy, gold, neu radius, soft lift shadow.
  // ─────────────────────────────────────────────

  /// Rough straight-line distance in km between two points — the payload
  /// carries driver→pickup only, so the trip leg is estimated here exactly
  /// the way the offer card estimates it before Directions answers.
  static double _havKm(LatLng a, LatLng b) {
    const r = 6371.0;
    const p = pi / 180;
    final dLat = (b.latitude - a.latitude) * p;
    final dLng = (b.longitude - a.longitude) * p;
    final h = pow(sin(dLat / 2), 2) +
        cos(a.latitude * p) * cos(b.latitude * p) * pow(sin(dLng / 2), 2);
    return 2 * r * asin(sqrt(h));
  }

  Widget _rideCard(Map<String, dynamic> trip) {
    final s = S.of(context);
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final isAirport = trip['is_airport'] == true;
    final airportCode = trip['airport_code'] as String?;
    final distKm = (trip['distance_km'] as num?)?.toDouble() ?? 0;

    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    // Driver→pickup leg comes from the backend; the trip leg is a
    // straight-line estimate, same rule the offer card uses pre-Directions.
    final etaToPickup =
        (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final distToPickupMi = distKm * 0.621371;
    var tripKm = 0.0;
    if (isValidLatLng(pickupLat, pickupLng) &&
        isValidLatLng(dropoffLat, dropoffLng)) {
      tripKm = _havKm(LatLng(pickupLat!, pickupLng!),
          LatLng(dropoffLat!, dropoffLng!));
      if (!tripKm.isFinite) tripKm = 0;
    }
    final tripEta = (tripKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final tripDistMi = tripKm * 0.621371;

    final totalMin = (etaToPickup + tripEta).clamp(1, 999);
    final hourly = totalMin > 0 ? fare / (totalMin / 60.0) : 0.0;

    final scheduledAt = _parseScheduledAt(trip);
    final dateStr = scheduledAt != null
        ? DateFormat('EEE d MMM, h:mm a').format(scheduledAt.toLocal())
        : '';
    final countdownStr = _countdown(scheduledAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      // Deeper than neuBox: the card floats over a live map / sits inside a
      // sheet of identical cards, and at neuBox's 4-pt offset the layers
      // read as one flat plane. Same shadow trio as the live offer card.
      decoration: BoxDecoration(
        color: neuSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAirport
              ? _airport.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.05),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            offset: const Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -8,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            offset: const Offset(0, 4),
            blurRadius: 10,
            spreadRadius: -3,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            offset: const Offset(0, -1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Fare + tips + rate + metrics, date block on the right ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '\$${fare.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            s.plusTips,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.offerHourlyRate(hourly.toStringAsFixed(2)),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _offerMetric(Icons.access_time_rounded,
                              s.offerDuration(totalMin)),
                          const SizedBox(width: 8),
                          _offerMetric(
                            Icons.straighten_rounded,
                            '${(distToPickupMi + tripDistMi).toStringAsFixed(1)} mi',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // When the ride happens — the one fact a scheduled card has
                // that a live offer never does.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (dateStr.isNotEmpty)
                      Text(
                        dateStr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    if (countdownStr.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        countdownStr,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (isAirport && airportCode != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _airport.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.flight_rounded,
                                size: 13, color: _airport),
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
              ],
            ),

            const SizedBox(height: 18),

            // ── Pickup, then dropoff, on one connected rail ──
            _addressRail(
              pickupMeta: s.offerAway(
                  etaToPickup, distToPickupMi.toStringAsFixed(1)),
              pickupAddr: pickup,
              dropoffMeta:
                  s.offerTrip(tripEta, tripDistMi.toStringAsFixed(1)),
              dropoffAddr: dropoff,
              isAirport: isAirport,
            ),

            const SizedBox(height: 16),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            const SizedBox(height: 14),

            // ── Who is riding ──
            _riderRow(trip, s),
          ],
        ),
      ),
    );
  }

  Widget _offerMetric(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _gold),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// The two stops on one rail, joined by a line — same grammar as the
  /// offer card's `_offerRoute`: gold pickup dot, white dropoff dot (blue
  /// for airport runs), a hairline between them.
  Widget _addressRail({
    required String pickupMeta,
    required String pickupAddr,
    required String dropoffMeta,
    required String dropoffAddr,
    required bool isAirport,
  }) {
    final dropColor = isAirport ? _airport : Colors.white;
    Widget stop(Color dotColor, String meta, String addr, bool muted) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(
                  color: dotColor.withValues(alpha: 0.3), width: 2.5),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  meta,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 1),
                Text(
                  addr.isNotEmpty
                      ? addr
                      : (muted
                          ? S.of(context).dropOffLabel
                          : S.of(context).pickupLabel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted ? Colors.white70 : Colors.white,
                    fontSize: 13,
                    fontWeight: muted ? FontWeight.w500 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return IntrinsicHeight(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          stop(_gold, pickupMeta, pickupAddr, false),
          Padding(
            padding: const EdgeInsets.only(left: 4.25),
            child: Align(
              alignment: Alignment.centerLeft,
              child:
                  Container(width: 1.5, height: 14, color: Colors.white12),
            ),
          ),
          stop(dropColor, dropoffMeta, dropoffAddr, true),
        ],
      ),
    );
  }

  /// Avatar + rider name. The scheduled payload does not carry rider fields
  /// today, so the row degrades to the gold-initial avatar with the generic
  /// rider label — the same fallback the offer card uses without a photo.
  Widget _riderRow(Map<String, dynamic> trip, S s) {
    final riderName =
        (trip['rider_name'] as String?) ?? s.riderFallback;
    final photoUrl = (trip['rider_photo_url'] as String? ??
            trip['passenger_photo_url'] as String? ??
            '')
        .trim();
    final initial = riderName.trim().isNotEmpty
        ? riderName.trim()[0].toUpperCase()
        : '?';
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          child: ClipOval(
            child: photoUrl.isNotEmpty
                ? Image.network(
                    photoUrl,
                    width: 30,
                    height: 30,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => Center(
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            riderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
