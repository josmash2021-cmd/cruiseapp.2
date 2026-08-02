import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../widgets/neu_style.dart';
import '../../models/lat_lng.dart';
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import '../../config/map_styles.dart';
import '../../config/page_transitions.dart';
import '../../config/route_observers.dart';
import '../../map/flat_map_projection.dart';
import '../../map/map_surface_coordinator.dart';
import '../../config/driver_colors.dart';
import '../../services/api_service.dart';
import '../../services/gps_service.dart';
import '../../services/heading_service.dart';
import '../../services/earnings_privacy.dart';
import '../../services/local_data_service.dart';
import '../../services/notification_service.dart';
import '../../services/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/prefs_cache.dart';
import '../home_screen.dart';
import '../welcome_screen.dart';
import '../../utils/mapbox_safe.dart';
import '../../services/map_controller_cache.dart';
import '../account_deactivated_screen.dart';
import 'driver_earnings_screen.dart';
import 'cruise_level_screen.dart';
import 'driver_trip_history_screen.dart';
import 'driver_menu_screen.dart';
import 'driver_online_screen.dart';
import 'driver_trip_accept_screen.dart';
import 'driver_inbox_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_vehicle_screen.dart';
import 'driver_documents_screen.dart';
import 'scheduled_rides_screen.dart';
import 'scheduled_ride_details_screen.dart';
import '../../l10n/app_localizations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/user_profile_photo.dart';
import '../../widgets/velocity_aware_panel.dart';
import '../../utils/responsive.dart';
import '../../utils/name_helper.dart' as nh;

/// Statuses the backend treats as the end of a trip.
///
/// Both spellings of cancelled are here on purpose. The canonical one is the
/// double-l (see CLAUDE.md), but rows written before that was settled still
/// carry the single-l form and a resume loop is not the place to be strict
/// about it.
const Set<String> _kFinishedTripStatuses = {
  'completed',
  'cancelled',
  'canceled',
  'expired',
  'no_show',
  'rejected',
  'failed',
};

