import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
import '../../map/flat_map_projection.dart';
import '../../map/map_callout.dart';
import '../../map/map_surface_coordinator.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/directions_service.dart';
import '../../services/haptic_service.dart';
import '../../services/notification_service.dart';
import '../../services/resilient_position_stream.dart';
import '../../services/scheduled_board_watcher.dart';
import '../../utils/driver_location_settings.dart';
import '../../utils/fix_kinematics.dart';
import '../../utils/friendly_load_error.dart';
import '../../utils/mapbox_safe.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/map/map_callout_bubble.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/glass_style.dart';
import '../../widgets/glass_notification_banner.dart';
import 'driver_rest_gate_mixin.dart';
import 'my_reservations_page.dart';
import 'reservation_detail_page.dart' show showReservationPolicy;
import 'reservation_offer_card.dart';
import 'reserve_confirm_sheet.dart';
import '../../utils/name_helper.dart' as nh;
import '../../utils/offer_metrics.dart';
import '../../utils/server_time.dart';

/// Full-screen map marketplace for scheduled rides (Lyft structure, Cruise
/// visual language): navy map, compact "$N" price bubbles at each pickup,
/// floating filter pills, a draggable sheet with offer-style cards, and a
/// detail mode where the real route is drawn and framed once. The Reserve
/// button lives INSIDE the sheet, below the card — never floating over the
/// map.
class ScheduledRidesMapScreen extends StatefulWidget {
  /// Deep-link from the "New Scheduled Ride Available" push (user spec
  /// 2026-09-27): open straight into that trip's detail. When the ride is
  /// gone from the fresh list (claimed by another driver, or filtered out
  /// for this one) a toast says so and the map stays in browse mode.
  final int? initialTripId;
  const ScheduledRidesMapScreen({super.key, this.initialTripId});

  @override
  State<ScheduledRidesMapScreen> createState() =>
      _ScheduledRidesMapScreenState();
}

enum _DateFilter { all, today, tomorrow }

enum _TimeFilter { all, morning, afternoon, night }