/// ═══════════════════════════════════════════════════════════════
///  CRUISE DRIVER HOME — Premium dashboard with map, stats, go-online
/// ═══════════════════════════════════════════════════════════════
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key, this.returnFromTrip = false});

  /// When true the driver came back from an active-trip screen — keep them
  /// in the "still online" state so the bottom bar shows "Buscando viajes"
  /// and the main button reads REANUDAR.
  final bool returnFromTrip;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        VelocityAwarePanelMixin,
        RouteAware {
  static final _sqlPrefixRe = RegExp(r'^sql_');
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  // ignore: unused_field
  static const _surface = Color(0xFF1A1A1F);

  // ── Map ──
  mapbox.MapboxMap? _mapController;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotation? _myLocAnnot;
  LatLng? _currentLatLng;
  // ignore: unused_field
  bool _mapReady = false;
  // True while a trip screen covers us: our MapWidget is unmounted so the
  // trip screen owns the only live native Mapbox surface. Two surfaces at
  // once is the iOS crash the driver hit right after accepting — and, on
  // relaunch with an active trip, the crash loop that made the app take
  // several attempts to open. The map is remounted when the trip screen
  // pops.
  /// Starts suspended on purpose.
  ///
  /// The map used to mount unconditionally on the first build, which left
  /// the coordinator unaware that this screen holds a surface at all. On a
  /// cold start with an active trip that is fatal: home paints its map,
  /// _resumeActiveTrip pushes the trip screen, the trip screen asks for the
  /// surface, finds no registered holder and mounts immediately — two live
  /// surfaces, which is the relaunch crash loop. Claiming first costs a
  /// couple of frames on an empty coordinator and removes the case.
  bool _mapSuspended = true;

  /// Mini-map camera glued to the driver. Cleared when they drag it,
  /// restored ten seconds after they stop. See _onHomeMapPanned.
  bool _homeCameraFollowing = true;
  Timer? _homeReFollowTimer;

  /// A camera write is crossing the platform channel. See _writeHomeCamera.
  bool _camWriteBusy = false;

  /// Ticks once per frame the marker moved, so the Flutter overlay repaints
  /// with it.
  ///
  /// A CustomPaint only redraws when something tells it to, and nothing in
  /// the GPS path calls setState — the annotation was updated directly,
  /// which needs no rebuild. Left like that the overlay would have frozen
  /// at whatever bearing the last unrelated rebuild caught it at: the
  /// arrow would not have turned through a bend at all.
  ///
  /// A notifier rather than setState because setState rebuilds the entire
  /// screen — map card, earnings, panel — sixty times a second. This
  /// repaints one 64-pixel widget.
  final ValueNotifier<int> _markerFrame = ValueNotifier<int>(0);

  /// True once the native dot has been flushed to invisible under the
  /// overlay, so the per-frame path stops re-sending the same hide.
  bool _dotHiddenFlushed = false;
  final GoldLocationDot _goldDot = GoldLocationDot(heading: true);
  // Retries the first dot draw until it lands. _updateMyLocAnnotation() no-ops
  // until BOTH the annotation manager and the dot image exist, and the dot
  // ticker only fires when the position actually changes — so a driver sitting
  // still while the map view is still coming up would never get a dot at all.
  // Self-cancels as soon as the annotation exists.
  Timer? _dotCreateWatchdog;
  StreamSubscription<Position>? _posStream;

  /// Which way the arrow points, from the compass or the GPS course
  /// depending on whether the car is moving. See [HeadingService].
  final HeadingService _headingSource = HeadingService();
  StreamSubscription<double>? _headingSub;
  StreamSubscription<String>? _fcmTokenRefreshSub;

  // ── Stats ──
  double _todayEarnings = 0.0;
  int _todayTrips = 0;
  double _todayHours = 0.0;

  // ── Earnings pill (top bar) ──
  /// Which period the pill is showing: 0 = this week, 1 = today. Opens on
  /// today, same as the online screen's pill.
  /// Which period the top-bar figure is showing: 0 today, 1 week, 2 month.
  /// Opens on today — the number the driver checks between rides.
  int _earningsPage = 0;

  /// Previous values, so a refreshed figure counts up from the old one
  /// instead of snapping. First paint animates from zero.
  double _prevTodayEarnings = 0.0;
  double _prevWeekEarnings = 0.0;
  double _monthEarnings = 0.0;
  double _prevMonthEarnings = 0.0;

  /// True once a real figure — cached or fetched — has landed.
  ///
  /// Before it, every amount on this screen is the zero a double is born
  /// with, and the pill was printing it as \$0.00. That is a claim, and for
  /// a driver who worked yesterday it is a false one; the week and month
  /// figures were not even cached, so they made it on every single open.
  bool _statsEverLoaded = false;

  // ── Earnings panel ──
  double _weekEarnings = 0.0;

  /// Index = local hour 0..23, from the backend's hourly_earnings.
  List<double> _hourlySeries = const [];

  /// Seven entries, oldest first, paired with [_daySeriesLabels].
  List<double> _daySeries = const [];
  List<String> _daySeriesLabels = const [];

  /// Which tab the earnings chart is showing.
  bool _earningsWeekTab = false;

  /// Which way the last earnings swipe went, so the pages slide the way the
  /// thumb did instead of always from the same side.
  bool _earningsSwipeForward = true;
  String _driverName = 'Driver';
  String? _photoUrl;

  // ── Animations ──
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _glossCtrl;
  late AnimationController _radarCtrl; // gloss shimmer sweep
  late AnimationController _statsCtrl;
  late Animation<double> _statsAnim;
  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;

  // ── Bottom panel ──
  // Collapsed height shows only the drag handle + status header row
  // ("You're offline" / "Finding trips"); the stats & recommendations stay
  // hidden until the user swipes the panel up.
  // Collapsed height, sized against the WORST case so the Column can never
  // overflow its fixed-height parent (that throws a visible RenderFlex error,
  // not a graceful clip):
  //   handle       20  (10 top pad + 4 + 6 bottom pad)
  //   status row   60  (10 v pad + a 40 px icon + 10)
  //   button pad   16  (2 top + 14 bottom)
  //   button       54  (13 v pad + a 28 px status circle + 13) — the circle
  //                    only appears while navigating or when documents are
  //                    missing, but the panel cannot resize for that
  //   -------------
  //                150, plus 10 px of headroom.
  //
  // Was 92, from when the button floated over the map above the panel instead
  // of living inside it. Anyone changing the button's padding or font must
  // revisit this number.
  // Collapsed height. Trimmed from 160: the GO button briefly left the
  // panel and the space it had occupied stayed behind as a band of nothing
  // under "You're offline". The button is back inside, so the panel only
  // needs what it actually holds.
  /// Height of the collapsed sheet.
  ///
  /// Measured from what is actually in it rather than picked: the grab
  /// handle (10 + 4 + 6) and the status row (10 + 26 + 10), plus a little
  /// air, plus whatever the home indicator takes. At a flat 148 there were
  /// about seventy pixels of nothing under "You're offline" — a sheet that
  /// looked like it had content it was refusing to show.
  ///
  /// 60, down from 68 and 82 before that. The sheet has no slack left to
  /// give — its two rows come to 58 — so this last eight points came out of
  /// the padding around them instead: the grab handle's 10/6 is now 8/4 and
  /// the status row's 10 is now 8. Nothing was removed and nothing shrank;
  /// the sheet is simply drawn as tightly as its contents allow, which puts
  /// its top edge eight points further down the map.
  ///
  /// This is the floor. Anything below 58 clips the status row, and a
  /// fixed-height Column that overflows throws a visible RenderFlex error
  /// rather than clipping quietly — so if the text ever grows (a longer
  /// translation, a larger accessibility size), this number has to grow with
  /// it. It cannot be trimmed again.
  ///
  /// The home indicator's inset is still added on top, so this is 60 on the
  /// web and about 94 on a phone that reserves 34 for it. Do not fold that
  /// allowance into this constant: it is a different thing, it varies by
  /// device, and adding it here would put it back on devices that have none.
  // 52, down from 60. The sheet is bottom-anchored, so taking height
  // off it is what moves its top edge down the screen.
  static const double _panelBaseMinH = 52.0;
  double get _panelBaseH =>
      _panelBaseMinH + (MediaQuery.maybeOf(context)?.padding.bottom ?? 0);
  // Extra height reserved while the scheduled-rides banner is shown above the
  // header (finding-trips state). Without it the banner's ~46px eats into the
  // scroll viewport and clips the bottom rows on devices with small insets.
  static const double _panelBannerH = 50.0;
  // Travel for the spring drag (must stay > 0 — drag deltas divide by it).
  // Collapsed (92) + travel (400) = 492 expanded, which fits the full content
  // (status row + 3 stat cards + all 3 recommended rows) without clipping.
  /// Legacy fixed travel, kept only as the fallback when there is no
  /// MediaQuery yet. See [_panelTravelH].
  static const double _panelTravelFallbackH = 400.0;

  bool get _scheduledBannerVisible =>
      _isStillOnline && _activeTripData == null && _scheduledAvailableCount > 0;

  double get _panelCollapsedH =>
      _panelBaseH + (_scheduledBannerVisible ? _panelBannerH : 0);

  /// How far the panel travels when the driver drags it up.
  ///
  /// Was a flat 400 px. On a tall phone that stops the panel two thirds of
  /// the way up — it reads as a sheet that refused to finish opening, and
  /// the content below the fold can only be reached by scrolling inside a
  /// panel that looks like it has more room to give.
  ///
  /// Measured from the screen instead: open all the way to just under the
  /// status bar, so the gesture ends where the driver expects it to. Falls
  /// back to the old constant only before the first layout, when there is
  /// no MediaQuery to ask.
  double get _panelTravelH {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return _panelTravelFallbackH;
    // 44 px of map left visible at the top: enough to keep the sheet reading
    // as a sheet over a map, rather than as a new screen.
    final full = mq.size.height - mq.padding.top - 44;
    return math.max(_panelTravelFallbackH, full - _panelCollapsedH);
  }

  double get _panelExpandedH => _panelCollapsedH + _panelTravelH;
  bool _dragging = false;

  // ── Inbox unread count ──
  int _unreadCount = 0;

  // ── Verification ──
  bool _isVerified = false;

  // ── Bottom nav ──
  int _navIndex = 0;

  // ── Online state (driver pressed back but is still connected) ──
  bool _isStillOnline = false;
  // Prevents _resumeActiveTrip() from pushing DriverTripAcceptScreen twice.
  // Six different code paths call _resumeActiveTrip (initState, app resume,
  // polling, notification tap, refresh-complete, Firestore listener). Without
  // this guard two of them firing within the same frame stack two trip
  // screens on top of each other — the duplicate the rider reported.
  bool _resumingActiveTrip = false;
  Timer? _tripPollTimer;
  Timer? _statsRefreshTimer;
  int? _driverId;

  /// Shared uploader. Only used while the driver is online and standing on
  /// this screen — see _feedGpsUploads.
  final GpsService _gpsService = GpsService();
  Map<String, dynamic>? _activeTripData;

  // ── Scheduled rides banner ──
  int _scheduledAvailableCount = 0;
  Timer? _scheduledBannerTimer;

  // ── Vehicle document approval ──
  bool _vehicleDocsApproved = false;
  bool _hasExpiredDocs = false;
  /// A plate change is waiting on dispatch. Separate from the other two
  /// because the driver did this to themselves five minutes ago and the
  /// button should say so, not send them hunting through Documents for
  /// which paper is wrong.
  bool _plateChangePending = false;
  bool _docStatusLoaded = false;
  bool _isNavigatingToOnline = false; // true while navigating to online screen
  late AnimationController _btnColorCtrl;
  StreamSubscription<DocumentSnapshot>? _docApprovalSub;
  late Animation<double> _btnColorAnim;

  @override
  double get panelTravelHeight => _panelExpandedH - _panelCollapsedH;

  /// Bounce non-driver users back to the rider home screen.
  void _enforceDriverRole() {
    // The browser build has no login, so the stored mode is never 'driver'
    // and both driver screens used to eject to the rider home a few
    // milliseconds after mounting — two of the four screens worth reviewing,
    // unreachable.
    if (kIsWeb) return;

    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    initPanelAnimation();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
      ),
    );

    // Pulsing glow for Go Online button
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Gloss shimmer sweep across button
    _glossCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    // The radar gets its own clock, slower than everything else on the
    // button. Sharing the gloss sweep's 2.4 s made the rings hurry; a radar
    // that hurries reads as a loading spinner rather than as a beacon.
    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();

    // Red → gold color transition for Go Online button
    _btnColorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _btnColorAnim = CurvedAnimation(
      parent: _btnColorCtrl,
      curve: Curves.easeInOut,
    );

    // Stats panel entrance
    _statsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _statsAnim = CurvedAnimation(
      parent: _statsCtrl,
      curve: Curves.easeOutCubic,
    );

    // FAB scale
    _fabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fabScale = CurvedAnimation(parent: _fabCtrl, curve: Curves.elasticOut);

    if (widget.returnFromTrip) _isStillOnline = true;
    _goldDot.build(this, onFrame: () {
      if (!mounted) return;
      _markerFrame.value++;
      _followHomeCameraToDriver();
    }, () {
      // Update the Mapbox annotation directly — no setState needed (avoids rebuild storm)
      if (mounted) _syncDotAnnotation();
    });
    _startDotCreateWatchdog();
    _startHeadingSource();
    EarningsPrivacy.load();
    EarningsPrivacy.hidden.addListener(_onEarningsPrivacyChanged);
    _initLocation();
    _loadDriverData();
    _checkVerification().then((_) => _checkVehicleDocStatus());
    _startDocApprovalListener();
    // Defer account status check to post-frame — don't block UI startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAccountStatus();
    });
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 300),
      (_) => _checkAccountStatus(),
    );

    // Listen for photo updates from UserSession
    UserSession.photoNotifier.addListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.addListener(_onPhotoUpdated);

    // Resolve driver ID then check Firestore for active trip.
    // _checkBackendActiveTrip uses auth token (no driver ID needed) so runs in parallel.
    _resolveDriverIdThenRefresh();
    _checkBackendActiveTrip();
    _checkScheduledRideLockout();
    _registerFcmToken();

    // Observe lifecycle — restart polling when app returns from background
    WidgetsBinding.instance.addObserver(this);

    // Restore online state persisted from last session
    PrefsCache.instance.then((prefs) {
      if (!mounted) return;
      final wasOnline = prefs.getBool('driver_was_online') ?? false;
      if (wasOnline && !_isStillOnline) {
        setState(() => _isStillOnline = true);
        _startTripPolling();
      }
    });

    // Periodic stats refresh (every 60s) for real-time chips
    _statsRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshStats(),
    );

    // Poll scheduled ride count every 90s to update banner
    _refreshScheduledCount();
    _scheduledBannerTimer = Timer.periodic(
      const Duration(seconds: 90),
      (_) => _refreshScheduledCount(),
    );

    // Entrance animations
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _statsCtrl.forward();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fabCtrl.forward();
    });
  }

  void _onPhotoUpdated() {
    if (mounted) {
      setState(() {
        _photoUrl = UserSession.photoUrlNotifier.value.isNotEmpty
            ? UserSession.photoUrlNotifier.value
            : UserSession.photoNotifier.value;
      });
    }
  }

  /// Register this device for push, retrying until it lands.
  ///
  /// Every driver row in production holds fcm_token NULL, so no ride offer
  /// can ever wake a phone — and this method could not say why, because it
  /// ignored the permission result, ignored a null token, did not await the
  /// save, and buried the lot in `catch (_) {}`. Each failure mode now
  /// names itself in the log.
  ///
  /// The retry matters: the save is a no-op until the session JWT exists,
  /// and without a second attempt a device that got here a moment early
  /// stayed unregistered for the whole session.
  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;

      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[DriverHome] FCM: push permission DENIED by the user — '
            'no ride offers can be delivered while the app is closed');
        return;
      }

      final token = await messaging.getToken();
      if (token == null) {
        // Typically APNs not wired up on iOS: no APNs token, no FCM token.
        // A Firebase/Xcode configuration problem, not something the app can
        // recover from at runtime — but it must not be silent.
        debugPrint('[DriverHome] FCM: getToken() returned null — check APNs '
            'setup in Firebase and the Xcode capabilities');
        return;
      }

      var saved = await ApiService.saveFcmToken(token);
      for (var attempt = 1; !saved && attempt <= 3; attempt++) {
        await Future.delayed(Duration(seconds: attempt * 3));
        if (!mounted) return;
        debugPrint(
            '[DriverHome] FCM: retrying token registration ($attempt/3)');
        saved = await ApiService.saveFcmToken(token);
      }
      if (!saved) {
        debugPrint('[DriverHome] FCM: token could NOT be registered after 3 '
            'retries — this driver will not receive ride offers in background');
      }

      _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = messaging.onTokenRefresh.listen((t) {
        debugPrint('[DriverHome] FCM: token rotated, re-registering');
        ApiService.saveFcmToken(t);
      });
    } catch (e) {
      debugPrint('[DriverHome] FCM registration failed: $e');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      mapRouteObserver.subscribe(this, route);
    }
    // First claim. Post-frame so ModalRoute is settled — on a cold start
    // with an active trip the resume push may already be on its way, and
    // then this correctly declines to mount.
    if (!_claimedMapSurfaceOnce) {
      _claimedMapSurfaceOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_acquireMapSurface());
      });
    }
  }

  bool _claimedMapSurfaceOnce = false;

  // ── RouteAware: one live Mapbox surface at a time ──
  //
  // This screen sits at the bottom of the driver stack for the whole shift,
  // and every screen it opens (online offers, the trip screen) brings its
  // own native map. Our MapWidget stayed mounted underneath all of them —
  // two live Mapbox surfaces, which is the iOS crash the driver hits right
  // after accepting a ride. The explicit _suspendMap() calls only covered
  // the trip pushes we make ourselves; this covers every route that lands
  // on top of us, including the ones other screens push (the online screen
  // re-created by pushAndRemoveUntil at the end of a trip).
  //
  // The observer is typed on PageRoute, so bottom sheets and dialogs never
  // reach here — opening a sheet over the map must not tear it down.

  @override
  void didPushNext() {
    // Deliberately empty. We keep our map.
    //
    // Tearing it down for anything that covered us meant walking into the
    // menu or Earnings and back rebuilt the whole map: black card, then
    // tiles, then the location dot drawn again from scratch. The driver saw
    // their own arrow vanish and come back for a trip through a menu.
    //
    // It only ever existed as crash insurance, and the crash needs two live
    // surfaces. Menus have no map, so they cannot be the second one — and
    // every driver screen that DOES have one claims it through
    // MapSurfaceCoordinator, which revokes ours and waits for us before it
    // mounts. That claim was previously missing on the scheduled-rides
    // screens, which is why this guard had to come back for a while; the
    // list no longer mounts a map at all and the detail screen registers.
    // test/map_surface_registration_test.dart fails if a new one forgets.
    //
    // Holding a PlatformView under an opaque menu costs some memory; it
    // cannot cost a crash.
  }

  @override
  void didPopNext() => _unsuspendMap();

  /// Identifies this screen to [MapSurfaceCoordinator].
  static const String _kHomeMapSurfaceOwner = 'DriverHome';

  @override
  void dispose() {
    mapRouteObserver.unsubscribe(this);
    MapSurfaceCoordinator.instance.release(_kHomeMapSurfaceOwner);
    _fcmTokenRefreshSub?.cancel();
    disposePanelAnimation();
    _pulseCtrl.dispose();
    _glossCtrl.dispose();
    _radarCtrl.dispose();
    _btnColorCtrl.dispose();
    _statsCtrl.dispose();
    _fabCtrl.dispose();
    _goldDot.dispose();
    _dotCreateWatchdog?.cancel();
    _homeReFollowTimer?.cancel();
    _markerFrame.dispose();
    _posStream?.cancel();
    _headingSub?.cancel();
    _headingSource.dispose();
    EarningsPrivacy.hidden.removeListener(_onEarningsPrivacyChanged);
    _accountStatusTimer?.cancel();
    _tripPollTimer?.cancel();
    _statsRefreshTimer?.cancel();
    _docApprovalSub?.cancel();
    _scheduledBannerTimer?.cancel();
    UserSession.photoNotifier.removeListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.removeListener(_onPhotoUpdated);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The magnetometer is not free, and there is no arrow to turn behind a
    // locked screen. Dropped on the way out, picked up on the way back.
    if (state == AppLifecycleState.paused) {
      _headingSource.stop();
    } else if (state == AppLifecycleState.resumed && mounted) {
      _startHeadingSource();
    }
    if (state == AppLifecycleState.resumed && mounted) {
      // Safety net for the suspended map: routes removed with
      // removeRoute/pushAndRemoveUntil never fire didPopNext, so a stack
      // that unwound while we were backgrounded could leave us on top with
      // no map. _unsuspendMap no-ops unless we really are the top route.
      _unsuspendMap();
      // Always re-check vehicle doc approval when app comes back
      if (!_vehicleDocsApproved) _checkVehicleDocStatus();
      // Re-check scheduled ride lockout (driver may return from background)
      _checkScheduledRideLockout();
    }
    if (state == AppLifecycleState.resumed && _isStillOnline && mounted) {
      // App returned from background — refresh trip status then restart polling
      _refreshActiveTripStatus().then((_) {
        if (!mounted) return;
        if (_activeTripData != null) {
          // Active trip exists — go straight back to the trip screen
          _resumeActiveTrip();
          return;
        }
        _startTripPolling();
      });
    }
  }

  /// Drop the annotation handle and the flag that described it, together.
  ///
  /// [_dotHiddenFlushed] means "the annotation currently on the map has been
  /// flushed to invisible". Nulling the handle without clearing it left that
  /// sentence describing an annotation that no longer existed, and the next
  /// one created inherited the claim — so the hide was never sent and the
  /// native arrow sat visible under the Flutter one. Two arrows.
  ///
  /// The two always move together now, so there is no way to drop one and
  /// forget the other.
  void _dropLocAnnot() {
    _myLocAnnot = null;
    _dotHiddenFlushed = false;
  }

  bool _updatingLocAnnot = false;

  /// Write-then-flush update of the driver's gold-dot annotation.
  /// Same pattern as the rider home dot (1.0.2+376) — the previous
  /// full-await guard dropped every frame that landed mid-IPC, so the
  /// dot only moved ~1×/sec. Now we always write the freshest position
  /// into the annotation in memory (cheap), and only fire mgr.update()
  /// when the previous IPC finished. The next IPC always carries the
  /// latest position, no information lost.
  /// The heading to point the arrow at, or null when the fix has none.
  ///
  /// Geolocator reports -1 (and iOS sometimes NaN) when it cannot determine
  /// a course — parked, or no compass. Forwarding that would snap the arrow
  /// to north every time the driver stops at a light, so a fix without a
  /// heading leaves the last good one on screen. Speed gate for the same
  /// reason: a course computed from GPS noise at walking pace spins.
  /// Point the arrow with the compass, continuously.
  ///
  /// Nothing here waits for movement. The compass reports while the phone is
  /// sitting on a cradle, so the arrow turns with the car at a red light and
  /// turns in the driver's hand when they pick the phone up — which is the
  /// only time the arrow's direction is actually being read.
  ///
  /// setBearing rather than setTarget: this changes where the marker points,
  /// not where it is. SmoothMotion turns it at its own rate, so a compass
  /// that jumps two degrees does not make the arrow jump two degrees.
  void _startHeadingSource() {
    _headingSource.start();
    // Runs from initState and again on every resume — two subscriptions
    // would each call setBearing for the same reading.
    _headingSub?.cancel();
    _headingSub = _headingSource.stream.listen((deg) {
      if (!mounted) return;
      _goldDot.setBearing(deg);
    });
  }

  /// The switch lives on another screen, and this one is already mounted
  /// underneath it when it is flipped — so the chip is repainted from a
  /// listener rather than on the way back from a route.
  void _onEarningsPrivacyChanged() {
    if (mounted) setState(() {});
  }

  double? _usableHeading(Position p) {
    final h = p.heading;
    if (h.isNaN || h.isInfinite || h < 0) return null;
    if (p.speed.isFinite && p.speed < 0.7) return null; // ~2.5 km/h
    return h;
  }

  Future<void> _updateMyLocAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final bytes = _goldDot.currentBytes;
    if (bytes == null) return;

    final lat = _goldDot.lat ?? _currentLatLng?.latitude;
    final lng = _goldDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final point = safePoint(lng, lat);
    if (point == null) return;

    // First-time creation must be guarded — without it the per-frame
    // ticker would parallel-create N annotations and stack dots.
    if (_myLocAnnot == null) {
      if (_updatingLocAnnot) return;
      _updatingLocAnnot = true;
      // Born hidden if the overlay is already drawing the arrow.
      //
      // This is the double arrow the driver sees coming back from online.
      // Creation set no opacity at all, so a fresh annotation arrived fully
      // visible underneath an overlay that was already painting the same
      // marker — and the only thing that would have hidden it, the update
      // path below, is skipped on the very frame that creates it.
      //
      // It never recovered on a later frame either, because
      // _dotHiddenFlushed outlived the annotation it described: it was still
      // true from before the map was rebuilt, so the "flush the hide once"
      // branch decided the hide had already been sent for an annotation that
      // did not exist when it was.
      final bornHidden = _dotOverlayOwnsMarker;
      try {
        _myLocAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          // Matched to the Flutter overlay so the arrow does not change size
          // when the driver drags the map and the two swap over.
          iconSize: GoldLocationDot.driverIconSize,
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconOffset: [0, 0],
          // The badge is drawn pointing north; the heading is applied here.
          iconRotate: _goldDot.bearing,
          iconOpacity: bornHidden ? 0.0 : 1.0,
        ));
        // The flag describes *this* annotation, so it is set with it.
        _dotHiddenFlushed = bornHidden;
      } catch (_) {
        // creation failed — leave null so we retry next frame
      } finally {
        _updatingLocAnnot = false;
      }
      return;
    }

    // Update geometry + image every frame.
    //
    // Invisible while the Flutter overlay is drawing the marker — see
    // _dotOverlayOwnsMarker. Kept alive and kept current rather than
    // deleted, so the instant the driver pans away it is already at their
    // real coordinates with nothing to rebuild.
    final overlayOwns = _dotOverlayOwnsMarker;
    try {
      _myLocAnnot!.geometry = point;
      _myLocAnnot!.image = bytes;
      _myLocAnnot!.iconRotate = _goldDot.bearing;
      _myLocAnnot!.iconSize = GoldLocationDot.driverIconSize;
      _myLocAnnot!.iconOpacity = overlayOwns ? 0.0 : 1.0;
      // One flush to hide it, then leave the channel to the camera.
      if (!overlayOwns || !_dotHiddenFlushed) {
        _dotHiddenFlushed = overlayOwns;
        mgr.update(_myLocAnnot!).catchError((_) {
          _dropLocAnnot();
        });
      }
    } catch (_) {
      _dropLocAnnot();
    }
  }

  /// Keep the map under the driver.
  ///
  /// Deliberately NOT inside _updateMyLocAnnotation. It used to be, at the
  /// very bottom, behind five guards that all concern the Mapbox annotation:
  /// no annotation manager yet, no rasterised icon yet, the frame the
  /// annotation is first created on. Any of those and the camera silently
  /// stopped following — the driver drove off the edge of a map that had
  /// decided not to move, for a reason that had nothing to do with the
  /// camera.
  ///
  /// That coupling was survivable while the annotation *was* the marker.
  /// Now the marker is a Flutter overlay that draws regardless, so the only
  /// thing those guards could still block is the one job that has to keep
  /// working. Driven from the motion frame instead.
  /// Keep the position uploads fed while the driver sits on this screen.
  ///
  /// GpsService uploads on its own timers from the last position it was
  /// given — so leaving it running without feeding it is worse than stopping
  /// it: it republishes one stale coordinate forever, and a car frozen at a
  /// real-looking address is harder to spot than one that vanished.
  ///
  /// The online screen fed it; this one never did, because until now the
  /// driver could not be online and standing here at the same time. They can:
  /// the Home button on the online screen is explicitly a look-at-home, not
  /// a go-off-shift.
  void _feedGpsUploads(LatLng pos, double heading, double speed) {
    // An active trip counts even if the online flag has not caught up.
    //
    // A driver who walks back to this screen mid-ride has a passenger
    // watching their car on a map. That car is drawn from these uploads and
    // from nothing else, so the flag being a beat behind is not a reason to
    // stop feeding it — the trip is.
    if (!_isStillOnline && _activeTripData == null) return;
    final id = _driverId;
    if (id == null) return;
    _gpsService.startTracking(id.toString()); // no-op once already tracking
    _gpsService.updatePosition(pos, heading, speed);
  }

  void _followHomeCameraToDriver() {
    if (!mounted || !_homeCameraFollowing) return;
    final lat = _goldDot.lat ?? _currentLatLng?.latitude;
    final lng = _goldDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;
    final point = safePoint(lng, lat);
    if (point == null) return;
    _writeHomeCamera(
      mapbox.CameraOptions(
        center: point,
        zoom: 16.0,
        pitch: 0.0,
        bearing: 0.0,
      ),
    );
  }

  /// Push one camera frame, dropping any produced while the previous write
  /// is still crossing the channel. An un-awaited setCamera per tick queues
  /// up behind a busy platform thread, and a backlog lands in bursts —
  /// which is the stutter. Every frame is recomputed, so a dropped one
  /// carries nothing the next does not.
  void _writeHomeCamera(mapbox.CameraOptions options) {
    final map = _mapController;
    if (map == null) return;
    if (_camWriteBusy) return;
    _camWriteBusy = true;
    try {
      map.setCamera(options).then((_) {
        _camWriteBusy = false;
      }).catchError((Object _) {
        _camWriteBusy = false;
      });
    } catch (_) {
      _camWriteBusy = false;
    }
  }

  /// The camera as Mapbox last reported it. Pushed to us by
  /// onCameraChangeListener, so reading it costs nothing per frame.
  mapbox.CameraState? _homeCamState;

  /// True while the Flutter overlay draws the marker instead of Mapbox.
  ///
  /// Not only while the camera is following any more: with the camera state
  /// in hand we can work out the driver's pixel ourselves for any flat view,
  /// so the marker stays smooth after the driver pans or zooms too. The
  /// annotation only takes back over where the arithmetic would be a guess —
  /// a tilted or rotated camera. See FlatMapProjection.
  bool get _dotOverlayOwnsMarker {
    if (_mapSuspended || _goldDot.lat == null) return false;
    if (_homeCameraFollowing) return true;

    // Order matters here, and it did not before.
    //
    // This used to end at `return _homeDotOffset != null`, and that offset
    // was null for two situations that have nothing in common: the marker is
    // off screen, and we cannot work out where the marker is. Both handed
    // the job to the Mapbox annotation — which is a fine answer for the
    // first and a bad one for the second, because the moments when the
    // projection has no answer are exactly the moments the annotation does
    // not exist either. A map that has just been rebuilt has no annotation
    // and has not sent a camera event yet, and in that window nothing at all
    // drew the arrow.
    final spot = _homeDotSpot;
    if (spot.at != null) return true; // we know the pixel — draw there
    if (!spot.known)
      return true; // we do not know — draw centred, never nothing
    // Known, and outside the viewport. The driver has panned away from
    // themselves, so there is genuinely nothing to draw. The annotation is
    // anchored in map space and is just as absent from the view, so this is
    // not a case of handing the marker to something that might drop it.
    return false;
  }

  /// The marker's pixel, and whether that answer can be trusted.
  ///
  /// `known: false` means the projection could not be computed at all — no
  /// camera event has arrived yet, the viewport has not been measured, or
  /// [FlatMapProjection] refused a tilted view. That is a different thing
  /// from a computed answer that lands off screen, and the two used to be
  /// the same `null`. Telling them apart is what lets the overlay draw
  /// through the gaps instead of standing aside in them.
  ///
  /// While following, the camera centres on the driver every frame, so the
  /// marker is the middle of the viewport by definition and no projection is
  /// needed: `at: null, known: true`.
  ({Offset? at, bool known}) get _homeDotSpot {
    if (_homeCameraFollowing) return (at: null, known: true); // centred
    final cam = _homeCamState;
    final lat = _goldDot.lat, lng = _goldDot.lng;
    final size = _homeMapSize;
    if (cam == null || lat == null || lng == null || size == null) {
      return (at: null, known: false);
    }
    final c = cam.center.coordinates;
    final off = FlatMapProjection.screenOffsetFlat(
      target: LatLng(lat, lng),
      cameraCenter: LatLng(c.lat.toDouble(), c.lng.toDouble()),
      zoom: cam.zoom,
      bearingDeg: cam.bearing,
      pitchDeg: cam.pitch,
      viewport: size,
    );
    if (off == null) return (at: null, known: false);
    if (!FlatMapProjection.isOnScreen(off, size)) {
      return (at: null, known: true); // off screen, and we are sure of it
    }
    return (at: off, known: true);
  }

  /// Where to draw the marker, or null for "centre it".
  Offset? get _homeDotOffset => _homeDotSpot.at;

  /// Size of the map box, measured from its own layout rather than assumed.
  Size? _homeMapSize;

  /// The driver dragged the mini map: stop following so it stays where they
  /// put it, and come back ten seconds after they stop.
  void _onHomeMapPanned() {
    _homeReFollowTimer?.cancel();
    _homeReFollowTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      setState(() => _homeCameraFollowing = true);
    });
    if (!_homeCameraFollowing) return;
    setState(() => _homeCameraFollowing = false);
  }

  /// Update the gold dot PointAnnotation with latest interpolated position + frame.
  void _syncDotAnnotation() {
    _updateMyLocAnnotation();
  }

  /// Poll until the dot annotation actually exists, then stop.
  /// Covers the startup race where the GPS fix arrives before the map's
  /// annotation manager (or the rendered dot image) is ready.
  void _startDotCreateWatchdog() {
    _dotCreateWatchdog?.cancel();
    _dotCreateWatchdog = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted) {
        t.cancel();
        _dotCreateWatchdog = null;
        return;
      }
      // Runs for the life of the screen, not until the marker first appears.
      //
      // It used to cancel itself the moment `_myLocAnnot` was non-null, which
      // made it a create watchdog and nothing else — so every way the marker
      // could be lost *after* that first success had no one watching. The
      // bitmap can be dropped later (the GPU context goes while backgrounded,
      // memory pressure), the annotation can be destroyed with the platform
      // view on any Android resume, and by then the only thing that would
      // have rebuilt either had already retired.
      //
      // The online screen's watchdog never stopped, and that is the one that
      // did not have this problem. Two seconds of a null check costs nothing.
      //
      // Rasterising the dot bitmap can fail (GPU context lost, OOM) and
      // GoldLocationDot leaves currentBytes null when it does — every draw
      // is then a silent no-op. Same retry the rider home does in
      // _scheduleHomeDotRetry.
      if (!_goldDot.isReady) {
        await _goldDot.build(this, onFrame: () {
          if (!mounted) return;
          _markerFrame.value++;
          _followHomeCameraToDriver();
        }, () {
          if (mounted) _syncDotAnnotation();
        });
        if (!mounted) return;
      }
      // Nothing to write into yet, or the handle died with its map: either
      // way _updateMyLocAnnotation creates a fresh one.
      if (_myLocAnnot == null) {
        _updateMyLocAnnotation();
        return;
      }
      // Otherwise nudge the Flutter overlay. The ticker only fires on frames
      // where the marker moved, so a driver standing still produces none —
      // and this is then the only thing keeping the arrow repainted. It does
      // not need the bitmap: the overlay paints shapes, and falls back to
      // the hand-drawn badge if even the artwork is missing.
      _markerFrame.value++;
    });
  }

  // ═══════════════════════════════════════════════════
  //  ACCOUNT STATUS CHECK
  // ═══════════════════════════════════════════════════
  Timer? _accountStatusTimer;

  Future<void> _checkAccountStatus() async {
    try {
      final status = await ApiService.getAccountStatus()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (status == 'blocked' || status == 'deleted') {
        _accountStatusTimer?.cancel();
        await UserSession.logout();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const WelcomeScreen()),
          (_) => false,
        );
      } else if (status == 'deactivated') {
        _accountStatusTimer?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const AccountDeactivatedScreen()),
          (_) => false,
        );
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════
  //  LOCATION
  // ═══════════════════════════════════════════════════
  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationServicesDisabledMsg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return;
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationRequiredForDriver),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }

      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        _currentLatLng = LatLng(last.latitude, last.longitude);
        // Last-known fix: position only. Its heading is whatever the phone
        // was doing whenever this was recorded, which may be yesterday.
        _goldDot.setTarget(last.latitude, last.longitude);
        setState(() {});
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // bestForNavigation, not high.
          //
          // geolocator's `high` is ten metres on iOS
          // (kCLLocationAccuracyNearestTenMeters), which is the width of a
          // road plus its pavement — so a driver standing in the street was
          // being placed on the kerb and the app was not wrong by its own
          // standards. Every other driver stream in the app already asks for
          // bestForNavigation through driverLocationSettings; this screen was
          // the one that did not, and it is the screen they look at while
          // parked and checking the marker.
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      _currentLatLng = LatLng(pos.latitude, pos.longitude);
      _goldDot.setTarget(pos.latitude, pos.longitude, accuracyM: pos.accuracy);
      _headingSource.onFix(pos);
      setState(() {});
      _updateMyLocAnnotation();
      _mapController?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(
                  _currentLatLng!.longitude, _currentLatLng!.latitude)),
          zoom: 16,
          pitch: 0,
          bearing: 0,
        ),
        mapbox.MapAnimationOptions(duration: 800),
      );

      // ── Real-time GPS stream ──
      // distanceFilter: 2 -> accept fixes every 2 meters.
      // SmoothMotion interpolates smoothly between fixes.
      // Balance between accuracy and battery life.
      _posStream?.cancel();
      _posStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 2,
        ),
      ).listen((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        _currentLatLng = ll;
        // Position here, direction separately.
        //
        // The bearing used to ride along with the fix, which meant the arrow
        // could only turn when the driver moved. It comes from the compass
        // now — see the _headingSource subscription in initState — and this
        // hands the fix over so the service can decide whether the car is
        // going fast enough for the GPS course to be the better answer.
        _goldDot.setTarget(ll.latitude, ll.longitude, accuracyM: p.accuracy);
        _headingSource.onFix(p);
        // Keep publishing while online — the driver can be on this screen
        // mid-shift now. See _feedGpsUploads.
        //
        // The rider watches this to see which way the car is pointing, so it
        // gets the compass too: a driver waiting at the pickup used to be
        // published as heading 0 — facing north whichever way they had
        // actually parked.
        _feedGpsUploads(
          ll,
          _headingSource.value ?? _usableHeading(p) ?? 0,
          p.speed,
        );
        debugPrint(
            '[DriverHome] GPS update: ${ll.latitude.toStringAsFixed(5)},${ll.longitude.toStringAsFixed(5)} '
            'speed=${p.speed.toStringAsFixed(1)}m/s accuracy=${p.accuracy.toStringAsFixed(1)}m');
        // Camera follow is handled per dot-tick in _updateMyLocAnnotation
        // (instant setCamera at ~30fps). The old 800ms-throttled flyTo
        // restarted its animation on every fix and made the map — and the
        // dot relative to the screen — visibly jump.
      });
    } catch (_) {}
  }

  Future<void> _loadDriverData() async {
    // Cache-first: show last-known data instantly
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final cachedName = prefs.getString('driver_cached_name');
    final cachedEarnings = prefs.getDouble('driver_cached_earnings');
    final cachedWeek = prefs.getDouble('driver_cached_earnings_week');
    final cachedMonth = prefs.getDouble('driver_cached_earnings_month');
    final cachedTrips = prefs.getInt('driver_cached_trips');
    final cachedUserId = prefs.getString('driver_cached_user_id');
    final cachedDay = prefs.getInt('driver_cached_earnings_day');
    final currentUserId = (await ApiService.getCurrentUserId()
            .timeout(const Duration(seconds: 15)))
        ?.toString();
    // Only use cache if it belongs to the current driver (prevents
    // showing another driver's earnings after logout/login) *and* to the
    // current day.
    //
    // The day was not checked. The cache holds a figure captioned "Today",
    // so the first thing the driver saw every morning was yesterday's total
    // wearing today's label — and it stayed there until a network round trip
    // came back to correct it, which on a bad signal is a long time and on
    // no signal is forever.
    final cacheValid = currentUserId != null &&
        currentUserId == cachedUserId &&
        cachedDay == _localDayStamp();
    if (cachedName != null && mounted && cacheValid) {
      setState(() {
        _driverName = cachedName;
        _todayEarnings = cachedEarnings ?? 0.0;
        _weekEarnings = cachedWeek ?? 0.0;
        _monthEarnings = cachedMonth ?? 0.0;
        _todayTrips = cachedTrips ?? 0;
        // The pill has something true to show, so it may stop hedging.
        _statsEverLoaded = true;
      });
    } else if (!cacheValid && mounted) {
      // Reset to zero when switching drivers
      setState(() {
        _todayEarnings = 0.0;
        _weekEarnings = 0.0;
        _monthEarnings = 0.0;
        _todayTrips = 0;
      });
    }

    // Background refresh from API — use dashboard (single call)
    final dashboard = await ApiService.getDashboard().catchError((_) => null);
    final notifs = await ApiService.getNotifications()
        .catchError((_) => <Map<String, dynamic>>[]);

    if (!mounted) return;
    final profile = dashboard?['profile'] as Map<String, dynamic>?;
    final driverData = dashboard?['driver_data'] as Map<String, dynamic>?;
    final earnings = driverData?['earnings'] as Map<String, dynamic>? ?? {};

    setState(() {
      if (profile != null) {
        final firstName = profile['first_name'] ?? 'Driver';
        final lastName = profile['last_name'] ?? '';
        _driverName = lastName.isNotEmpty
            ? '$firstName ${lastName[0].toUpperCase()}.'
            : firstName;
        if (UserSession.photoNotifier.value.isNotEmpty) {
          _photoUrl = UserSession.photoNotifier.value;
        } else {
          final serverPhoto = profile['photo_url']?.toString() ?? '';
          if (serverPhoto.isNotEmpty) {
            _photoUrl = serverPhoto.startsWith('http')
                ? serverPhoto
                : '${ApiService.publicBaseUrl}$serverPhoto';
          }
        }
      }
      // Today's figures do not come from here.
      //
      // /auth/dashboard has no idea what day it is for this driver — it takes
      // no timezone — and what it calls `earnings.total` is
      // `user.total_earnings`, the driver's lifetime figure, falling back to
      // a seven-day sum. `trips_count` is the length of a seven-day query
      // capped at twenty rows, and `online_hours` is not in the response at
      // all. All three were being written into fields labelled "Today" on
      // screen, which is why the card kept showing work from days ago and
      // never reset at midnight.
      //
      // _refreshStats below asks /drivers/earnings?period=today with the
      // phone's tz_offset, which is the endpoint that actually computes a
      // driver's local day. It is the only thing that writes these now.
      _unreadCount = notifs.where((n) => n['is_read'] != true).length;
    });

    // And the chart's own numbers.
    //
    // This load takes the totals out of the same response and stops there,
    // so the bars and the week were left to a 60-second timer: the driver
    // opened the panel to an empty axis, and the Week tab to nothing at all
    // — no bars, no day labels — until a minute had passed. Most of the time
    // they had closed it again by then, which is why the chart looked like
    // it simply did not work.
    //
    // _refreshStats fetches both periods and fills both series. The 'today'
    // call lands on the 10-second response cache this load just filled, so
    // it costs one extra request.
    unawaited(_refreshStats());

    // Update local cache
    prefs.setString('driver_cached_name', _driverName);
    prefs.setDouble('driver_cached_earnings', _todayEarnings);
    // Week and month too. The pill swipes between all three, and only
    // today's was ever kept — so the other two opened at zero every time
    // and printed it as a figure.
    prefs.setDouble('driver_cached_earnings_week', _weekEarnings);
    prefs.setDouble('driver_cached_earnings_month', _monthEarnings);
    prefs.setInt('driver_cached_trips', _todayTrips);
    // Stamped with the day it describes, so tomorrow cannot read it as its
    // own. Local date, because "today" is the driver's day, not UTC's.
    prefs.setInt('driver_cached_earnings_day', _localDayStamp());
    if (currentUserId != null) {
      prefs.setString('driver_cached_user_id', currentUserId);
    }
  }

  /// The driver's current local day, as yyyymmdd.
  ///
  /// The same shape and the same key the online screen already used, on
  /// purpose. Both screens cache today's earnings under
  /// `driver_cached_earnings` and stamp it with
  /// `driver_cached_earnings_day`, and a first pass at this wrote a String
  /// where the other wrote an int — same key, different type, so each one's
  /// read of the other's write came back null and the cache silently
  /// stopped working on whichever screen was opened second.
  ///
  /// Local rather than UTC: a driver in Miami starts a new day five hours
  /// before UTC does, and it is their midnight the card resets at.
  int _localDayStamp() {
    final d = DateTime.now();
    return d.year * 10000 + d.month * 100 + d.day;
  }

  /// Lightweight periodic refresh for the 3 stats chips (no name/photo reload).
  Future<void> _refreshStats() async {
    try {
      // Both periods, in parallel. The panel shows today and this week side by
      // side, so fetching them one after the other would show a stale week
      // total for a whole round trip. Each falls back to an empty map rather
      // than taking the other down with it.
      // A swallowed failure and a genuinely empty response used to look the
      // same here, and the pill hedges on both — so a driver whose circuit
      // breaker had tripped saw "$—" with nothing anywhere to say why.
      Future<Map<String, dynamic>> fetch(String period) =>
          ApiService.getDriverEarnings(period: period).catchError((e) {
            debugPrint('[DriverHome] earnings($period) failed: $e');
            return <String, dynamic>{};
          });

      final results = await Future.wait([
        fetch('today'),
        fetch('week'),
        fetch('month'),
      ]);
      if (!mounted) return;
      final today = results[0];
      final week = results[1];
      final month = results[2];

      // Coerced, never cast: a hard `as num` on a payload field throws on the
      // first backend that sends a numeric string, and this runs on a timer.
      double dbl(dynamic v, double fallback) {
        final n = v is num ? v : num.tryParse(v?.toString() ?? '');
        final d = n?.toDouble();
        return (d != null && d.isFinite) ? d : fallback;
      }

      List<double> series(dynamic raw) {
        if (raw is! List) return const [];
        return raw.map((e) => dbl(e, 0.0)).toList(growable: false);
      }

      setState(() {
        // Where the pill's count-up starts from — captured before the new
        // figures land, or every refresh would animate from itself.
        _prevTodayEarnings = _todayEarnings;
        _prevWeekEarnings = _weekEarnings;
        _prevMonthEarnings = _monthEarnings;
        _todayEarnings = dbl(today['total'], _todayEarnings);
        _todayTrips = (today['trips_count'] as num?)?.toInt() ?? _todayTrips;
        _todayHours = dbl(today['online_hours'], _todayHours);
        _weekEarnings = dbl(week['total'], _weekEarnings);
        _monthEarnings = dbl(month['total'], _monthEarnings);
        // Only a real response lifts the hedge. All three empty means all
        // three threw — the figures on screen are still unknown, not zero,
        // and the next tick will try again.
        if (today.isNotEmpty || week.isNotEmpty || month.isNotEmpty) {
          _statsEverLoaded = true;
        } else {
          debugPrint('[DriverHome] all three earnings calls failed — '
              'the pill keeps hedging until one lands');
        }

        // Keep the last good series when a response arrives without one —
        // an empty chart reads as "you earned nothing", which is a lie the
        // driver will notice.
        final h = series(today['hourly_earnings']);
        if (h.length == 24) _hourlySeries = h;
        // Bars and labels are updated together or not at all. Guarding them
        // separately let an empty response blank the labels while the previous
        // bars stayed on screen — seven unlabelled columns.
        final d = series(week['daily_earnings']);
        final labels = week['day_labels'];
        if (d.isNotEmpty && labels is List && labels.length == d.length) {
          _daySeries = d;
          _daySeriesLabels =
              labels.map((e) => e?.toString() ?? '').toList(growable: false);
        }
      });
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════
  //  IDENTITY VERIFICATION GATE
  // ═══════════════════════════════════════════════════
  Future<void> _checkVerification() async {
    // Driver reached this screen after passing splash/login approval gates,
    // so they are already verified. Sync local status to match.
    await LocalDataService.setDriverApprovalStatus('approved');
    if (mounted) setState(() => _isVerified = true);
  }

  Future<bool> _ensureVerified() async {
    if (_isVerified) return true;
    // Driver is on home screen — they passed all gates already
    if (mounted) setState(() => _isVerified = true);
    return true;
  }

  // ═══════════════════════════════════════════════════
  //  VEHICLE DOCUMENT STATUS CHECK
  // ═══════════════════════════════════════════════════
  Future<void> _checkVehicleDocStatus() async {
    try {
      final result =
          await ApiService.canGoOnline().timeout(const Duration(seconds: 15));
      if (!mounted) return;

      final canGo = result['can_go_online'] == true;
      final expired = result['has_expired_docs'] == true;
      final platePending = result['plate_change_pending'] == true;

      // Sync approval status locally
      if (result['approved'] == true) {
        await LocalDataService.setDriverApprovalStatus('approved');
      }
      if (!mounted) return;

      setState(() {
        _vehicleDocsApproved = canGo;
        _hasExpiredDocs = expired;
        _plateChangePending = platePending;
        _docStatusLoaded = true;
      });
      _btnColorCtrl.value = 1.0;
    } catch (e) {
      debugPrint('[DriverHome] _checkVehicleDocStatus error: $e');
      // On error, fail-closed: require docs to be explicitly approved
      if (mounted) {
        setState(() {
          _vehicleDocsApproved = false;
          _docStatusLoaded = true;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  REAL-TIME DOC APPROVAL LISTENER
  //  Fires immediately when admin approves docs in Firestore,
  //  so the driver doesn't need to restart the app.
  // ═══════════════════════════════════════════════════
  Future<void> _startDocApprovalListener() async {
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (e) {
      debugPrint('[DriverHome] Firebase Auth for doc listener failed: $e');
      return;
    }

    final user = await UserSession.getUser();
    final userIdStr = user?['userId'] ?? '';
    final userIdInt = int.tryParse(userIdStr) ?? 0;
    if (userIdInt <= 0) return;

    final docId = 'sql_$userIdInt';
    _docApprovalSub?.cancel();
    _docApprovalSub = FirebaseFirestore.instance
        .collection('verifications')
        .doc(docId)
        .snapshots()
        .listen((snap) {
      if (!mounted || !snap.exists) return;
      final data = snap.data() ?? {};
      final status = data['status'] as String? ??
          data['verificationStatus'] as String? ??
          data['approvalStatus'] as String? ??
          '';
      final isApproved = status == 'approved' ||
          status == 'active' ||
          data['isVerified'] == true ||
          data['isApproved'] == true;
      if (isApproved && !_vehicleDocsApproved) {
        debugPrint(
            '[DriverHome] Firestore doc-approval listener fired — refreshing doc status');
        _checkVehicleDocStatus();
      }
    }, onError: (e) {
      debugPrint('[DriverHome] Doc approval listener error: $e');
    });
  }

  // ═══════════════════════════════════════════════════
  //  GO ONLINE — navigate to DriverOnlineScreen
  // ═══════════════════════════════════════════════════
  void _goOnline() async {
    // Show immediate feedback — button will display loading state
    setState(() => _isNavigatingToOnline = true);

    // _ensureVerified is always synchronous — inline the check
    if (!_isVerified) setState(() => _isVerified = true);

    // If doc status has loaded, enforce doc gates synchronously (no await)
    if (_docStatusLoaded) {
      // If docs expired, navigate to documents page to re-upload
      if (_hasExpiredDocs) {
        HapticService.mediumImpact();
        await Navigator.of(context).push(
          slideFromRightRoute(const DriverDocumentsScreen()),
        );
        if (mounted) await _checkVehicleDocStatus();
        return;
      }

      // If vehicle docs not approved, navigate to documents page
      if (!_vehicleDocsApproved) {
        HapticService.mediumImpact();
        await Navigator.of(context).push(
          slideFromRightRoute(const DriverDocumentsScreen()),
        );
        if (mounted) await _checkVehicleDocStatus();
        return;
      }
    }
    // else: doc status not loaded yet — don't block. The online screen's
    // _verifyAndGoOnline() will handle the backend check in background.
    // Driver already passed splash/login approval gates to reach this screen.

    // Quick check: if we already know there's an active trip, resume immediately
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }

    // Resolve driver ID in background — don't block navigation
    if (_driverId == null) {
      unawaited(_resolveDriverId());
    }

    // Navigate immediately — no waiting on API calls.
    //
    // 2026-04-27 freeze fix:
    //   The old order was haptic + sound + push, which stacked three
    //   MethodChannel round-trips on the same frame the route transition
    //   was supposed to start animating. Result: ~1s freeze the moment
    //   the driver tapped Go Online.
    //
    //   New order: kick off the navigation FIRST (its animation now owns
    //   the next frames cleanly), then schedule haptic + sound on the
    //   post-frame callback so they cross the platform boundary AFTER
    //   the route transition has begun.
    // Our map goes now, before the push — not when the next screen asks.
    //
    // The handover was correct but tight. This screen keeps its map on
    // purpose, so during the 420 ms transition it is still up while the
    // online screen is being built; the coordinator then revokes ours and
    // that screen waits. Everything hangs on that wait being honoured on a
    // platform thread already busy standing up a PlatformView, and two live
    // Mapbox surfaces close the app on iOS.
    //
    // Starting the teardown here removes the overlap instead of sequencing
    // it: by the time the online screen asks, our surface has been gone for
    // most of the transition. The coordinator still runs and still waits —
    // this is a margin on top of it, not a replacement.
    //
    // Nothing is awaited, so the push is not delayed. The cost is that the
    // map behind the transition is a solid card for those 420 ms, which
    // costs nothing the driver can act on; the crash costs the shift.
    _suspendMap();

    final pushFuture = Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (ctx, anim1, anim2) => DriverOnlineScreen(
            photoUrl: _photoUrl, initialPos: _currentLatLng, initialHeading: 0),
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved =
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
                child: child,
              ),
            ),
          );
        },
      ),
    );
    // No chime. Removed, not deferred again.
    //
    // Three rounds went into keeping it: fire it after the push, then defer it
    // 300 ms, then swap play(Source) for resume() on a pre-warmed player. It
    // still stuck, because the audio engine's work happens on the platform
    // thread and that is the same thread the route transition and the Mapbox
    // surface on the next screen both need. Every fix moved the stall, none of
    // them removed it. A sound worth one second of frozen UI on the busiest
    // button in the driver app does not exist.
    //
    // The haptic stays and stays deferred — the engine can cold-start slowly
    // on iOS too, so it waits for the transition to be most of the way done.
    Future.delayed(const Duration(milliseconds: 300), () {
      HapticService.lightImpact();
    });
    final result = await pushFuture;
    if (!mounted) return;
    setState(() => _isNavigatingToOnline = false);
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
    PrefsCache.instance
        .then((p) => p.setBool('driver_was_online', stillOnline));
    _refreshStats();
    if (stillOnline) {
      _startTripPolling();
      // Immediately check for an active trip so the Resume button appears
      // without waiting for the 15-second poll interval.
      unawaited(_refreshActiveTripStatus());
    } else {
      _stopTripPolling();
    }
  }

  /// Resolve driver ID (used by polling and other callers).
  Future<void> _resolveDriverId() async {
    try {
      final id = await ApiService.getCurrentUserId();
      if (id != null && mounted) {
        _driverId = id;
      }
    } catch (_) {}
  }

  /// Resolve driver ID first, THEN check Firestore for active trip.
  /// This prevents the race where _refreshActiveTripStatus runs with null _driverId.
  Future<void> _resolveDriverIdThenRefresh() async {
    await _resolveDriverId();
    if (_driverId != null && mounted) {
      await _refreshActiveTripStatus();
      // Auto-navigate to active trip on cold start (same as background resume)
      if (_activeTripData != null && mounted) {
        _resumeActiveTrip();
      }
    }
  }

  void _startTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_isStillOnline) {
        _tripPollTimer?.cancel();
        return;
      }
      _pollForTrips();
    });
  }

  void _stopTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = null;
  }

  Future<void> _pollForTrips() async {
    if (_driverId == null) {
      await _resolveDriverId();
      if (_driverId == null) return;
    }
    await _refreshActiveTripStatus();
    if (_activeTripData != null) {
      // Active trip found — auto-resume it immediately
      _stopTripPolling();
      if (mounted) _resumeActiveTrip();
      return;
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      if (!mounted || !_isStillOnline) return;
      if (offers.isNotEmpty) {
        // Trip arrived! Redirect to online screen
        _stopTripPolling();
        HapticService.heavyImpact();
        _navigateToOnlineScreen();
      }
    } catch (_) {}
  }

  void _navigateToOnlineScreen() async {
    if (_driverId == null) {
      await _resolveDriverId();
    }

    await _refreshActiveTripStatus();
    if (!mounted) return;
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl, initialPos: _currentLatLng),
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved =
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
    PrefsCache.instance
        .then((p) => p.setBool('driver_was_online', stillOnline));
    _refreshStats();
    if (stillOnline) {
      _startTripPolling();
      // Immediately check for an active trip so the Resume button appears
      // without waiting for the 15-second poll interval.
      unawaited(_refreshActiveTripStatus());
    } else {
      _stopTripPolling();
    }
  }

  // ═══════════════════════════════════════════════════
  //  BOTTOM NAVIGATION BAR
  // ═══════════════════════════════════════════════════
  Widget _buildBottomNav(dynamic dc) {
    return NavigationBar(
      backgroundColor: const Color(0xFF1A1A1F),
      indicatorColor: const Color(0xFFE8C547).withValues(alpha: 0.15),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _navIndex,
      onDestinationSelected: (i) {
        HapticService.selectionClick();
        if (i == 0) {
          setState(() => _navIndex = 0);
          return;
        }
        setState(() => _navIndex = i);
        final route = i == 1
            ? slideFromRightRoute(const DriverEarningsScreen())
            : i == 2
                ? slideFromRightRoute(const DriverTripHistoryScreen())
                : slideFromRightRoute(const DriverMenuScreen());
        Navigator.of(context).push(route).then((_) {
          if (mounted) setState(() => _navIndex = 0);
        });
      },
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.map_outlined,
              color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon:
              const Icon(Icons.map_rounded, color: Color(0xFFE8C547), size: 22),
          label: S.of(context).homeNav,
        ),
        NavigationDestination(
          icon: Icon(Icons.attach_money_rounded,
              color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.attach_money_rounded,
              color: Color(0xFFE8C547), size: 22),
          label: S.of(context).earningsNav,
        ),
        NavigationDestination(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.history_rounded,
                  color: Colors.white.withValues(alpha: 0.5), size: 22),
            ],
          ),
          selectedIcon: const Icon(Icons.history_rounded,
              color: Color(0xFFE8C547), size: 22),
          label: S.of(context).tripsNav,
        ),
        NavigationDestination(
          icon: _unreadCount > 0
              ? Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(Icons.person_outline_rounded,
                        color: Colors.white.withValues(alpha: 0.5), size: 22),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                )
              : Icon(Icons.person_outline_rounded,
                  color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.person_rounded,
              color: Color(0xFFE8C547), size: 22),
          label: S.of(context).accountNav,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    // No panelH / dc here any more: both existed only to place the floating GO
    // button above the panel, which the panel now owns.
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          // ── Full-screen map ──
          _buildMap(),

          // ── Top gradient overlay ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: pad.top + 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    neuBase.withValues(alpha: 0.85),
                    neuBase.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),

          // ── Top bar: menu + greeting + inbox ──
          Positioned(
            top: pad.top + 12,
            left: 16,
            right: 16,
            child: _buildTopBar(),
          ),

          // The GO button used to float here, pinned above the panel at
          // `pad.bottom + panelH + 16` — so it slid up the screen with every
          // drag of the panel and had to be re-measured against panelH on
          // every frame. It lives inside the panel now, under the status row,
          // which is where the driver's thumb already is.

          // ── Draggable bottom panel ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildDraggablePanel(pad),
          ),

          // ── GO — travels out of the panel as the sheet closes ──
          _buildMorphingGoButton(pad),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MAP
  // ═══════════════════════════════════════════════════
  Widget _buildMap() {
    // While a trip screen sits on top of us the native map stays unmounted
    // — see _mapSuspended. Solid base color underneath; none of it is
    // visible until the trip screen pops and the map remounts.
    if (_mapSuspended) {
      return Container(color: neuBase);
    }
    // Use Google Maps on both iOS and Android
    final dc = DriverColors.of(context);
    // Mapbox Maps Flutter has no web implementation — its MapWidget crashes
    // during the first layout. On web show a static placeholder instead.
    if (kIsWeb) {
      return Container(
        decoration: neuBox(radius: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                size: 44,
              ),
              const SizedBox(height: 10),
              Text(
                'Map preview is not available on web',
                style: TextStyle(
                  color: dc.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // FIX: Always show map, even if GPS hasn't loaded yet. Use default location
    // and move camera when GPS arrives. Prevents blank screen on slow GPS.
    final pos = _currentLatLng ?? const LatLng(40.7128, -74.0060);

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Remember the box we are drawn in: the projection needs it to
          // turn a coordinate into a pixel, and guessing it would put the
          // marker in the wrong place on every screen size but one.
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (_homeMapSize != size) {
            _homeMapSize = size;
          }
          final offset = _homeDotOffset;
          return Stack(
            children: [
              Positioned.fill(child: _homeMapSurface(pos)),
              // The marker, painted by Flutter: 60 fps with no platform
              // channel in the way, and nothing that can fail to rasterise.
              // Centred while the camera follows; at its own projected pixel
              // once the driver has panned or zoomed away.
              // Rebuilt by _markerFrame on every frame the marker moves, so
              // the arrow slides and turns with the ticker rather than with
              // whatever else happens to rebuild the screen.
              Positioned.fill(
                  child: ListenableBuilder(
                listenable: _markerFrame,
                builder: (context, _) {
                  if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();
                  final o = _homeDotOffset;
                  final dot = GoldLocationDotOverlay(bearing: _goldDot.bearing);
                  const half = GoldLocationDot.driverOverlaySize / 2;
                  if (o == null) return Center(child: dot);
                  return Stack(children: [
                    Positioned(left: o.dx - half, top: o.dy - half, child: dot),
                  ]);
                },
              )),
            ],
          );
        },
      ),
    );
  }

  Widget _homeMapSurface(LatLng pos) {
    return RepaintBoundary(
      child: mapbox.MapWidget(
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude)),
          zoom: 16.0,
          pitch: 0.0,
          bearing: 0.0,
        ),
        // FIX: textureView works on more devices than surfaceView (default)
        textureView: true,
        onMapCreated: (ctrl) async {
          try {
            _mapController = ctrl;
            // Cache controller for reuse across driver screens
            MapControllerCache.instance.cache(ctrl);

            // Correct the camera if GPS already landed.
            //
            // cameraOptions above is only the INITIAL camera — Mapbox does
            // not re-read it when the widget rebuilds. The location
            // lookup does a flyTo when it resolves, but with
            // `_mapController?.` — so if GPS won the race and resolved
            // before this callback, that flyTo hit a null controller and
            // was silently dropped. The map then sat on the fallback
            // coordinates for the whole session, which is why drivers in
            // Alabama were staring at New York.
            final known = _currentLatLng;
            if (known != null) {
              try {
                await ctrl.setCamera(mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates:
                        mapbox.Position(known.longitude, known.latitude),
                  ),
                  zoom: 16,
                  pitch: 0,
                  bearing: 0,
                ));
              } catch (e) {
                debugPrint('[DriverMap] initial camera correction failed: $e');
              }
            }
            // Pan and zoom, but the map never turns.
            //
            // Nothing set gestures here at all, so every default applied and
            // a two-finger twist rotated the map. That is the one gesture
            // this screen cannot afford: north stays up, so the arrow's
            // rotation is the whole of what tells the driver which way they
            // are pointing. Turn the map and the arrow still points north-
            // relative while everything under it has moved, and the two
            // disagree with no way to tell which is right.
            //
            // Pitch goes with it — it is the same two-finger gesture, and a
            // tilted map has the same problem in the other axis.
            await ctrl.gestures.updateSettings(mapbox.GesturesSettings(
              scrollEnabled: true,
              pinchToZoomEnabled: true,
              doubleTapToZoomInEnabled: true,
              doubleTouchToZoomOutEnabled: true,
              quickZoomEnabled: true,
              rotateEnabled: false,
              pitchEnabled: false,
              simultaneousRotateAndPinchToZoomEnabled: false,
            ));
            // Disable Mapbox native puck IMMEDIATELY before any annotation creation
            await ctrl.location.updateSettings(
                mapbox.LocationComponentSettings(enabled: false));

            // FIX: Create annotation manager with error handling
            try {
              _pointAnnotMgr =
                  await ctrl.annotations.createPointAnnotationManager();
            } catch (e) {
              debugPrint('[DriverMap] Failed to create annotation manager: $e');
            }

            if (_pointAnnotMgr != null) {
              try {
                await ctrl.style.setStyleLayerProperty(
                    _pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(
                    _pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(
                    _pointAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (_) {}
            }

            setState(() => _mapReady = true);

            // A fresh manager means any annotation we still hold belongs to
            // the previous platform view (Android destroys it in background)
            // and can never be updated again. Drop it, draw the dot on the
            // new map right away, and re-arm the watchdog in case this ran
            // before the first GPS fix.
            _dropLocAnnot();
            _updateMyLocAnnotation();
            _startDotCreateWatchdog();
          } catch (e) {
            debugPrint('[DriverMap] onMapCreated error: $e');
          }
        },
        onStyleLoadedListener: (_) async {
          try {
            if (_mapController != null) {
              // Re-disable puck after style reload (Mapbox may re-enable it)
              await _mapController!.location.updateSettings(
                  mapbox.LocationComponentSettings(enabled: false));
              await _applyNavyGoldTheme(_mapController!);
              if (_pointAnnotMgr != null) {
                try {
                  await _mapController!.style.setStyleLayerProperty(
                      _pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                  await _mapController!.style.setStyleLayerProperty(
                      _pointAnnotMgr!.id,
                      'icon-rotation-alignment',
                      'viewport');
                  await _mapController!.style.setStyleLayerProperty(
                      _pointAnnotMgr!.id, 'icon-allow-overlap', true);
                } catch (_) {}
              }
            }
          } catch (e) {
            debugPrint('[DriverMap] onStyleLoaded error: $e');
          }
        },
        onScrollListener: (_) => _onHomeMapPanned(),
        // The camera state is pushed to us here, so the projection never has
        // to ask for it — asking would put the marker back on the channel
        // this whole approach exists to get off.
        onCameraChangeListener: (data) {
          _homeCamState = data.cameraState;
          // Repaint the overlay too. Its screen position is derived from
          // this camera, and the motion ticker parks itself when the driver
          // stands still — so a driver dragging the map while stopped would
          // otherwise leave the arrow pinned to a stale pixel while the map
          // slid out from under it.
          _markerFrame.value++;
        },
        // FIX: Catch map load errors
        onMapLoadErrorListener: (err) {
          debugPrint(
              '[DriverMap] Load error: ${err.message} (type: ${err.type})');
        },
      ),
    );
  }

  Future<Uint8List> _buildGoldPuckImage() async {
    const size = 24.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, size / 2, Paint()..color = Colors.white);
    canvas.drawCircle(
        center, size / 2 - 3, Paint()..color = const Color(0xFFE8C547));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // ── Dark navy + gold freeway theme ──
  Future<void> _applyNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  // ═══════════════════════════════════════════════════
  //  EARNINGS PANEL — chart + period toggle
  // ═══════════════════════════════════════════════════

  /// Time online, read as a clock rather than as a decimal.
  ///
  /// It used to print one decimal place and an "h": half an hour showed as
  /// "0.5h", which is a number the driver has to convert before it means
  /// anything, and a first shift showed "0.0h" for its first six minutes as
  /// though nothing had been counted at all. Hours and minutes say it
  /// directly.
  ///
  ///   0.0 -> 0h        0.5 -> 30min
  ///   0.9 -> 54min     1.0 -> 1h
  ///   2.25 -> 2h 15min
  String _onlineTimeText(double hours) {
    if (!hours.isFinite || hours <= 0) return '0h';
    final totalMinutes = (hours * 60).round();
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}min';
    if (m == 0) return '${h}h';
    return '${h}h ${m}min';
  }

  /// Bars for the selected period. Hand-drawn rather than pulling in a chart
  /// package: it is a row of rectangles, and a dependency for that would cost
  /// a native rebuild to ship.
  /// Which hourly columns get their amount printed above the bar.
  ///
  /// All of them will not fit. Twenty-four columns across a phone panel are
  /// about ten points wide and a dollar amount is nearer thirty, so two on
  /// neighbouring hours overlap into something unreadable — which is why the
  /// hourly view carried no figures at all.
  ///
  /// So they are placed rather than skipped: biggest amount first, and one
  /// is only taken if nothing within three columns has been taken already.
  /// What survives is the hours that earned most, which is what a driver
  /// reads the figures for. The rest are still there as bars.
  Set<int> _tipColumns(List<double> values) {
    final order = <int>[
      for (var i = 0; i < values.length; i++)
        if (values[i] > 0) i,
    ]..sort((a, b) => values[b].compareTo(values[a]));
    final taken = <int>{};
    for (final i in order) {
      if (taken.any((j) => (j - i).abs() < 3)) continue;
      taken.add(i);
    }
    return taken;
  }

  Widget _earningsChart(DriverColors dc) {
    final week = _earningsWeekTab;
    final values = week ? _daySeries : _hourlySeries;
    final barH = Responsive.h(84);
    // The band above the bars where the amounts sit. Reserved in the empty
    // state too, and on both tabs, or the chart grows by a line the moment
    // data lands — which is the jump the empty axis below exists to avoid.
    final tipH = Responsive.sp(13);
    // Every day on the week tab; a spaced subset of the hours on today's.
    final tips = week
        ? <int>{for (var i = 0; i < values.length; i++) i}
        : _tipColumns(values);

    if (values.isEmpty) {
      // Draw the axis immediately, empty.
      //
      // This used to be the word "Loading", so the chart arrived in two
      // steps: a line of text, then a sudden wall of bars once the request
      // came back. The bars appearing all at once is what reads as slow —
      // the fetch takes what it takes, but the driver should not watch the
      // shape of the panel change underneath them.
      //
      // The baseline ticks are the same ones a real zero draws, so when the
      // data lands the bars grow out of them instead of replacing something
      // else. Nothing here claims an amount: an empty axis says "no numbers
      // yet", which is true, where "$0" would not be.
      return SizedBox(
        height: barH + tipH + Responsive.h(6) + Responsive.sp(11),
        child: Column(
          children: [
            SizedBox(
              height: barH + tipH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (int i = 0; i < (week ? 7 : 24); i++) ...[
                    if (i > 0) SizedBox(width: week ? Responsive.w(7) : 2),
                    Expanded(child: _chartBar(barH * 0.03, week, false)),
                  ],
                ],
              ),
            ),
            SizedBox(height: Responsive.h(6)),
            _chartLabels(dc, week),
          ],
        ),
      );
    }

    final peak = values.fold<double>(0, math.max);
    // Today's own bar, so the driver can find "now" at a glance.
    final nowIdx = week ? values.length - 1 : DateTime.now().hour;

    return Column(
      children: [
        SizedBox(
          height: barH + tipH,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < values.length; i++) ...[
                if (i > 0) SizedBox(width: week ? Responsive.w(7) : 2),
                // Explicit height, not FractionallySizedBox.
                //
                // A fractional box inside a Row aligned to `end` resolves its
                // own size from its child, and a DecoratedBox has no intrinsic
                // size — that combination is the kind of layout that renders
                // fine on one device and collapses to nothing on another.
                // barH is known right here, so the arithmetic is done here.
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // The amount, riding on the tip of its own bar.
                      //
                      // Never where there is no money: a row of $0.00 under
                      // every empty column is noise standing exactly where
                      // the eye goes to compare the ones that earned.
                      //
                      // The hourly view lets its figure spill past the column
                      // it belongs to. Twenty-four columns leave about ten
                      // points each and an amount needs thirty, so a label
                      // confined to its own width would be scaled down to
                      // something unreadable. _tipColumns has already made
                      // room by only labelling hours three columns apart, so
                      // there is nothing beside it to collide with.
                      SizedBox(
                        height: tipH,
                        child: tips.contains(i) && values[i] > 0
                            ? OverflowBox(
                                maxWidth:
                                    week ? double.infinity : Responsive.w(46),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '\$${values[i].toStringAsFixed(2)}',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: _gold.withValues(alpha: 0.85),
                                      fontSize: Responsive.sp(9),
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        ui.FontFeature.tabularFigures()
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : null,
                      ),
                      // A floor of 3%, so an hour that earned nothing still
                      // draws a baseline tick. Without it the axis has holes
                      // in it and reads as broken rather than as empty.
                      _chartBar(
                        barH *
                            (peak > 0
                                ? math.max(0.03, values[i] / peak)
                                : 0.03),
                        week,
                        i == nowIdx,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: Responsive.h(6)),
        _chartLabels(dc, week),
      ],
    );
  }

  /// One bar. Slim on purpose.
  ///
  /// The bars used to take the full column width, which on the seven-bar week
  /// view made them wide blocks — a bar chart reads as data when the bar is
  /// thinner than the space around it, and as a bar chart of nothing in
  /// particular when it is not. Capped rather than fractional so the week and
  /// the day views end up with the same weight of line despite having seven
  /// bars against twenty-four.
  Widget _chartBar(double height, bool week, bool isNow) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: week ? Responsive.w(10) : Responsive.w(4),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: isNow ? _gold : _gold.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(week ? 3 : 2),
          ),
        ),
      ),
    );
  }

  Widget _chartLabels(DriverColors dc, bool week) {
    final style = TextStyle(
      color: dc.textSecondary,
      fontSize: Responsive.sp(9),
      fontWeight: FontWeight.w600,
    );
    // Week: one label per bar. Today: every sixth hour — 24 labels on a phone
    // is a grey smear.
    final labels =
        week ? _daySeriesLabels : const ['12AM', '6AM', '12PM', '6PM'];
    if (labels.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (final l in labels)
          Expanded(
            child: Text(
              l,
              textAlign: week ? TextAlign.center : TextAlign.start,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: style,
            ),
          ),
      ],
    );
  }

  /// Today / Week pill. The selected one is a raised surface, the other a
  /// sunken well — the same language the rest of the app uses for state.
  Widget _periodPill(
      DriverColors dc, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.w(14), vertical: Responsive.h(7)),
        decoration: neuBox(radius: 14, pressed: !selected),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _gold : dc.textSecondary,
            fontSize: Responsive.sp(12),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildEarningsSection(DriverColors dc) {
    final s = S.of(context);
    final total = _earningsWeekTab ? _weekEarnings : _todayEarnings;
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.w(14), Responsive.h(12),
          Responsive.w(14), Responsive.h(10)),
      decoration: neuBox(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _periodPill(dc, s.today, !_earningsWeekTab, () {
                if (!_earningsWeekTab) return;
                HapticService.selectionClick();
                setState(() => _earningsWeekTab = false);
              }),
              SizedBox(width: Responsive.w(8)),
              _periodPill(dc, s.weekLabel, _earningsWeekTab, () {
                if (_earningsWeekTab) return;
                HapticService.selectionClick();
                setState(() => _earningsWeekTab = true);
              }),
              const Spacer(),
              Text(
                '\$${total.toStringAsFixed(2)}',
                style: TextStyle(
                  color: dc.text,
                  fontSize: Responsive.sp(19),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.h(14)),
          _earningsChart(dc),
          SizedBox(height: Responsive.h(6)),
          Center(
            child: GestureDetector(
              onTap: () {
                HapticService.selectionClick();
                Navigator.of(context).push(
                  slideFromRightRoute(const DriverEarningsScreen()),
                );
              },
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Responsive.h(6)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.seeMore,
                      style: TextStyle(
                        color: _gold,
                        fontSize: Responsive.sp(13),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: Responsive.w(4)),
                    Icon(Icons.arrow_forward_rounded,
                        color: _gold, size: Responsive.sp(15)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The reserved-rides card, which is only there when there is one.
  ///
  /// It grows into the sheet rather than appearing: a card that pops into
  /// a list the driver is already reading shoves everything below it down
  /// by its full height in one frame, and whatever they were about to tap
  /// is somewhere else by the time their thumb lands.
  ///
  /// AnimatedSize carries the height, a fade and a small rise carry the
  /// card. `_scheduledBannerVisible` has always reserved the sheet's
  /// height for this; nothing ever drew it.
  Widget _buildReservedRidesCard(DriverColors dc) {
    final show = _scheduledBannerVisible;
    return AnimatedSize(
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeInOutCubicEmphasized,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        child: !show
            ? const SizedBox(width: double.infinity)
            : TweenAnimationBuilder<double>(
                key: ValueKey('reserved_$_scheduledAvailableCount'),
                tween: Tween<double>(begin: 14, end: 0),
                duration: const Duration(milliseconds: 460),
                curve: Curves.easeOutCubic,
                builder: (_, dy, child) =>
                    Transform.translate(offset: Offset(0, dy), child: child),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: GestureDetector(
                    onTap: () {
                      HapticService.selectionClick();
                      Navigator.of(context).push(
                        slideFromRightRoute(
                          const ScheduledRidesScreen(initialTab: 0),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: neuBox(radius: 20),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: neuBox(radius: 14, pressed: true),
                            child: const Icon(
                              Icons.event_available_rounded,
                              color: Color(0xFFE8C547),
                              size: 21,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  S.of(context).scheduledRidesTitle,
                                  style: TextStyle(
                                    color: dc.text,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  S.of(context).scheduledAvailableCount(
                                        _scheduledAvailableCount,
                                      ),
                                  style: TextStyle(
                                    color: const Color(0xFFE8C547)
                                        .withValues(alpha: 0.9),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: dc.textSecondary,
                            size: 22,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// Cruise Level row. Tapping opens the full ladder.
  ///
  /// No level name or point count here on purpose: this screen does not fetch
  /// either, and a hardcoded "Silver" would be wrong for most drivers reading
  /// it. The ladder itself is the honest summary.
  Widget _buildCruiseLevelRow(DriverColors dc) {
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        Navigator.of(context).push(
          slideFromRightRoute(const CruiseLevelScreen()),
        );
      },
      child: Container(
        padding: EdgeInsets.all(Responsive.w(14)),
        decoration: neuBox(radius: 20),
        child: Row(
          children: [
            Container(
              width: Responsive.w(38),
              height: Responsive.w(38),
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(Icons.workspace_premium_rounded,
                  color: _gold, size: Responsive.sp(19)),
            ),
            SizedBox(width: Responsive.w(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    S.of(context).cruiseLevel,
                    style: TextStyle(
                      color: dc.text,
                      fontSize: Responsive.sp(14),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: Responsive.h(2)),
                  Text(
                    S.of(context).cruiseLevelTiers,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: dc.textSecondary,
                      fontSize: Responsive.sp(11),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.28),
                size: Responsive.sp(20)),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        // Menu
        _glassBtn(
          Icons.menu_rounded,
          onTap: () {
            HapticService.selectionClick();
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (ctx, a, sa) => const DriverMenuScreen(),
                transitionDuration: const Duration(milliseconds: 350),
                reverseTransitionDuration: const Duration(milliseconds: 300),
                transitionsBuilder: (ctx2, anim, sa, child) {
                  return FadeTransition(
                    opacity: CurvedAnimation(
                      parent: anim,
                      curve: Curves.easeInOut,
                    ),
                    child: child,
                  );
                },
              ),
            );
          },
        ),

        const SizedBox(width: 12),

        // Earnings pill — the same one the driver already reads while online.
        //
        // It used to be a wide box with the avatar and TODAY / WEEK side by
        // side: two small figures where the online screen shows one big one,
        // so the number the driver checks all day changed size and place the
        // moment they went online. Now it is the same object in both screens —
        // one period at a time, swipe to change it, tap for the detail. The
        // avatar went with the old box; the menu behind the left button is
        // where the account lives.
        Expanded(child: Center(child: _earningsPill())),

        const SizedBox(width: 12),

        // Notifications.
        //
        // This was the scheduled-rides calendar. The badge that mattered here
        // was never "how many jobs exist in the marketplace" — it was "how
        // many things are waiting for you", and that is the inbox. Scheduled
        // rides keep their own entry in the menu, where a browsing
        // destination belongs.
        _glassBtn(
          Icons.notifications_none_rounded,
          badge: _unreadCount > 0 ? _unreadCount : null,
          onTap: () {
            HapticService.selectionClick();
            Navigator.of(context)
                .push(slideFromRightRoute(const DriverInboxScreen()));
          },
        ),
      ],
    );
  }

  /// Top-bar earnings pill — the offline twin of the online screen's pill
  /// ([driver_online_widgets.dart] `_earningsPill`). Same 160×52 footprint,
  /// same type sizes, same page dots, so going online does not move the
  /// figure the driver is looking at. Two periods here instead of three:
  /// the home screen never fetches a last-trip total.
  Widget _earningsPill() {
    const pillText = Colors.white;
    const pillSub = Colors.white38;
    const dotActive = Colors.white;
    const dotInactive = Color(0x33FFFFFF); // white @ 20%

    // Today, then the week, then the month — swiped left in that order,
    // shortest span first, the way a driver widens the question.
    final amounts = [_todayEarnings, _weekEarnings, _monthEarnings];
    final prevAmounts = [
      _prevTodayEarnings,
      _prevWeekEarnings,
      _prevMonthEarnings,
    ];
    // One word each, and tightly set.
    //
    // The capsule is as wide as its widest line, and with "THIS MONTH" that
    // line was the label, not the figure — 95 px against 53 for "$8.40", so
    // the box never shrank for a small amount no matter what the number did.
    // TODAY / WEEK / MONTH puts the figure back in charge of the width.
    final labels = [
      S.of(context).today.toUpperCase(),
      S.of(context).weekLabel.toUpperCase(),
      S.of(context).monthLabel.toUpperCase(),
    ];
    final pageCount = amounts.length;
    final safePage = _earningsPage.clamp(0, pageCount - 1);

    // The plate is around the swiper, not inside it.
    //
    // First it was a slab per page, so swiping slid a bordered rectangle
    // across the map and the eye followed the box instead of the number that
    // had changed. Taking it away fixed that but left the figure floating on
    // the map with nothing to hold it. One box around the whole control does
    // both: it never moves, and only the type travels through it.
    Widget pillPage(double amount, double prevAmount, String label) {
      return SizedBox(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey<double>(amount),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                tween: Tween<double>(begin: prevAmount, end: amount),
                // The figure, or a bare $ standing in for it.
                //
                // This chip sits at the top of the map and is the most
                // legible thing on the screen from a back seat, which is
                // why the switch in Earnings exists and why this is what
                // it covers.
                builder: (_, val, __) => Text(
                  // "$—" until a real figure has landed.
                  //
                  // A double starts at zero, and printing that as $0.00 is
                  // a claim: it tells a driver who worked yesterday that
                  // they earned nothing. Week and month were not cached at
                  // all, so they made that claim on every open, for as
                  // long as the request took.
                  _statsEverLoaded ? EarningsPrivacy.format(val) : '\$—',
                  style: const TextStyle(
                    color: pillText,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 1),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: pillSub,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  for (int i = 0; i < pageCount; i++) ...[
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == safePage ? dotActive : dotInactive,
                      ),
                    ),
                    if (i < pageCount - 1) const SizedBox(width: 3),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        Navigator.of(context).push(
          slideFromRightRoute(const DriverEarningsScreen()),
        );
      },
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -200 && safePage < pageCount - 1) {
          HapticService.selectionClick();
          setState(() {
            _earningsSwipeForward = true;
            _earningsPage = safePage + 1;
          });
        } else if (details.primaryVelocity! > 200 && safePage > 0) {
          HapticService.selectionClick();
          setState(() {
            _earningsSwipeForward = false;
            _earningsPage = safePage - 1;
          });
        }
      },
      // Wrapped tight around the figure, not a slab with the figure adrift
      // in the middle of it.
      //
      // It was a fixed 160 px, so "$28.51" sat in a box with forty empty
      // pixels either side of it. The box takes the width of whatever page
      // is showing instead — and since "THIS MONTH" is wider than "TODAY",
      // AnimatedSize eases that difference rather than letting the box jump
      // width as the driver swipes.
      // Grows and shrinks with the figure.
      //
      // The amount is set in tabular figures, so every digit is the same
      // width and the count-up does not make the capsule shiver — it only
      // changes width when a digit is gained or lost ($9.99 to $10.00), and
      // then it eases rather than snapping. Material's emphasized curve, the
      // same one the rider's vehicle row uses, so the two feel related.
      child: AnimatedSize(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubicEmphasized,
        child: Container(
          // The same plate the online screen carries, down to the numbers.
          //
          // It was a full capsule here — 48 tall at radius 24, so the ends
          // were semicircles — while online it is a rounded rectangle at
          // radius 20 with a faint white rim. Going online therefore
          // reshaped the one figure the driver checks all day, which is the
          // thing this control was rebuilt to stop doing.
          //
          // 48 tall still, matching the two round buttons beside it.
          height: 48,
          // Clipped, so a page sliding in is cut at the rounded edge instead
          // of running out across the map.
          clipBehavior: Clip.antiAlias,
          decoration: neuBox(
            radius: 20,
            borderColor: Colors.white.withValues(alpha: 0.06),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            reverseDuration: const Duration(milliseconds: 380),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            // Slide as well as fade, and in the direction the thumb went.
            //
            // A pure crossfade says "this number was replaced". A short travel
            // says "you moved to the one next door", which is what a swipe
            // means — and it is the difference between the change reading as
            // a glitch and as a gesture. layoutBuilder stacks the outgoing and
            // incoming pages so neither shoves the other while they cross.
            transitionBuilder: (child, animation) {
              final incoming = child.key == ValueKey<int>(safePage);
              final dir = _earningsSwipeForward ? 1.0 : -1.0;
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(incoming ? 0.35 * dir : -0.35 * dir, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.center,
              children: [...previous, if (current != null) current],
            ),
            // KeyedSubtree, not Center — this is what made the plate run the
            // whole width of the bar.
            //
            // A Center with no widthFactor takes every pixel it is offered, and
            // what it is offered here is the entire span between the two
            // buttons. That widened the layoutBuilder's Stack, which widened
            // the Container painting the plate, so a 110 px capsule was drawn
            // as a 430 px slab with the figure adrift in the middle of it.
            //
            // Nothing is lost: the Stack above already centres its children,
            // and the Center outside the pill still centres the pill in the
            // bar. The key has to stay for AnimatedSwitcher to see a new child.
            child: KeyedSubtree(
              key: ValueKey<int>(safePage),
              child: pillPage(
                amounts[safePage],
                prevAmounts[safePage],
                labels[safePage],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Fetch count of available scheduled rides matching driver's vehicle type.
  int _lastNotifiedScheduledCount = 0;
  Future<void> _refreshScheduledCount() async {
    if (!_isStillOnline || _activeTripData != null) return;
    try {
      // Same reasoning as the online screen: reserved rides are same-state
      // only, and 0,0 turned that rule off. Uses the position this screen
      // already holds — no extra Geolocator call to hang on.
      final here = _currentLatLng;
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: here?.latitude ?? 0,
        lng: here?.longitude ?? 0,
        radiusKm: 100,
      );
      if (!mounted) return;
      final newCount = trips.length;
      // Backend sends FCM push to 'drivers_available' topic when new scheduled
      // rides enter the marketplace. No local notification needed here — the
      // OS shows the push when the app is backgrounded, and the banner below
      // handles the in-app visual cue.
      _lastNotifiedScheduledCount = newCount;
      setState(() => _scheduledAvailableCount = newCount);
    } catch (_) {}
  }

  /// Animated banner above "Finding trips" showing scheduled ride count.
  Widget _buildScheduledRidesBanner() {
    if (_scheduledAvailableCount == 0) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        Navigator.of(context).push(
          slideFromRightRoute(const ScheduledRidesScreen()),
        );
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        builder: (context, scale, child) => Transform.scale(
          scaleY: scale,
          alignment: Alignment.topCenter,
          child: child,
        ),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: neuBox(
            radius: 16,
            borderColor: _gold.withValues(alpha: 0.35),
          ),
          child: Row(
            children: [
              const Icon(Icons.event_available_rounded, color: _gold, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S
                      .of(context)
                      .scheduledRidesAvailableLabel(_scheduledAvailableCount),
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _gold, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  // _getGreeting is gone with the greeting it fed: the top pill shows today's
  // and this week's earnings now, not the time of day and the driver's own name.

  Widget _glassBtn(IconData icon, {required VoidCallback onTap, int? badge}) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            // 48 flat, not Responsive.w(48).
            //
            // Responsive.w is `px * (width / 390)`, so these grew with the
            // viewport while the online screen's side buttons are passed a
            // plain 48 — the same two controls came out different sizes on
            // anything that is not a 390-wide phone, and on a browser window
            // three times that wide they came out three times as big.
            width: 48,
            height: 48,
            // Round, with the same faint gold rim the online screen's side
            // buttons carry.
            //
            // Raised, not a sunken well: `pressed: true` paints neuPressed
            // (#101014), which next to the pill's neuSurface read as two
            // black holes flanking a grey card.
            //
            // These were rounded squares at radius 14 while going online
            // swapped them for circles, so the two controls that never
            // change what they do changed shape underneath the driver's
            // thumb. Half the width is a circle, and the rim is the same
            // 0xFFE8C547 at 18% that `_fab` uses over there — one family
            // across both screens.
            decoration: neuBox(
              radius: 24,
              borderColor: const Color(0xFFE8C547).withValues(alpha: 0.18),
            ),
            // 48 * 0.44, the ratio `_fab` uses.
            child: Icon(icon, color: dc.text, size: 48 * 0.44),
          ),
          if (badge != null)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                // Flat too, so the badge keeps its proportion to the button
                // it sits on instead of growing past it.
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$badge',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecenterBtn() {
    return GestureDetector(
      onTap: () {
        if (_currentLatLng != null) {
          _mapController?.flyTo(
            mapbox.CameraOptions(
              center: mapbox.Point(
                  coordinates: mapbox.Position(
                      _currentLatLng!.longitude, _currentLatLng!.latitude)),
              zoom: 16,
              pitch: 45,
            ),
            mapbox.MapAnimationOptions(duration: 600),
          );
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: neuBox(radius: 14, pressed: true),
        child: const Icon(
          Icons.my_location_rounded,
          color: _gold,
          size: 22,
        ),
      ),
    );
  }

  // ── GO button geometry, both ends of the morph ──
  static const double _kGoPillH = 56.0;
  static const double _kGoCircleD = 74.0;
  static const double _kGoSideInset = 20.0;

  /// The GO button, morphing between two shapes as the sheet is dragged.
  ///
  /// Open, it is the wide pill at the foot of the sheet — the one action the
  /// panel offers. Closed, there is no sheet to sit in, so it becomes the
  /// round GO hovering over the map.
  ///
  /// Both are the same widget travelling, not two widgets swapping. Every
  /// property — width, height, corner radius, height above the screen floor,
  /// and which of the two labels is showing — is read straight off
  /// [panelExtent], the same 0-to-1 the drag already produces. So it is not
  /// an animation that plays after the gesture: it IS the gesture. Let go
  /// halfway and the button is halfway, and the panel's own spring carries
  /// both the rest of the way together.
  Widget _buildMorphingGoButton(EdgeInsets pad) {
    final t = panelExtent; // 0 = closed circle, 1 = open pill
    final height = ui.lerpDouble(_kGoCircleD, _kGoPillH, t)!;
    final radius = ui.lerpDouble(_kGoCircleD / 2, 16.0, t)!;

    // Closed: floating clear of the sheet's rounded top. Open: resting on the
    // sheet's floor, above the home indicator.
    //
    // 34, up from 20 and 8 before that.
    //
    // The disc carries a gold glow that reaches roughly eight points past its
    // edge, so a gap measured to the edge is not the gap anyone sees: at 8
    // the glow landed on the sheet and the two read as one object. 20 pulled
    // the glow clear but left the disc close enough to still look attached —
    // the eye reads the space between two round things as a gap only once it
    // is wider than the glow by a clear margin.
    //
    // 26 now, with the sheet 8 points shorter than when 34 was measured —
    // the disc has come down with it and this takes a little more off the
    // gap. The glow still clears the sheet, which is the constraint the
    // number exists for.
    final bottomClosed = _panelCollapsedH + 26;
    final bottom = ui.lerpDouble(bottomClosed, 0, t)!;

    // Inset on both sides and centred inside whatever that leaves, rather
    // than positioned from the screen's width.
    //
    // It used to compute `left: (screenWidth - width) / 2`, which is only
    // right if this Stack is exactly as wide as the screen. It is not, so
    // the open bar sat off-centre and ran off the left edge. Measuring the
    // box we are actually in cannot be wrong about it.
    // Open, the button sits in a bar of its own at the foot of the sheet —
    // the shape Uber's "View issues" uses. Closed, that bar is not there at
    // all and the disc floats over the map, so the footer's ground, its
    // hairline and its padding all arrive with the drag.
    return Positioned(
      bottom: bottom,
      left: ui.lerpDouble(_kGoSideInset, 0, t)!,
      right: ui.lerpDouble(_kGoSideInset, 0, t)!,
      child: FadeTransition(
        opacity: _fabScale,
        child: Container(
          padding: EdgeInsets.fromLTRB(
            ui.lerpDouble(0, 20, t)!,
            ui.lerpDouble(0, 14, t)!,
            ui.lerpDouble(0, 20, t)!,
            ui.lerpDouble(0, 14 + pad.bottom, t)!,
          ),
          decoration: BoxDecoration(
            color: neuSurface.withValues(alpha: t),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.05 * t),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45 * t),
                blurRadius: 14 * t,
                offset: Offset(0, -4 * t),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, box) => Center(
              child: SizedBox(
                width: ui.lerpDouble(_kGoCircleD, box.maxWidth, t),
                height: height,
                child: _buildGoButton(radius: radius, morph: t),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  FLOATING GO BUTTON — inner pulse glow
  // ═══════════════════════════════════════════════════
  Widget _buildGoButton({double radius = 16.0, double morph = 1.0}) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: _isVerified
          ? _goOnline
          : () async {
              await _ensureVerified();
            },
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_pulseAnim, _btnColorAnim, _glossCtrl, _radarCtrl]),
        builder: (_, __) {
          final p = _pulseAnim.value;
          final g = _glossCtrl.value;
          final docsOk = _vehicleDocsApproved || !_docStatusLoaded;
          // Disabled when docs missing or not verified — sunken neu well.
          final enabled = _isVerified && docsOk;

          // Graphite body, gold lettering — the reverse of the old gold
          // slab with black type. The gold is now the thing that moves and
          // glows (the word, the radar, the rim light) against a still,
          // neutral body, which is what lets the radar read at all: rings
          // of gold over gold were invisible.
          //
          // Still breathing with the pulse, just narrower: a body this dark
          // shows a large swing as flicker rather than as a heartbeat.
          // Near-black when it is the disc, a shade lighter as it becomes
          // the bar. The disc sits on a dark map and has a gold ring, a
          // gold word and gold radar inside it — a lighter body would put
          // all four in competition and none of them would read.
          // Black disc closed, gold bar open.
          //
          // The disc sits on the map, where a gold puck would compete with
          // the gold arrow a few centimetres above it; the bar sits at the
          // foot of a dark sheet, where gold is the only thing that reads as
          // the one action on the screen.
          final greyTop1 = Color.lerp(
              const Color(0xFF0B0B0F), const Color(0xFFF2D45E), morph)!;
          final greyTop2 = Color.lerp(
              const Color(0xFF14141A), const Color(0xFFE8C547), morph)!;
          final greyBot = Color.lerp(
              const Color(0xFF06060A), const Color(0xFFD4A82A), morph)!;

          final topColor = Color.lerp(greyTop1, greyTop2, p)!;
          final botColor = greyBot;
          final glowColor = _gold;

          // Gold on black, then black on gold.
          final fgColor = enabled
              ? Color.lerp(_gold, const Color(0xFF0B0B0F), morph)!
              : dc.textSecondary;

          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              // Without this the body never fills its own button.
              //
              // A Stack hands loose constraints to its non-positioned
              // children, so the Container below sized itself to the Row
              // inside it — measured, 74 x 14 inside the 74 x 74 disc and
              // 182 x 56 inside a 360-wide bar — and sat in the top-left
              // corner of the rest. Closed, that is a flattened sliver with
              // GO in it and the radar circling something that is not there;
              // open, it is a gold bar that stops two thirds of the way
              // across. The two faults are the same fault.
              //
              // The Row below already says mainAxisAlignment.center, which
              // only means anything in a box wider than the Row. This is
              // what makes the box wider than the Row.
              fit: StackFit.expand,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: ui.lerpDouble(0, 28, morph)!,
                    vertical: ui.lerpDouble(0, 13, morph)!,
                  ),
                  decoration: enabled
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          // The gold ring, which the disc was described as
                          // having and never had.
                          //
                          // The body is near-black on purpose, so that the
                          // word, the radar and the rim are the only gold in
                          // it. But near-black on a dark map is a hole: what
                          // reads as the button is then the lettering alone,
                          // floating with rings around it. The rim is what
                          // gives the disc an edge.
                          //
                          // Gone by the time it is the bar — a gold outline
                          // on a gold body is either invisible or a seam.
                          border: Border.all(
                            color: _gold.withValues(
                                alpha: 0.55 * (1 - morph).clamp(0.0, 1.0)),
                            width: 1.5,
                          ),
                          boxShadow: [
                            // Tight on the disc, softer on the bar. At the
                            // old 16-24 px blur a 74 px circle was more
                            // halo than button — it read as a glow with a
                            // word floating in it rather than as a control.
                            BoxShadow(
                              color: glowColor.withValues(
                                  alpha: ui.lerpDouble(
                                      0.12, 0.3 + 0.15 * p, morph)!),
                              blurRadius: ui.lerpDouble(8, 16 + 8 * p, morph)!,
                              spreadRadius: 0,
                              offset: const Offset(0, 3),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.28),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [topColor, botColor],
                          ),
                        )
                      : neuBox(radius: 16, pressed: true),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    // Centred: the button is full-width inside the panel now,
                    // and a min-size Row in a stretched box hugs the left edge.
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // A power symbol, in its own disc, to the left of the
                      // label.
                      //
                      // Only on the bar: the closed disc is 74 px with the
                      // word GO in it and has no room beside it, so the badge
                      // fades in with the shape. The same disc still carries
                      // the spinner while navigating and the warning when
                      // documents are missing — states where the button is
                      // refusing to do what it says and has to look like it.
                      if (_isNavigatingToOnline || !docsOk || morph > 0.35) ...[
                        Opacity(
                          opacity: (_isNavigatingToOnline || !docsOk)
                              ? 1.0
                              : ((morph - 0.35) / 0.65).clamp(0.0, 1.0),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              // Dark well on the gold bar, light one on the
                              // black disc — the fill has to flip with the body
                              // underneath it or the icon disappears into it.
                              color: enabled
                                  ? Color.lerp(
                                      Colors.white.withValues(alpha: 0.10),
                                      Colors.black.withValues(alpha: 0.16),
                                      morph)
                                  : Colors.white.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: _isNavigatingToOnline
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: enabled ? Colors.black87 : _gold,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    !docsOk
                                        ? (_hasExpiredDocs ||
                                                _plateChangePending
                                            ? Icons.warning_amber_rounded
                                            : Icons.upload_file_rounded)
                                        : Icons.power_settings_new_rounded,
                                    color: fgColor,
                                    size: 16,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      // Two labels crossing over, not one label changing.
                      //
                      // The circle has room for "GO" and nothing else, the
                      // pill wants the full sentence. Swapping the string at
                      // some point in the drag would pop; overlapping them
                      // and trading opacity means that mid-gesture you see
                      // both faintly, which is what a shape becoming another
                      // shape should look like. Stacked so neither reflows
                      // the row as it fades.
                      Flexible(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Opacity(
                              opacity: (1 - morph * 1.6).clamp(0.0, 1.0),
                              child: Text(
                                'GO',
                                maxLines: 1,
                                style: TextStyle(
                                  color: fgColor,
                                  fontSize: ui.lerpDouble(22, 14, morph),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            Opacity(
                              opacity: ((morph - 0.35) / 0.65).clamp(0.0, 1.0),
                              child: Text(
                                _isNavigatingToOnline
                                    ? 'GOING ONLINE...'
                                    : _isVerified
                                        ? (!docsOk
                                            // A plate change is the driver's
                                            // own doing and has one fix, so
                                            // the button names the problem
                                            // rather than the folder.
                                            ? (_plateChangePending
                                                ? S.of(context).viewIssue
                                                : _hasExpiredDocs
                                                    ? 'EXPIRED DOCS'
                                                    : 'DOCUMENTS')
                                            : (_activeTripData != null ||
                                                    _isStillOnline)
                                                ? S.of(context).resumeOnline
                                                : S.of(context).goOnline)
                                        : S.of(context).verifyFirst,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: TextStyle(
                                  color: fgColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Radar sweep — only while the button is the round GO.
                //
                // Painted after the body, not before it. Underneath, it was
                // invisible from the moment the body started filling the disc
                // the way it should: an opaque gradient covering the whole
                // 74 px leaves nothing of a layer below it.
                //
                // Over the top it never reaches the word. The painter keeps
                // its rings between 62% and 90% of the radius — outside the
                // lettering, inside the rim — so there is no pass where a
                // ring and the O are the same gold in the same place.
                //
                // Faded out by `morph` rather than switched off, so it thins
                // away as the circle stretches into the pill instead of
                // vanishing at some threshold mid-gesture. Rings on a pill
                // read as a glitch; rings appearing and disappearing under
                // the driver's thumb read as a worse one.
                if (enabled && morph < 0.9)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: (1 - morph).clamp(0.0, 1.0),
                        child: CustomPaint(
                          painter: _GoRadarPainter(
                            progress: _radarCtrl.value,
                            color: glowColor,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The sheet's direction hint: `^` closed, `v` open.
  ///
  /// Rotated by [panelExtent] rather than by its own animation, so it turns
  /// with the drag and not after it. Halfway up the sheet the arrow is on
  /// its side — which is exactly what "you are between the two" should look
  /// like, and something a swap of two icons could never show.
  ///
  /// It also drags: the gesture is the same one the handle above it takes,
  /// so a thumb landing on the arrow does the obvious thing instead of
  /// nothing. Tapping snaps to the other end.
  Widget _buildPanelChevron(DriverColors dc) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selectionClick();
        animatePanelTo(panelExtent > 0.5 ? 0.0 : 1.0);
      },
      onVerticalDragStart: (_) => setState(() => _dragging = true),
      onVerticalDragUpdate: (d) {
        setState(() => _dragging = true);
        updatePanelDrag(d.primaryDelta ?? 0);
      },
      onVerticalDragEnd: (d) {
        setState(() => _dragging = false);
        endPanelDrag(d.primaryVelocity ?? 0);
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Transform.rotate(
            angle: math.pi * panelExtent,
            child: Icon(
              Icons.keyboard_arrow_up_rounded,
              color: dc.textSecondary,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  DRAGGABLE BOTTOM PANEL (Uber Driver style)
  // ═══════════════════════════════════════════════════
  Widget _buildDraggablePanel(EdgeInsets pad) {
    final dc = DriverColors.of(context);
    final panelH =
        _panelCollapsedH + (_panelExpandedH - _panelCollapsedH) * panelExtent;
    final hasActiveTrip = _activeTripData != null;

    return GestureDetector(
      // Consume taps so panel never opens on tap — swipe-only
      onTap: () {},
      child: Container(
        height: panelH + pad.bottom,
        decoration: BoxDecoration(
          // The ground the panel's cards sit on, so neuBase — neuBox cannot
          // express a top-only radius, hence the dual shadow spelled out here.
          //
          // This was neuSurface, which is the colour of the cards themselves.
          // The earnings card, the chart and the GO bar were then raised
          // surfaces on a surface of the same tone, with nothing between them
          // for their shadows to describe. Same fault the rider's booking sheet
          // had, and the same fix: a raised thing needs a base to rise from.
          color: neuBase,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              offset: const Offset(6, 6),
              blurRadius: 14,
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.045),
              offset: const Offset(-4, -4),
              blurRadius: 10,
            ),
          ],
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
          ),
        ),
        child: Column(
          children: [
            // ── Drag handle — drag only registered here ──
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) => setState(() => _dragging = true),
              onVerticalDragUpdate: (d) {
                setState(() => _dragging = true);
                updatePanelDrag(d.primaryDelta ?? 0);
              },
              onVerticalDragEnd: (d) {
                setState(() => _dragging = false);
                endPanelDrag(d.primaryVelocity ?? 0);
              },
              child: Padding(
                // 8/4, trimmed from 10/6 — see _panelBaseMinH. The handle keeps
                // its 36×4 bar and its drag target is the whole row above, so
                // the four points come off the air around it, not off anything
                // the thumb has to hit.
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // ── Scheduled Rides Banner (only when online & no active trip) ──
            if (_isStillOnline && _activeTripData == null)
              _buildScheduledRidesBanner(),

            // ── Header row: photo | status | list — also draggable ──
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) => setState(() => _dragging = true),
              onVerticalDragUpdate: (d) {
                setState(() => _dragging = true);
                updatePanelDrag(d.primaryDelta ?? 0);
              },
              onVerticalDragEnd: (d) {
                setState(() => _dragging = false);
                endPanelDrag(d.primaryVelocity ?? 0);
              },
              child: Padding(
                // vertical 8, trimmed from 10 — see _panelBaseMinH. The row is
                // 26 points of text between these two, so 8/26/8 is 42 and the
                // sheet's 60 has two points spare over the handle's 16.
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    // Status text
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isStillOnline
                                ? const Color(0xFF34C759)
                                : dc.text.withValues(alpha: 0.3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isStillOnline
                              ? S.of(context).findingTrips
                              : S.of(context).youreOffline,
                          style: TextStyle(
                            color: dc.text,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    // A chevron that tells you which way the sheet goes.
                    //
                    // This was a list button opening trip history — a second
                    // destination competing with the sheet's own handle for a
                    // thumb that is already there to drag. The affordance the
                    // spot needs is "there is more, pull it up", so that is
                    // what it shows now: an arrow that turns over as the sheet
                    // opens, so it always points the way it will next travel.
                    _buildPanelChevron(dc),
                  ],
                ),
              ),
            ),
            // The GO button used to sit here, inside the column, and a
            // 72 px spacer was left behind to hold its place.
            //
            // That was the wrong end. The button travels to the *bottom* of
            // the screen as the sheet opens — see _buildMorphingGoButton —
            // so reserving the room up here left a band of nothing under
            // "You're offline" while the button came down on top of the last
            // row of the list. The room it needs is reserved at the foot of
            // the scrolling content instead, below.

            // ── Panel content — hidden when collapsed; fades/slides in
            // proportionally to the drag for a fluid open gesture ──
            Expanded(
              child: Opacity(
                // 0 when closed → fully visible ~60% through the swipe up
                opacity: (panelExtent * 1.7).clamp(0.0, 1.0),
                child: FadeTransition(
                  opacity: _statsAnim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.05),
                      end: Offset.zero,
                    ).animate(_statsAnim),
                    child: SingleChildScrollView(
                      // Scrollable, where it used to be locked.
                      //
                      // The content grew — Cruise Level and the earnings chart
                      // joined the stats and the recommendations — and locked
                      // physics do not shrink to fit, they clip. On a short phone
                      // the last rows simply vanished with no way to reach them.
                      // The panel's drag lives on the handle and the status row,
                      // so a scrollable body here cannot fight it.
                      physics: const ClampingScrollPhysics(),
                      // The foot of the list clears the GO button hovering
                      // over it: the button's own height, the gap it keeps
                      // above the home indicator, and a little air on top.
                      // Without this the last row sits underneath it.
                      padding: EdgeInsets.fromLTRB(
                        20,
                        8,
                        20,
                        8 +
                            _kGoPillH +
                            26 +
                            MediaQuery.of(context).padding.bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Divider(
                            color: dc.divider,
                            height: 1,
                          ),
                          const SizedBox(height: 14),
                          // ── Cruise Level ──
                          _buildCruiseLevelRow(dc),
                          const SizedBox(height: 16),
                          // Only there when there is a reservation to take.
                          _buildReservedRidesCard(dc),
                          // ── Earnings: period toggle + chart + see more ──
                          Text(
                            S.of(context).earningsTitle,
                            style: TextStyle(
                              color: dc.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildEarningsSection(dc),
                          const SizedBox(height: 16),
                          // ── Trips and hours ──
                          // Earnings moved to the top pill and the chart above, so
                          // only the two figures that are not money left here.
                          Row(
                            children: [
                              _panelStat(
                                Icons.local_taxi_rounded,
                                '$_todayTrips',
                                S.of(context).tripsToday,
                              ),
                              const SizedBox(width: 8),
                              _panelStat(
                                Icons.schedule_rounded,
                                _onlineTimeText(_todayHours),
                                S.of(context).hoursOnline,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            S.of(context).recommendedForYou,
                            style: TextStyle(
                              color: dc.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 12),
                          // ── Recommendation items — raised neu group ──
                          Container(
                            decoration: neuBox(radius: 20),
                            child: Column(
                              children: [
                                _recommendItem(
                                  Icons.bar_chart_rounded,
                                  S.of(context).seeEarningsTrends,
                                  () {
                                    Navigator.of(context).push(
                                      slideFromRightRoute(
                                          const DriverEarningsScreen()),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: pad.bottom + 16),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recommendItem(IconData icon, String label, VoidCallback onTap) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: dc.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: dc.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelStat(IconData icon, String value, String label) {
    final dc = DriverColors.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: neuBox(radius: 18),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: _gold, size: 18),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                color: dc.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: dc.textSecondary,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickStat(String value, String label, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider() {
    return Container(
      width: 1,
      height: 36,
      color: Colors.white.withValues(alpha: 0.06),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Map style now from MapStyles.dark (config/map_styles.dart)

  Future<void> _refreshActiveTripStatus() async {
    final driverId = _driverId;
    if (driverId == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('trips')
          .where('status', whereIn: const [
            'accepted',
            'driver_arriving',
            'driver_en_route',
            'en_route_to_pickup',
            'arrived',
            'driver_arrived',
            'in_trip',
            'in_progress',
            'rider_onboard',
            'on_trip',
          ])
          .limit(25)
          .get();

      Map<String, dynamic>? active;
      for (final doc in snap.docs) {
        final data = doc.data();
        final rawDriverId = data['driverId'] ?? data['driver_id'];
        final rawDriverStr = (rawDriverId ?? '').toString().trim();
        final driverIdStr = driverId.toString();
        final matches = rawDriverStr == driverIdStr ||
            rawDriverStr == 'sql_$driverIdStr' ||
            rawDriverStr.replaceFirst(_sqlPrefixRe, '') == driverIdStr;
        if (matches) {
          active = {'_docId': doc.id, ...data};
          break;
        }
      }

      if (!mounted) return;

      // Firestore is a mirror of the trips table, not the table. Confirm
      // with the server before acting on it.
      //
      // The mirror goes stale in one direction only — it keeps trips open
      // that the backend has already closed — because the app's own
      // `completed` write is the last step of the finish path and is the one
      // most likely to be dropped: rejected while the Firebase session is
      // invalid, or lost when the driver closes the app during the 1.5 s
      // hand-off to the rating screen. Two of driver 44's rides have sat at
      // `arrived` since 29 and 30 July for exactly that reason.
      //
      // Left untrusted-but-unchecked, a stale doc is permanent. It sends the
      // driver back into the trip screen on every launch, and the only way
      // out of that screen is to finish the trip again — which writes the
      // same doc that is already failing to be written. This check is what
      // breaks the loop.
      bool confirmedOver = false;
      if (active != null && await _serverSaysTripIsOver(_tripSqlId(active))) {
        debugPrint(
            '[DriverHome] ignoring stale Firestore trip ${active['_docId']}');
        active = null;
        confirmedOver = true;
      }
      if (!mounted) return;

      if (active != null) {
        setState(() {
          _activeTripData = active;
          _isStillOnline = true;
        });
        return;
      }

      // Only a confirmed ending clears what we are holding.
      //
      // Firestore finding nothing is not proof — an empty local cache and a
      // rules rejection both look exactly like this, and clearing on either
      // would erase a trip _checkBackendActiveTrip had just fetched from the
      // server. But this method is also what _resumeActiveTripBody calls to
      // decide whether the ride is over and polling should start again, and
      // before this it had no path that could ever set _activeTripData back
      // to null. So it always decided the ride was still on.
      if (confirmedOver && _activeTripData != null) {
        setState(() => _activeTripData = null);
      }
    } catch (_) {
      // Keep current UI state if this lookup fails.
    }
  }

  /// True only when the server has confirmed this trip is finished.
  ///
  /// The distinction that matters is "closed" versus "could not tell". A
  /// driver mid-ride in a parking garage gets timeouts, and Railway answers
  /// 502 for a few seconds during every redeploy — neither is a reason to
  /// take their trip screen away, so anything inconclusive returns false and
  /// the trip stays. Only a definite answer clears it: a status the state
  /// machine treats as terminal, or a 404 saying the trip is not there at
  /// all. Same tri-state rule as ApiService.isTokenValid, and for the same
  /// reason — see rule 21 in CLAUDE.md.
  Future<bool> _serverSaysTripIsOver(int tripId) async {
    if (tripId <= 0) return true; // no id to check; never resumable
    try {
      final trip =
          await ApiService.getTrip(tripId).timeout(const Duration(seconds: 8));
      final status = (trip['status'] ?? '').toString().trim().toLowerCase();
      return _kFinishedTripStatuses.contains(status);
    } on ApiException catch (e) {
      // 404 is an answer: the trip is gone. 401/500/502 are not.
      return e.statusCode == 404;
    } catch (_) {
      return false; // offline or timed out — assume the ride is still on
    }
  }

  /// Check backend for active trip (handles reinstall where Firestore cache
  /// may be empty). Auto-navigates to the trip screen on cold start.
  Future<void> _checkBackendActiveTrip() async {
    try {
      // Skip if Firestore already found an active trip
      if (_activeTripData != null) return;
      final trip = await ApiService.getActiveTrip();
      if (!mounted || trip == null) return;
      final status = (trip['status'] ?? '').toString();
      if (status == 'completed' ||
          status == 'canceled' ||
          status == 'cancelled') return;
      final activeStatuses = {
        'accepted',
        'driver_en_route',
        'driver_arriving',
        'en_route_to_pickup',
        'arrived',
        'driver_arrived',
        'in_trip',
        'in_progress',
        'rider_onboard',
        'on_trip'
      };
      if (!activeStatuses.contains(status)) return;

      if (!mounted) return;
      setState(() {
        _activeTripData = trip;
        _isStillOnline = true;
      });
      // Auto-navigate to the active trip screen
      if (mounted) _resumeActiveTrip();
    } catch (e) {
      debugPrint('[DriverHome] Backend active trip check failed: $e');
    }
  }

  /// Check if driver has a scheduled ride approaching — navigate to details if locked.
  Future<void> _checkScheduledRideLockout() async {
    try {
      final data = await ApiService.getActiveScheduledTrip();
      if (!mounted) return;
      final hasTrip = data['has_scheduled_trip'] == true;
      final isLocked = data['is_locked'] == true;
      if (hasTrip && isLocked && data['trip'] != null) {
        final minutesUntil = (data['minutes_until'] as num?)?.toDouble() ?? 30;
        final trip = data['trip'] as Map<String, dynamic>;

        // ── Auto-start: <=15 min → start trip + navigate to trip screen directly ──
        // BUT only if driver doesn't already have an active trip
        if (minutesUntil <= 15 && _activeTripData == null) {
          try {
            final tripId = trip['id'] as int;
            await ApiService.startScheduledTrip(tripId);
            if (!mounted) return;
            _navigateToScheduledTripScreen(trip);
          } catch (e) {
            debugPrint(
                '[DriverHome] Auto-start scheduled trip failed: $e — showing countdown instead');
            if (!mounted) return;
            _showScheduledCountdown(trip, minutesUntil);
          }
          return;
        }

        // ── >15 min but locked → show countdown screen ──
        _showScheduledCountdown(trip, minutesUntil);
      }
    } catch (e) {
      debugPrint('[DriverHome] Scheduled ride check failed: $e');
    }
  }

  void _showScheduledCountdown(Map<String, dynamic> trip, double minutesUntil) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ScheduledRideDetailsScreen(
          trip: trip,
          minutesUntil: minutesUntil,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Unmount our native map while a trip screen is on top of us.
  ///
  /// DriverTripAcceptScreen mounts its own MapWidget, and two live native
  /// Mapbox surfaces at once is the iOS crash on accept — and the crash
  /// loop on relaunch with an active trip. The controller and annotation
  /// manager belong to the PlatformView being destroyed, so they go with
  /// it; onMapCreated rebuilds both (and the location dot) on remount.
  void _suspendMap() {
    if (_mapSuspended || !mounted) return;
    setState(() {
      _mapSuspended = true;
      _mapReady = false;
    });
    _mapController = null;
    _pointAnnotMgr = null;
    _dropLocAnnot();
  }

  /// Bring the map back once the screen above us is gone.
  ///
  /// Only when nothing is on top of us any more. A trip screen that ends
  /// with `pushAndRemoveUntil(DriverOnlineScreen, (r) => r.isFirst)` hands
  /// control straight to another map-owning screen without ever popping
  /// back to us — remounting there would put two native surfaces up again,
  /// which is the crash this whole path exists to avoid.
  void _unsuspendMap() {
    if (!_mapSuspended || !mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    unawaited(_acquireMapSurface());
  }

  /// Claim the one live Mapbox surface, then bring our map back.
  ///
  /// Going through the coordinator rather than flipping the flag closes the
  /// case the isCurrent guard above cannot see: we can be the top route
  /// while the screen that just left is still tearing its PlatformView
  /// down. Remounting into that overlap is the same two-surface crash,
  /// arrived at from the other direction.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _kHomeMapSurfaceOwner,
      onRevoke: () async {
        // Confirm the teardown even when the flag is already down.
        //
        // `_mapSuspended` is set by setState, which only schedules the
        // rebuild — the element unmounts a frame later and the PlatformView
        // is disposed over the channel after that. So a revoke arriving in
        // that window saw the flag already true and returned instantly,
        // telling the coordinator the surface was free while the native view
        // was still being torn down. The incoming screen then mounts the
        // second one, and two live surfaces close the app on iOS.
        //
        // The window is small and needs a revoke to land inside it, which is
        // exactly what going online does: it suspends this map and claims
        // the surface in the same handful of frames.
        //
        // surfaceRemoved() costs about two frames and races a timer, so
        // waiting here cannot hang the handoff.
        if (!mounted) return;
        if (!_mapSuspended) _suspendMap();
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_kHomeMapSurfaceOwner);
      return;
    }
    // Only remount if we are the visible route. A trip screen that ends with
    // pushAndRemoveUntil hands straight over to a new online screen without
    // ever popping back to us; mounting there would fight it for the surface.
    //
    // One retry, because didPopNext fires as the pop begins: on a 300 ms
    // transition we can still be behind the outgoing route at this point,
    // and giving up silently is how the driver returns from a menu to a
    // black card that never comes back.
    if (ModalRoute.of(context)?.isCurrent != true) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
        MapSurfaceCoordinator.instance.release(_kHomeMapSurfaceOwner);
        return;
      }
    }
    setState(() => _mapSuspended = false);
  }

  /// Navigate directly to DriverTripAcceptScreen for a scheduled trip.
  void _navigateToScheduledTripScreen(Map<String, dynamic> trip) {
    final pickupLat = _pickDouble(trip, ['pickup_lat']);
    final pickupLng = _pickDouble(trip, ['pickup_lng']);
    final dropoffLat = _pickDouble(trip, ['dropoff_lat']);
    final dropoffLng = _pickDouble(trip, ['dropoff_lng']);
    if (pickupLat == null ||
        pickupLng == null ||
        dropoffLat == null ||
        dropoffLng == null) {
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    final driverPos = _currentLatLng ?? pickup;
    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);
    final tripId = (trip['id'] as num?)?.toInt() ?? 0;
    final riderName = _pickString(trip, ['rider_name'], fallback: 'Rider');
    final riderId = int.tryParse((trip['rider_id'] ?? '').toString());

    _suspendMap();
    Navigator.of(context)
        .push(
          slideFromRightRoute(
            DriverTripAcceptScreen(
              tripId: tripId,
              riderName: riderName,
              riderPhotoUrl:
                  _normalizePhotoUrl(trip['rider_photo_url']?.toString() ?? ''),
              riderRating: (trip['rider_rating'] as num?)?.toDouble() ?? 0,
              riderIsNew: trip['rider_is_new'] == true,
              riderId: riderId,
              pickupLatLng: pickup,
              dropoffLatLng: dropoff,
              pickupAddress:
                  _pickString(trip, ['pickup_address'], fallback: 'Pickup'),
              dropoffAddress:
                  _pickString(trip, ['dropoff_address'], fallback: 'Drop-off'),
              fare: _pickDouble(trip, ['fare']) ?? 0,
              vehicleType:
                  _pickString(trip, ['vehicle_type'], fallback: 'Comfort'),
              driverPos: driverPos,
              distToPickupKm: distKm,
              etaMinutes: etaMinutes,
              riderPhone: _pickString(trip, ['rider_phone']),
              tripAlreadyStarted: true,
            ),
          ),
        )
        .whenComplete(() => _unsuspendMap());
  }

  Future<void> _resumeActiveTrip() async {
    // Idempotency guard — 6 callers, any two firing concurrently would
    // push DriverTripAcceptScreen twice.
    if (_resumingActiveTrip) {
      debugPrint(
          '[DriverHome] _resumeActiveTrip skipped — already in progress');
      return;
    }
    // Don't re-push DriverTripAcceptScreen if DriverHomeScreen is not the
    // topmost route — that means a trip screen is already on the stack and
    // pushing another one on top would reset its local state (the Arrived
    // slider, Start Ride button, etc.) back to phase 1. This fires on every
    // app-resume after the driver used Google Maps for turn-by-turn.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      debugPrint(
          '[DriverHome] _resumeActiveTrip skipped — another route is on top');
      return;
    }
    _resumingActiveTrip = true;
    try {
      await _resumeActiveTripBody();
    } finally {
      _resumingActiveTrip = false;
    }
  }

  Future<void> _resumeActiveTripBody() async {
    // Use existing trip data immediately — don't block on Firestore.
    // Refresh in background for status updates, but navigate instantly.
    if (_activeTripData != null) {
      unawaited(_refreshActiveTripStatus());
    } else {
      // No cached data — must fetch before navigating
      await _refreshActiveTripStatus();
    }
    final trip = _activeTripData;
    if (!mounted || trip == null) return;

    final pickupLat = _pickDouble(trip, ['pickupLat', 'pickup_lat']);
    final pickupLng = _pickDouble(trip, ['pickupLng', 'pickup_lng']);
    final dropoffLat = _pickDouble(trip, ['dropoffLat', 'dropoff_lat']);
    final dropoffLng = _pickDouble(trip, ['dropoffLng', 'dropoff_lng']);
    if (pickupLat == null ||
        pickupLng == null ||
        dropoffLat == null ||
        dropoffLng == null) {
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    final driverPos = _currentLatLng ?? pickup;
    final tripId = _tripSqlId(trip);
    if (tripId <= 0) {
      // Nothing downstream works without the real id — the trip screen would
      // PATCH /trips/0, the rating screen would rate trip 0, and every one of
      // those calls comes back 404. The driver ends up on a screen whose
      // buttons do nothing, which is how a finished trip turned into a trap.
      debugPrint(
          '[DriverHome] active trip has no usable id: ${trip.keys.toList()}');
      if (mounted) setState(() => _activeTripData = null);
      return;
    }
    final riderName = _pickString(
        trip, ['riderName', 'rider_name', 'passengerName', 'passenger_name'],
        fallback: 'Rider');
    final riderPhone =
        _pickString(trip, ['rider_phone', 'passengerPhone', 'passenger_phone']);
    final pickupAddress = _pickString(trip, ['pickupAddress', 'pickup_address'],
        fallback: 'Pickup');
    final dropoffAddress = _pickString(
        trip, ['dropoffAddress', 'dropoff_address'],
        fallback: 'Drop-off');
    final fare = _pickDouble(trip, ['fare']) ?? 0;
    final vehicleType =
        _pickString(trip, ['vehicleType', 'vehicle_type'], fallback: 'Ride');

    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);

    // Determine trip phase from Firestore status so the screen resumes
    // at the correct phase instead of resetting to "Slide Start Trip".
    final status = _pickString(trip, ['status'], fallback: 'accepted');
    final arrivedAtPickup = (status == 'arrived' || status == 'driver_arrived');
    final rideStarted = (status == 'in_trip' ||
        status == 'in_progress' ||
        status == 'rider_onboard');

    // Extract rider SQL integer ID from riderId/passengerId ("sql_123" → 123)
    final passengerIdRaw = _pickString(
        trip, ['riderId', 'rider_id', 'passengerId', 'passenger_id']);
    final resumeRiderId = int.tryParse(passengerIdRaw.replaceFirst('sql_', ''));

    // Drop our native map before the trip screen mounts its own — two live
    // Mapbox surfaces on iOS is the crash this whole path kept hitting on
    // relaunch. _unsuspendMap remounts it when the trip screen pops.
    _suspendMap();
    try {
      await Navigator.of(context).push(
        slideFromRightRoute(
          DriverTripAcceptScreen(
            tripId: tripId,
            riderName: riderName,
            riderPhotoUrl: _normalizePhotoUrl(
              _pickString(trip, [
                'riderPhotoUrl',
                'rider_photo_url',
                'passengerPhotoUrl',
                'passenger_photo_url'
              ]),
            ),
            riderRating:
                _pickDouble(trip, ['riderRating', 'rider_rating']) ?? 0,
            riderIsNew: trip['rider_is_new'] == true,
            riderId: resumeRiderId,
            pickupLatLng: pickup,
            dropoffLatLng: dropoff,
            pickupAddress: pickupAddress,
            dropoffAddress: dropoffAddress,
            fare: fare,
            vehicleType: vehicleType,
            driverPos: driverPos,
            distToPickupKm: distKm,
            etaMinutes: etaMinutes,
            riderPhone: riderPhone,
            pickupInstructions: _pickString(
                trip, ['pickupInstructions', 'pickup_instructions']),
            dropoffInstructions: _pickString(
                trip, ['dropoffInstructions', 'dropoff_instructions']),
            arrivedAtPickup: arrivedAtPickup,
            rideStarted: rideStarted,
            tripAlreadyStarted: true,
          ),
        ),
      );
    } finally {
      _unsuspendMap();
    }

    // After trip screen pops, re-check if the trip is still active.
    // If completed/cancelled, clear state and resume polling for new trips.
    // If still active, just refresh _activeTripData so RESUME button shows —
    // do NOT auto-navigate back (driver chose to go home).
    if (!mounted) return;
    await _refreshActiveTripStatus();
    if (_activeTripData == null && _isStillOnline) {
      _startTripPolling();
    }
  }

  /// The SQL trip id, whatever shape the record arrived in. 0 when there
  /// isn't one.
  ///
  /// Backend JSON carries `id`. The Firestore mirror does not — its fields
  /// are `sqliteId` plus a document named `sql_<id>`, and nothing in it is
  /// called `id` at all. So the old lookup (`id`/`tripId`/`trip_id`, then
  /// `int.tryParse('sql_405')`) missed on every Firestore-sourced trip and
  /// fell through to its `?? 0` default.
  ///
  /// Zero is the worst possible failure here because it is a valid-looking
  /// int: it sails into DriverTripAcceptScreen, and from there every status
  /// PATCH, the fare lookup and the rating submit all address trip 0 and come
  /// back 404. The screen keeps working, the buttons keep responding, and
  /// nothing they do reaches the server — which is exactly what a driver
  /// stuck on the rating screen was looking at.
  int _tripSqlId(Map<String, dynamic> data) {
    final direct = _pickInt(data, const [
      'id',
      'tripId',
      'trip_id',
      'sqliteId',
      'sqlite_id',
    ]);
    if (direct != null && direct > 0) return direct;
    final docId = (data['_docId'] ?? '').toString();
    return int.tryParse(docId.replaceFirst(_sqlPrefixRe, '')) ?? 0;
  }

  double? _pickDouble(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v is num) return v.toDouble();
      final parsed = double.tryParse(v?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _pickInt(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      final parsed = int.tryParse(v?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  String _pickString(Map<String, dynamic> data, List<String> keys,
      {String fallback = ''}) {
    for (final k in keys) {
      final v = data[k]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return fallback;
  }

  String _normalizePhotoUrl(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sa = math.sin(dLat / 2);
    final sb = math.sin(dLng / 2);
    final aa = sa * sa +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sb *
            sb;
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }
}

/// The radar inside the round GO button.
///
/// Three rings expanding out of the centre, staggered a third of a cycle
/// apart and fading as they grow, so there is always one leaving and one
/// arriving — a pulse with no gap in it. Drawn rather than animated with
/// widgets because it is three circles: a stack of AnimatedContainers for
/// that would cost three elements and a layout pass per frame to say the
/// same thing.
///
/// [progress] is a 0-to-1 that already loops; the painter adds the stagger,
/// so the button does not need three controllers of its own.
class _GoRadarPainter extends CustomPainter {
  const _GoRadarPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide / 2;
    if (maxR <= 0) return;

    // The band the rings live in: clear of the lettering at the centre,
    // clear of the rim at the edge.
    //
    // A ring that crosses the word cuts through it — the two are the same
    // gold and there is no depth to tell them apart. A ring that reaches
    // the rim gets sliced flat by the clip, which turns a circle into an
    // arc for the last of its life. Both ends are held off deliberately.
    const inner = 0.62;
    const outer = 0.90;

    for (int i = 0; i < 3; i++) {
      final t = (progress + i / 3.0) % 1.0;
      // Ease out: quick at birth, drifting by the time it fades. A ring
      // travelling at constant speed reads as mechanical; this is what
      // makes a slow animation feel unhurried rather than merely slow.
      final e = 1.0 - math.pow(1.0 - t, 2.2).toDouble();
      final r = maxR * (inner + (outer - inner) * e);

      // Fade in over the first sliver so a ring never pops into existence
      // on top of the word, then fade out squared so it reads as leaving
      // rather than as being switched off.
      final fadeIn = (t / 0.12).clamp(0.0, 1.0);
      final a = fadeIn * (1.0 - e) * (1.0 - e) * 0.5;
      if (a <= 0.01) continue;

      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          // Thinning as it travels: a ring keeping its weight while it
          // grows looks like it is being drawn, not like it is spreading.
          ..strokeWidth = 1.8 - 0.9 * e
          ..color = color.withValues(alpha: a),
      );
    }
  }

  @override
  bool shouldRepaint(_GoRadarPainter old) =>
      old.progress != progress || old.color != color;
}