class _ScheduledRidesMapScreenState extends State<ScheduledRidesMapScreen>
    with TickerProviderStateMixin, DriverRestGate {
  static const _gold = Color(0xFFE8C547);
  static const _airport = Color(0xFF4285F4);
  static const _cacheKey = 'sched_avail_cache';

  // Sheet extents. A drag rests in exactly TWO places — closed (the header:
  // "N rides available" + its line) or fully open (owner spec 2026-10-31:
  // "debe cerrarse o abrirse completo, pero no hasta la mitad"). Detail is
  // the one height the app itself sets when a ride is tapped; any drag from
  // there still lands closed or open.
  static const _sheetMin = 0.14;
  static const _sheetInitial = _sheetMin;
  // Detail sits LOW, Lyft-style (2026-08-25): the card + Reserve take the
  // bottom ~44% and the route owns the rest of the map.
  static const _sheetDetail = 0.44;

  /// Height the floating ride card + Reservar take at the bottom: they
  /// measure 386 (English) to 404 (Spanish, rendered 2026-11-04), + 12
  /// below them and a little air above.
  static const double _kDetailCardSpace = 430;
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
  // True once the style finished loading — the price-bubble images attach
  // only after that (pre-style they render as the default blue marker).
  bool _styleReady = false;

  /// Deep-link selection (widget.initialTripId) pending on BOTH the fresh
  /// list and the live map — see _tryConsumePendingSelect.
  int? _pendingSelectTripId;
  bool _freshLoaded = false;

  // Live refresh (owner report 2026-10-29: a new reservation never showed up
  // while this list was open). It reloaded only on open and on the
  // `scheduled_ride` push, so a push that did not arrive left the list stale
  // for good. The poll replays the LAST query exactly (same area the driver
  // is looking at), so it never swaps a searched area for the default one.
  static const Duration _availPollEvery = Duration(seconds: 15);
  Timer? _availPollTimer;
  double? _lastQLat;
  double? _lastQLng;
  mapbox.CoordinateBounds? _lastQBbox;
  String? _lastAvailJson;
  mapbox.PointAnnotationManager? _dotMgr;
  mapbox.PointAnnotation? _dotAnnot;
  // The selected ride's line: a style layer (not an annotation) so it can
  // carry a gradient — gold at the pickup to white at the drop-off, the
  // card rail's line (owner 2026-11-04, "mismo diseño para la línea").
  static const _routeSourceId = 'resv-route-src';
  static const _routeLayerId = 'resv-route-line';
  mapbox.CircleAnnotationManager? _dotsEndMgr;
  final List<mapbox.CircleAnnotation> _endDots = [];

  // The rides' callouts (owner 2026-11-04, "como cuando un viaje todos han
  // rechazado"): a Flutter overlay like the online map's — the camera of
  // every frame, and the zoom hysteresis of rule #49b.
  mapbox.CameraState? _camState;
  final ValueNotifier<int> _camFrame = ValueNotifier<int>(0);
  bool _calloutsExpanded = false;


  /// The driver's own marker — the same gold badge every other driver
  /// screen paints. Static here: this screen browses, it does not navigate.
  final GoldLocationDot _driverDot = GoldLocationDot(heading: true);
  LatLng? _driverPos;

  /// The arrow MOVES on this map too (owner 2026-11-03: "la flecha en esta
  /// página debe moverse bien, no ser estática"): live fixes through the
  /// shared driver GPS channel, glided by SmoothMotion, turned by the car's
  /// own course (no compass — rule 41).
  ResilientPositionStream? _gps;
  bool _dotWriteBusy = false;
  bool _dotWriteAgain = false;
  bool _dotAlignmentSet = false;

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
    initDriverRestGate();
    NotificationService.scheduledRideRefreshNotifier
        .addListener(_onScheduledRidePush);
    // Live board: a booking anywhere refreshes this screen at once.
    ScheduledBoardWatcher.acquire();
    _pendingSelectTripId = widget.initialTripId;
    _seedInitialCenter();
    _loadAvailable();
    _loadMyRidesCount();
    _acquireMapSurface();
    // Refresh countdown text every minute, same as the list screen.
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _availPollTimer = Timer.periodic(_availPollEvery, (_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      _loadAvailable(
          force: true, lat: _lastQLat, lng: _lastQLng, bbox: _lastQBbox);
    });
  }

  @override
  void dispose() {
    NotificationService.scheduledRideRefreshNotifier
        .removeListener(_onScheduledRidePush);
    ScheduledBoardWatcher.release();
    disposeDriverRestGate();
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _countdownTimer?.cancel();
    _availPollTimer?.cancel();
    _camFrame.dispose();
    unawaited(_gps?.stop());
    _gps = null;
    _driverDot.dispose();
    _sheetCtrl.dispose();
    super.dispose();
  }

  void _onScheduledRidePush() {
    if (mounted) _loadAvailable(force: true);
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
        _dotMgr = null;
        _dotAnnot = null;
        _dotAlignmentSet = false;
        _dotsEndMgr = null;
        _endDots.clear();
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
    _tryConsumePendingSelect();
  }

  /// Live position for the arrow. One Android GPS channel is shared by every
  /// driver screen (rule 33): the same driverLocationSettings as the rest,
  /// foreground-only here (this page tracks nothing in the background).
  void _startLiveGps() {
    if (kIsWeb || _gps != null || !mounted) return;
    final s = S.of(context);
    _gps = ResilientPositionStream(
      label: 'ScheduledMapGps',
      settings: driverLocationSettings(
        distanceFilter: 0,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnline,
        background: false,
      ),
      onPosition: (pos) {
        if (!mounted) return;
        if (!pos.latitude.isFinite || !pos.longitude.isFinite) return;
        _driverPos = LatLng(pos.latitude, pos.longitude);
        if (!_driverDot.isReady || _dotAnnot == null) {
          unawaited(_syncDriverDot());
          return;
        }
        // Android reports 0/0 when it measured nothing — only real
        // readings steer the arrow (rule 32).
        _driverDot.setTarget(
          pos.latitude,
          pos.longitude,
          bearing: measuredCourseDeg(pos),
          accuracyM: pos.accuracy,
          timestampMs: pos.timestamp.millisecondsSinceEpoch.toDouble(),
          speedMps: measuredSpeedMps(pos),
        );
      },
    )..start();
  }

  /// One glide step of the arrow onto the map: position and heading. Paced
  /// by the dot's own throttle; a write that lands while the previous one is
  /// in flight is queued, so the LAST position always settles (rule 25).
  void _onDotTick() {
    if (!mounted || _selected != null) return;
    final mgr = _dotMgr;
    final annot = _dotAnnot;
    final lat = _driverDot.lat, lng = _driverDot.lng;
    if (mgr == null || annot == null || lat == null || lng == null) return;
    if (_dotWriteBusy) {
      _dotWriteAgain = true;
      return;
    }
    final point = safePoint(lng, lat);
    if (point == null) return;
    annot.geometry = point;
    annot.iconRotate = _driverDot.bearing;
    _dotWriteBusy = true;
    mgr.update(annot).catchError((Object _) {}).whenComplete(() {
      _dotWriteBusy = false;
      if (_dotWriteAgain) {
        _dotWriteAgain = false;
        _onDotTick();
      }
    });
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
    _lastQLat = lat;
    _lastQLng = lng;
    _lastQBbox = bbox;
    // Cached data paints instantly while fresh data loads in background —
    // first paint only; once fresh data is on screen a refresh must not
    // flash the cached list over it.
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && mounted && !_freshLoaded) {
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
      // Same list as on screen (the 15 s poll's usual case): nothing to
      // redraw. Re-syncing deleted and re-created every bubble each poll —
      // the map blinked every 15 s (review 2026-10-30).
      final freshJson = jsonEncode(trips);
      if (_freshLoaded && freshJson == _lastAvailJson) {
        _loadingAvail = false;
        // The signal came back with the same list: the error goes away.
        if (_errorAvail != null) setState(() => _errorAvail = null);
        return;
      }
      _lastAvailJson = freshJson;
      // Save to cache for next open.
      SharedPreferences.getInstance()
          .then((p) => p.setString(_cacheKey, freshJson));
      setState(() {
        _available = trips;
        _loadingAvail = false;
        _freshLoaded = true;
        // Data arrived: an earlier failure must not keep covering it
        // (2026-10-31 — the error stayed up after the signal came back).
        _errorAvail = null;
      });
      _syncBubbles();
      _tryConsumePendingSelect();
    } catch (e) {
      if (!mounted) return;
      if (_available.isEmpty) {
        setState(() {
          // 2026-10-26: never print the raw exception wrapper — drivers read
          // "ApiException" and think the marketplace is down. The server
          // already sends the reason; a 403 here means the account is not
          // approved yet (waitlist/pending), not a server failure.
          // 2026-10-31: no signal printed the raw "ClientException with
          // SocketException…" — never the exception text, ever.
          _errorAvail = friendlyLoadError(context, e, pendingOn403: true);
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
  /// lives in MyReservationsPage, one tap away.
  Future<void> _loadMyRidesCount() async {
    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) return;
      final trips = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      setState(() =>
          _myRidesCount = myReservationRows(trips, DateTime.now()).length);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Claim (same 403/409 mapping as the list screen)
  // ─────────────────────────────────────────────

  Future<void> _claimTrip(int tripId) async {
    if (driverIsResting) {
      showDriverRestRemaining();
      return;
    }
    setState(() => _claimingId = tripId);
    try {
      final result = await ApiService.claimScheduledTrip(tripId);
      if (!mounted) return;
      HapticService.mediumImpact();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
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
      if (e is ApiException &&
          e.statusCode == 403 &&
          e.message == 'shift_rest_required') {
        syncDriverRestRefusal();
        return;
      }
      final goOnline = e is ApiException &&
          e.statusCode == 409 &&
          e.message == 'go_online_first';
      final taken = e is ApiException && e.statusCode == 409 && !goOnline;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        // The refusals the driver can act on get their own sentence.
        // Everything else keeps the raw server reason.
        content: Text(
          e is ApiException && e.message == 'maintenance'
              ? S.of(context).maintenanceClaimBlocked
              // Inside the last hour a reservation is only for a driver
              // who is online (offline, the next tick would hand it back).
              : goOnline
                  ? S.of(context).scheduledGoOnlineFirst
              : e is ApiException && e.statusCode == 403
                  ? S.of(context).scheduledOutOfState
              // 409: the row lock gave it to whoever asked first. The
              // loser was reading a raw exception for what is an ordinary
              // outcome of two drivers wanting the same ride.
              : taken
                  ? S.of(context).scheduledRideTaken
                  : '${S.of(context).error}: $e',
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      // The ride has just gone to someone else: close its card (its
      // Reservar is dead) and re-read now — the 10 s throttle would leave
      // it on the map.
      if (taken) _dismissSelection();
      _loadAvailable(force: taken);
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
      return parseServerTime(raw);
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
      () => MapBrand.show(ctrl),
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _dotMgr = await ctrl.annotations.createPointAnnotationManager();
    _dotsEndMgr = await ctrl.annotations.createCircleAnnotationManager();
    for (final mgr in [_dotMgr]) {
      if (mgr == null) continue;
      try {
        final lid = mgr.id;
        await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
        await ctrl.style
            .setStyleLayerProperty(lid, 'icon-ignore-placement', true);
      } catch (_) {}
    }
    // The callouts draw from the camera: seed it (no change event until
    // the camera first moves).
    try {
      _camState = await ctrl.getCameraState();
      _camFrame.value++;
    } catch (_) {}
    // Image-bearing annotations (the price bubbles) must NOT attach before
    // the style is up: pre-style they render as the default blue marker
    // (the 2026-08-08 bug this gate exists for). Geometry-only content —
    // the driver dot, the selected route — carries no image and stays
    // immediate.
    if (_styleReady) await _syncBubbles();
    _syncDriverDot();
    // A revoke while the detail was open took the drawn route with the old
    // surface — redraw it on the fresh one.
    final sel = _selected;
    if (sel != null) await _drawSelectedRoute(sel);
  }

  void _onCameraChanged(mapbox.CameraChangedEventData event) {
    final coords = event.cameraState.center.coordinates;
    _lastCamCenter = LatLng(coords.lat.toDouble(), coords.lng.toDouble());
    _camState = event.cameraState;
    _camFrame.value++;
  }

  void _onMapIdle(mapbox.MapIdleEventData _) {
    if (!_userPanned) return;
    _userPanned = false;
    if (_selected == null && mounted) {
      setState(() => _showSearchArea = true);
    }
  }

  // ─────────────────────────────────────────────
  //  Driver marker (gold badge, same artwork as the online screen)
  // ─────────────────────────────────────────────

  Future<void> _syncDriverDot() async {
    // Detail mode is driverless — a GPS fix mid-detail must not resurrect
    // the arrow over the framed route.
    if (_selected != null) return;
    final mgr = _dotMgr;
    final pos = _driverPos;
    if (mgr == null || pos == null || !mounted) return;
    if (!_driverDot.isReady) {
      // The tick moves the arrow on the map as it glides (it used to be a
      // still marker here).
      await _driverDot.build(this, _onDotTick);
      if (!mounted || !_driverDot.isReady) return;
    }
    _driverDot.snapTo(pos.latitude, pos.longitude, bearing: _driverDot.bearing);
    _startLiveGps();
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
          iconRotate: _driverDot.bearing,
        ));
        // The heading is geographic (0 = north): it turns with the map, not
        // with the screen.
        if (!_dotAlignmentSet) {
          _dotAlignmentSet = true;
          try {
            await _map?.style.setStyleLayerProperty(
                mgr.id, 'icon-rotation-alignment', 'map');
          } catch (_) {
            _dotAlignmentSet = false;
          }
        }
      }
    } catch (_) {}
  }

  // ─────────────────────────────────────────────
  //  Price bubbles
  // ─────────────────────────────────────────────

  /// The rides on the board are a Flutter overlay ([_rideCalloutOverlay])
  /// built from [_filtered] and [_selected]; this only asks for a rebuild.
  /// Kept as the one call every list, filter and selection change makes.
  Future<void> _syncBubbles() async {
    if (mounted) setState(() {});
  }

  /// The rides on the board as the online map's trip callouts (owner
  /// 2026-11-04: "hazlo como cuando un viaje todos han rechazado"): the
  /// same MapCalloutBubble — the gold tile, "$20 CRUISE", the pickup's day
  /// and time under it — glued to its pickup every camera frame with
  /// FlatMapProjection, open from zoom 11 and down to the price below 10.6
  /// (rule #49b). A tap opens the ride; an open ride keeps only its own
  /// callout, over the pickup ring of its route.
  Widget _rideCalloutOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _camFrame,
      builder: (context, _) {
        final cam = _camState;
        if (cam == null || !_mapMounted) return const SizedBox.shrink();
        // An open ride keeps only ITS callout, sitting on its pickup ring
        // (owner 2026-11-04, "colócalo aquí").
        final open = _selected;
        final s = S.of(context);
        final isEs = Localizations.localeOf(context).languageCode == 'es';
        final size = MediaQuery.sizeOf(context);
        _calloutsExpanded =
            calloutExpandedForZoom(cam.zoom, wasExpanded: _calloutsExpanded);
        final c = cam.center.coordinates;
        final center = LatLng(c.lat.toDouble(), c.lng.toDouble());
        final pad = cam.padding;
        final shift = Offset(
            (pad.left - pad.right) / 2, (pad.top - pad.bottom) / 2);
        final children = <Widget>[];
        for (final trip in open == null ? _filtered : [open]) {
          final lat = (trip['pickup_lat'] as num?)?.toDouble();
          final lng = (trip['pickup_lng'] as num?)?.toDouble();
          if (!isValidLatLng(lat, lng)) continue;
          final off = FlatMapProjection.screenOffsetHeading(
            target: LatLng(lat!, lng!),
            cameraCenter: center,
            zoom: cam.zoom,
            bearingDeg: cam.bearing,
            pitchDeg: cam.pitch,
            viewport: size,
          );
          if (off == null) continue;
          final p = off + shift;
          if (!FlatMapProjection.isOnScreen(p, size, margin: 160)) continue;
          final price = tripCalloutPrice(trip['fare']);
          final product = tripCalloutProduct(trip['vehicle_type']);
          final at = _parseScheduledAt(trip);
          final bubble = MapCalloutBubble(
            variant: CalloutVariant.trip,
            title: price ?? product,
            titleFade: price == null ? null : ' $product',
            subtitle: at == null ? null : _whenShort(s, at, isEs),
            expanded: _calloutsExpanded,
            onTap: open == null ? () => _selectTrip(trip) : null,
          );
          children.add(Positioned(
            key: ValueKey('resv-callout-${trip['id']}'),
            left: p.dx,
            // Open: the tail tip rests on top of the pickup ring.
            top: open == null ? p.dy : p.dy - 9,
            child: open == null ? bubble : IgnorePointer(child: bubble),
          ));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }

  // ─────────────────────────────────────────────
  //  Selection / detail mode
  // ─────────────────────────────────────────────

  /// The push deep-link (widget.initialTripId): select the trip once BOTH
  /// the fresh list and the live map are up. Not finding it means another
  /// driver claimed it or the server filtered it out for this one
  /// (state/tier) — an honest toast, never a silent no-op.
  void _tryConsumePendingSelect() {
    final id = _pendingSelectTripId;
    if (id == null || !_freshLoaded || !_mapMounted) return;
    _pendingSelectTripId = null;
    Map<String, dynamic>? hit;
    for (final t in _available) {
      if (t['id'] == id) {
        hit = t;
        break;
      }
    }
    if (hit != null) {
      _selectTrip(hit);
      return;
    }
    // Opened from a notification about a ride that is gone: the glass
    // banner at the top (owner spec 2026-11-01).
    GlassNotificationBanner.show(
      context: context,
      title: S.of(context).scheduledRideNoLongerAvailable,
      icon: Icons.event_busy_rounded,
    );
  }

  void _selectTrip(Map<String, dynamic> trip) {
    HapticService.lightImpact();
    setState(() {
      _selected = trip;
      _showSearchArea = false;
    });
    // Detail mode is driverless, Lyft-style (2026-08-25): the gold arrow
    // comes off the map so the route owns it; Dismiss draws it back.
    final dotMgr = _dotMgr;
    final dotAnnot = _dotAnnot;
    if (dotMgr != null && dotAnnot != null) {
      _dotAnnot = null;
      dotMgr.delete(dotAnnot).catchError((Object _) {});
    }
    _syncBubbles(); // selected marker turns gold + scales up
    // The list sheet steps aside and the ride floats as an offer card
    // (owner 2026-11-03, Lyft) — the sheet keeps its own height for later.
    _drawSelectedRoute(trip);
  }

  void _dismissSelection() {
    setState(() => _selected = null);
    _syncBubbles(); // the gold selected marker returns to normal
    _clearRouteAnnotation();
    _syncDriverDot(); // the driver's arrow comes back
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
      final raw = (result != null && result.points.length >= 2)
          ? result.points
          : <LatLng>[pickup, dropoff];
      // Anchor the line to the exact pins (user spec 2026-08-28): the
      // directions geometry starts/ends at the road snap, a few metres off
      // the dot — splice the true endpoints so the line MEETS them.
      final pts = <LatLng>[
        if (_havKm(pickup, raw.first) * 1000 > 2) pickup,
        ...raw,
        if (_havKm(dropoff, raw.last) * 1000 > 2) dropoff,
      ];
      await _setRouteAnnotation(pts);
      await _setEndpointDots(pickup, dropoff);
      if (!mounted || _selected != trip) return;
      await _fitRouteOnce(pts);
    } finally {
      _routeFetching = false;
    }
  }

  Future<void> _setRouteAnnotation(List<LatLng> pts) async {
    final m = _map;
    if (m == null || pts.length < 2) return;
    final coords = [
      for (final p in pts)
        if (isValidLatLng(p.latitude, p.longitude))
          [p.longitude, p.latitude],
    ];
    if (coords.length < 2) return;
    final data = jsonEncode({
      'type': 'Feature',
      'properties': <String, Object>{},
      'geometry': {'type': 'LineString', 'coordinates': coords},
    });
    final style = m.style;
    try {
      if (await style.styleSourceExists(_routeSourceId)) {
        await style.setStyleSourceProperty(_routeSourceId, 'data', data);
      } else {
        await style.addSource(mapbox.GeoJsonSource(
          id: _routeSourceId,
          data: data,
          // What makes `line-progress` — and so the gradient — exist.
          lineMetrics: true,
        ));
      }
      if (!await style.styleLayerExists(_routeLayerId)) {
        final layer = mapbox.LineLayer(
          id: _routeLayerId,
          sourceId: _routeSourceId,
          lineCap: mapbox.LineCap.ROUND,
          lineJoin: mapbox.LineJoin.ROUND,
          lineWidth: 4.0,
          lineGradientExpression: [
            'interpolate',
            ['linear'],
            ['line-progress'],
            0,
            'rgba(232, 197, 71, 1)',
            1,
            'rgba(255, 255, 255, 1)',
          ],
        );
        // Under the street names (dark-v11 calls them road-label-simple),
        // over everything else; on top of the style if neither exists.
        var placed = false;
        for (final below in const ['road-label-simple', 'road-label']) {
          if (!await style.styleLayerExists(below)) continue;
          try {
            await style.addLayerAt(layer, mapbox.LayerPosition(below: below));
            placed = true;
            break;
          } catch (_) {}
        }
        if (!placed) await style.addLayer(layer);
      } else {
        await style.setStyleLayerProperty(
            _routeLayerId, 'visibility', 'visible');
      }
    } catch (e) {
      debugPrint('[SchedMap] route line failed: $e');
    }
  }

  /// Ring markers at both ends of the drawn route — the card rail's own
  /// (user spec 2026-08-28; owner 2026-11-04, "los círculos deben ser igual
  /// que estos"): a gold ring with a gold dot at the pickup, a hollow white
  /// ring at the drop-off, at the rail's 13 pt, filled with the map's navy
  /// so the line ends at the ring instead of running through it.
  Future<void> _setEndpointDots(LatLng pickup, LatLng dropoff) async {
    final mgr = _dotsEndMgr;
    if (mgr == null) return;
    await _clearEndpointDots();

    Future<void> ring(LatLng pt, Color color, {required bool filled}) async {
      final point = safePoint(pt.longitude, pt.latitude);
      if (point == null) return;
      try {
        final ringAnnot = await mgr.create(mapbox.CircleAnnotationOptions(
          geometry: point,
          circleRadius: 5.5,
          circleColor: const Color(0xFF0A1128).toARGB32(),
          circleStrokeWidth: 1.8,
          circleStrokeColor: color.toARGB32(),
        ));
        _endDots.add(ringAnnot);
        if (filled) {
          final dotAnnot = await mgr.create(mapbox.CircleAnnotationOptions(
            geometry: point,
            circleRadius: 2.5,
            circleColor: color.toARGB32(),
          ));
          _endDots.add(dotAnnot);
        }
      } catch (_) {}
      if (!mounted) return;
    }

    await ring(pickup, _gold, filled: true);
    await ring(dropoff, Colors.white, filled: false);
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
    await _clearEndpointDots();
    final m = _map;
    if (m == null) return;
    try {
      if (await m.style.styleLayerExists(_routeLayerId)) {
        await m.style
            .setStyleLayerProperty(_routeLayerId, 'visibility', 'none');
      }
    } catch (_) {}
  }

  Future<void> _fitRouteOnce(List<LatLng> pts) async {
    final m = _map;
    if (m == null || pts.isEmpty) return;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return;
    final coords = pts
        .where((p) => isValidLatLng(p.latitude, p.longitude))
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    if (coords.isEmpty) return;
    // The floating ride card + Reservar cover the bottom; the route frames
    // in the strip above them (the top bar is gone in this mode, only X).
    // The top leaves room for the ride's callout, which stands ~80 above
    // its pickup (2026-11-04).
    final bottom = media.padding.bottom + _kDetailCardSpace;
    final top = media.padding.top + 140;
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
        .push(slideFromRightRoute(const MyReservationsPage()))
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
                        if (m == null) return;
                        await MapTheme.applyNavyGold(m);
                        // The style is up: the bubbles' image bytes can
                        // attach now (pre-style they rendered as the default
                        // blue marker). This is also the kick for the cold
                        // start, where onMapCreated ran before the style.
                        _styleReady = true;
                        await _syncBubbles();
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
          // ── The rides, as the online map's callouts ──
          Positioned.fill(child: _rideCalloutOverlay()),

          // ── Top bar: X + title + filter pills inside ONE solid container
          // (2026-08-25, Lyft reference): they no longer float over the map.
          // Detail mode fades the whole bar out (Lyft photo 2026-08-25):
          // only the Dismiss pill stays, top-right.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              opacity: _selected == null ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: _selected != null,
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
            ),
          ),

          // ── Dismiss pill (detail mode) — top-right where the bar used
          // to be, matching the Lyft detail layout.
          if (_selected != null)
            Positioned(
              top: media.padding.top + 12,
              right: 14,
              child: _buildDismissX(),
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
                  if (_driverPos != null && _selected == null)
                    Positioned(
                      right: 14,
                      bottom: bottom,
                      child: _buildRecenterFab(),
                    ),
                ],
              );
            },
          ),

          // ── Draggable bottom sheet (fluid, snaps to its stops) ── it
          // steps aside while a ride floats as an offer card.
          IgnorePointer(
            ignoring: _selected != null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              opacity: _selected == null ? 1 : 0,
              child: DraggableScrollableSheet(
            controller: _sheetCtrl,
            initialChildSize: _sheetInitial,
            minChildSize: _sheetMin,
            maxChildSize: _sheetMax,
            snap: true, // min + max only: closed or fully open
            // Frosted glass like the driver's home sheet (owner spec
            // 2026-10-31), frosted harder as it rises: by the detail height
            // nothing under it — the arrow, a bubble — shows through.
            // The sheet's builder runs once, not per drag frame — the
            // controller is what moves, so the frost listens to it.
            builder: (ctx, scrollCtrl) => AnimatedBuilder(
              animation: _sheetCtrl,
              builder: (ctx, child) => GlassSurface(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                blur: kGlassSheetBlur +
                    (kGlassSheetBlurOpen - kGlassSheetBlur) * _sheetOpenT(),
                tint: Color.lerp(
                    glassSheetTint, glassSheetOpenTint, _sheetOpenT())!,
                child: child!,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: _buildListSheet(scrollCtrl),
              ),
            ),
          ),
            ),
          ),

          // ── The selected ride, floating above Reservar ──
          // The offer card's side inset: card and Reservar equally wide.
          Positioned(
            left: 20,
            right: 20,
            bottom: media.padding.bottom + 12,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.1), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              child: _selected == null
                  ? const SizedBox.shrink()
                  : _buildFloatingDetail(s, _selected!),
            ),
          ),
        ],
      ),
    );
  }

  /// 0 closed → 1 at the detail height: how hard the sheet's glass frosts.
  double _sheetOpenT() {
    final size = _sheetCtrl.isAttached ? _sheetCtrl.size : _sheetInitial;
    return ((size - _sheetMin) / (_sheetDetail - _sheetMin)).clamp(0.0, 1.0);
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

  /// Closes the ride card (owner 2026-11-03: an X, not "Dismiss"). The
  /// ride STAYS on the map and in the list — it only leaves when someone
  /// reserves it.
  Widget _buildDismissX() {
    return GestureDetector(
      key: const ValueKey('sched-detail-close'),
      onTap: _hideSelectedTrip,
      child: const MapChipSurface(
        circle: true,
        width: 46,
        height: 46,
        child: Icon(Icons.close_rounded, color: Colors.white, size: 24),
      ),
    );
  }

  Widget _buildSearchAreaPill(S s) {
    return GestureDetector(
      onTap: _searchThisArea,
      // Same as the home map buttons (owner 2026-10-31): translucent grey,
      // soft 3D shadow, no blur — on iOS a blur draws a square around it.
      child: MapChipSurface(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        borderRadius: BorderRadius.circular(24),
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
      child: const MapChipSurface(
        circle: true,
        width: 44,
        height: 44,
        child: Icon(Icons.my_location_rounded, color: _gold, size: 20),
      ),
    );
  }

  /// The one CTA of detail mode. Gold, full width — and a child of the
  /// sheet, right below the card. It never floats over the map.
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

  /// "¿Reservar este viaje?" first (owner 2026-11-03, Lyft); only its
  /// Reservar takes the ride.
  Future<void> _confirmReserve(Map<String, dynamic> trip) async {
    final tripId = trip['id'] as int? ?? 0;
    final ok = await showReserveConfirm(
      context,
      pickupAt: _parseScheduledAt(trip),
      onViewPolicy: () => unawaited(showReservationPolicy(context, trip)),
    );
    if (!ok || !mounted) return;
    await _claimTrip(tripId);
  }

  /// The selected ride as the trip offer card, with Reservar under it as
  /// wide as the card (owner 2026-11-04: "la tarjeta tal cual como la
  /// tarjeta de oferta y botón de reserve mismo ancho que la tarjeta"): the
  /// full route on the map behind it. Reservar asks first (_confirmReserve).
  Widget _buildFloatingDetail(S s, Map<String, dynamic> trip) {
    final at = _parseScheduledAt(trip);
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final tripId = trip['id'] as int? ?? 0;
    return Column(
      key: ValueKey('sched-detail-${trip['id']}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ReservationOfferCard(
          trip: trip,
          whenLabel: at == null ? '' : _whenShort(s, at, isEs),
          driverPos: _driverPos,
        ),
        const SizedBox(height: 8),
        ReserveOfferButton(
          label: driverIsResting ? driverRestLabel : s.resvReserve,
          busy: _claimingId == tripId,
          resting: driverIsResting,
          onTap: driverIsResting
              ? showDriverRestRemaining
              : () => _confirmReserve(trip),
        ),
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
                s.schedMapRidesAvailable(trips.length),
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
  //  Ride card — the Cruise offer-card language: big fare + tips, minutes
  //  + miles, the exact offer-card address rail (gold ring + dot, gradient
  //  connector, hollow ring), rider row at the bottom. No $/hr estimate
  //  (user spec 2026-08-25). Navy, gold, neu radius, soft lift shadow.
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

  // Tables instead of DateFormat: the project never calls
  // initializeDateFormatting, so a Spanish-locale DateFormat throws.
  static const _kWeekEs = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
  static const _kWeekEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _kMonEs = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun',
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
  ];
  static const _kMonEn = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "Hoy · 5:55 PM" / "Mañana · 7:40 AM" / "jue 5 nov · 7:40 AM".
  String _whenShort(S s, DateTime at, bool isEs) {
    final now = DateTime.now();
    final diff = DateTime(at.year, at.month, at.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final time = DateFormat('h:mm a', 'en_US').format(at);
    final String day;
    if (diff == 0) {
      day = s.resDetailToday;
    } else if (diff == 1) {
      day = s.resDetailTomorrow;
    } else {
      day = isEs
          ? '${_kWeekEs[at.weekday - 1]} ${at.day} ${_kMonEs[at.month - 1]}'
          : '${_kWeekEn[at.weekday - 1]}, ${_kMonEn[at.month - 1]} ${at.day}';
    }
    return '$day · $time';
  }

  /// A ride in the list, as Lyft's scheduled-ride card (owner 2026-11-03):
  /// the pay; the pickup with its day and time; the drop-off with the
  /// ride's own minutes and miles; the rider ("Nombre I.", verified, ★).
  /// The selected one floats as the offer card (ReservationOfferCard).
  Widget _rideCard(Map<String, dynamic> trip) {
    final s = S.of(context);
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final isAirport = trip['is_airport'] == true;
    final airportCode = trip['airport_code'] as String?;

    // The ride's own route minutes/miles; a straight-line estimate (the
    // offer card's rule) only when the booking carried none.
    var tripMin = (trip['duration_minutes'] as num?)?.round();
    var tripMi = (trip['distance_miles'] as num?)?.toDouble();
    if (tripMin == null || tripMi == null) {
      final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
      final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
      final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
      final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();
      var km = 0.0;
      if (isValidLatLng(pickupLat, pickupLng) &&
          isValidLatLng(dropoffLat, dropoffLng)) {
        km = _havKm(LatLng(pickupLat!, pickupLng!),
            LatLng(dropoffLat!, dropoffLng!));
        if (!km.isFinite) km = 0;
      }
      tripMin ??= offerLegMinutes(km: km);
      tripMi ??= km * 0.621371;
    }

    final at = _parseScheduledAt(trip);
    final rider = nh.shortName((trip['rider_name'] ?? '').toString());
    final rating = (trip['rider_rating'] as num?)?.toDouble();
    final verified = trip['rider_verified'] == true;
    final hairline =
        Container(height: 1, color: Colors.white.withValues(alpha: 0.08));

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      // A lift of the sheet's own glass (2026-10-31) — an opaque card on a
      // frosted sheet reads as a grey slab again.
      decoration: glassInnerBox(
        radius: 20,
        borderColor: isAirport ? _airport.withValues(alpha: 0.25) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Row(
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
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.plusTips,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (isAirport && airportCode != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            ),
          ),
          hairline,
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: _lyftRail(
              pickupTitle: at == null ? '' : _whenShort(s, at, isEs),
              pickupAddr: pickup,
              dropTitle: '$tripMin min · ${tripMi.toStringAsFixed(1)} mi',
              dropAddr: dropoff,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: hairline,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rider.isEmpty ? s.riderFallback : rider,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (verified || rating != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (verified) ...[
                        // Gold, never the blue (owner 2026-11-04).
                        const Icon(Icons.verified_rounded,
                            color: _gold, size: 17),
                        const SizedBox(width: 4),
                        Text(
                          s.faceVerified,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (rating != null) ...[
                        Icon(Icons.stars_rounded,
                            color: Colors.white.withValues(alpha: 0.85),
                            size: 17),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pickup over drop-off on one gold rail: a hollow ring at the pickup, a
  /// ring with a dot at the drop-off (Lyft's card).
  Widget _lyftRail({
    required String pickupTitle,
    required String pickupAddr,
    required String dropTitle,
    required String dropAddr,
  }) {
    Widget ring({bool dot = false}) => Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _gold, width: 2.5),
          ),
          alignment: Alignment.center,
          child: dot
              ? Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: _gold),
                )
              : null,
        );
    Widget text(String title, String sub) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500)),
            Text(sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 15)),
          ],
        );
    Widget step({required bool last, required Widget content}) =>
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 20,
                child: Column(
                  children: [
                    const SizedBox(height: 3),
                    ring(dot: last),
                    if (!last)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.only(top: 2),
                          color: _gold.withValues(alpha: 0.8),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: last ? 0 : 14),
                  child: content,
                ),
              ),
            ],
          ),
        );
    return Column(
      children: [
        step(last: false, content: text(pickupTitle, pickupAddr)),
        step(last: true, content: text(dropTitle, dropAddr)),
      ],
    );
  }
}
