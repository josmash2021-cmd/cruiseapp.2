part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  CONTROLLER — boot, GPS, polling, offers, navigation, trips
// ══════════════════════════════════════════════════════════════

// ── Global guards against polling storm (P1 fix) ──
// These survive widget rebuilds and prevent multiple DriverOnlineScreen
// instances from creating overlapping poll timers.
int _driverOnlinePollingGen = 0;
bool _driverOnlinePollLock = false;
DateTime? _driverOnlineLastStartPolling;

final _htmlTagRe = RegExp(r'<[^>]*>');

/// Identifies this screen to [MapSurfaceCoordinator].
const String _kMapSurfaceOwner = 'DriverOnline';

/// How long the camera takes to glide back to the driver on a recentre.
///
/// Top-level rather than a class static because it is used inside a `const
/// Duration(...)` from a part file, and the iOS compiler rejects that as
/// "not a constant expression" — see rule 16 in CLAUDE.md.
///
/// Shared by the flight itself and by the timer that hands the overlay back
/// to centred mode when it lands. The two must not drift: if the flight
/// outlives the timer, the arrow snaps to the middle before the map gets
/// there, which is the jump this pair exists to remove.
const int _kRecenterFlightMs = 600;

extension _DriverOnlineController on _DriverOnlineScreenState {
  String _normalizePhotoUrl(dynamic rawUrl) {
    final raw = (rawUrl ?? '').toString().replaceAll('"', '').trim();
    if (raw.isEmpty) return '';
    // Filter Python/JS sentinel strings that backend may send
    if (raw == 'null' || raw == 'None' || raw == 'undefined' || raw == 'none') {
      return '';
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOOT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _boot() async {
    // Fire driver-ID resolution in background — don't block boot.
    // _verifyAndGoOnline retries if this hasn't resolved yet.
    unawaited(Future.microtask(() async {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('Got driverId');
        }
      } catch (e) {
        debugPrint('getCurrentUserId failed: $e');
      }
    }));

    // Let the page transition animation settle before starting
    // background services (400ms transition + small buffer).
    // Use addPostFrameCallback so we don't block the first build frame.
    // Start everything immediately — no artificial delays
    // Stagger service initialization to prevent UI thread saturation.
    // Each service starts in its own microtask so the framework can
    // pump frames between them — eliminates the 1s freeze on entry.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _startClock();
      await Future.microtask(() => _startPolling());
      if (!mounted) return;
      await Future.microtask(() => _startPosStream());
      if (!mounted) return;
      await Future.microtask(() => _loadAllEarnings());
      if (!mounted) return;
      await Future.microtask(() => _startEarningsRefresh());
      if (!mounted) return;
      await Future.microtask(() => _startScheduledPoll());
      if (!mounted) return;
      // Fire-and-forget: these must not block the UI thread
      unawaited(_locate());
      // Coming back to a shift that never stopped: already approved, so the
      // screen opens in the searching state instead of replaying the
      // go-online sequence and its spinner.
      //
      // The backend registration still runs. It is the only caller of
      // startOnline(), of the persistent online notification and of the
      // scheduled-rides topic subscription, so skipping it left a resumed
      // driver with no Live Activity to update when an offer arrived. It is
      // also the only thing that sets _approvalGatePassed, and
      // _goOnlineBackend bails on a false gate — so without this both
      // recovery paths that call it (network recovery below, driver-id
      // recovery in _poll) were dead for the rest of the session.
      //
      // SSE is already connected by _startPolling above; connecting again
      // here would only tear that one down a generation later.
      // Up front, on both paths. The driver is on the online screen, so the
      // lock screen should say so now rather than after a network round trip
      // that may never complete.
      _showOnlinePresence();
      if (widget.resuming) {
        _approvalGatePassed = true;
        _setState(() => _isGoingOnline = false);
        _goOnlineBackend();
      } else {
        unawaited(Future.microtask(_verifyAndGoOnline));
      }
    });

    // Listen for network recovery — proactively reconnect SSE + re-register
    // online status when connectivity returns after a drop.
    _networkListener = () {
      if (!mounted) return;
      final online = NetworkService().isOnline;
      if (online && _phase == _Phase.searching && !_sseActive) {
        debugPrint(
            '[DriverOnline] Network recovered — reconnecting SSE + re-registering online');
        _connectSse();
        _goOnlineBackend();
      }
    };
    NetworkService().onlineNotifier.addListener(_networkListener!);

    // Build vehicle icons immediately — if there's jank, fix the animation, don't delay
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _buildVehicleIcons();
    });

    // Pre-cache map tiles in background (fire-and-forget)
    if (_pos != null) {
      unawaited(MapCacheService().precacheArea(
        regionId: 'driver_area_${_driverId ?? 0}',
        lat: _pos!.latitude,
        lng: _pos!.longitude,
        minZoom: 10,
        maxZoom: 16,
        radiusKm: 5.0,
      ));
    }
  }

  /// Background verification + go-online — never blocks boot.
  Future<void> _verifyAndGoOnline() async {
    // Signal UI immediately that we're going online — don't wait for any API
    _setState(() => _isGoingOnline = true);

    // Retry driver ID if first attempt failed
    if (_driverId == null) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        try {
          final id = await ApiService.getCurrentUserId();
          if (!mounted) return;
          if (id != null) {
            _driverId = id;
            debugPrint('✅ Got driverId on retry $attempt');
            // Reconnect SSE now that we have an ID
            _connectSse();
            _startPosStream();
            break;
          }
        } catch (_) {}
      }
    }
    if (!mounted) {
      _setState(() => _isGoingOnline = false);
      return;
    }
    await _verifyDriverApproval();
    if (!mounted) {
      _setState(() => _isGoingOnline = false);
      return;
    }
    _goOnlineBackend();
  }

  /// Id of the offer whose card is at the head of the stack, or null when
  /// there is none.
  String? get _headOfferId => _pendingOffers.isEmpty
      ? null
      : (_pendingOffers.first['offer_id'] ?? _pendingOffers.first['id'])
          ?.toString();

  /// Point the iOS Live Activity at the offer at the head of
  /// [_pendingOffers], or — with no offer — at whether the driver is
  /// driving someone or waiting for the next ride.
  ///
  /// Derived from those two pieces of state rather than pushed from each
  /// path that changes them: accept, chained accept, decline, rider-cancel
  /// and trip-complete all empty the offer list in their own `setState`, and
  /// all but one of them used to forget the island — so a ride the driver
  /// had already accepted stayed on their lock screen for the whole trip.
  /// The clock calls this too, so a path added later that forgets
  /// self-corrects within five seconds.
  ///
  /// [force] re-sends the same state, for when an offer's road metrics land
  /// after its card was first drawn from the haversine fallback.
  void _syncOfferLiveActivity({bool force = false}) {
    if (!mounted) return; // _offerLiveActivityFields reads S.of(context)
    final head = _headOfferId;
    // 'online' reads "receiving trips", which is a false statement to leave
    // on the lock screen of someone with a passenger in the car.
    final next = head != null
        ? 'offer:$head'
        : (_phase == _Phase.searching ? 'online' : 'on_trip');
    if (next == _islandState && !force) return;
    _islandState = next;
    if (head == null) {
      unawaited(LiveActivityService.updateStatus(next));
      return;
    }
    final la = _offerLiveActivityFields(_pendingOffers.first);
    unawaited(LiveActivityService.showOffer(
      fare: la['fare']!,
      perHour: la['perHour']!,
      miles: la['miles']!,
      minutes: la['minutes']!,
    ));
  }

  /// The four strings the iOS offer card shows, built from the same
  /// numbers as the in-app offer card: the fare, what the ride pays per
  /// hour of the driver's time (drive-to-pickup included, because that
  /// time is spent whether or not it is paid), and the totals for distance
  /// and time. Real Directions metrics when the route cache has them, the
  /// same haversine fallback the card uses when it does not.
  ///
  /// Formatted here rather than in Swift so both surfaces read from one
  /// place — a second formatter is a second place for the driver's pay to
  /// disagree with itself.
  Map<String, String> _offerLiveActivityFields(Map<String, dynamic> offer) {
    final fare = _safeDouble(offer['fare']);
    final pickupLat = _safeDouble(offer['pickup_lat']);
    final pickupLng = _safeDouble(offer['pickup_lng']);
    final dropoffLL =
        LatLng(_safeDouble(offer['dropoff_lat']), _safeDouble(offer['dropoff_lng']));
    final pickupLL = LatLng(pickupLat, pickupLng);
    final offerId = (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng')
        .toString();

    final cached = _routeCache[offerId];
    int etaToPickup;
    int tripEta;
    double distToPickupMi;
    double tripDistMi;
    if (cached?.driverToPickupKm != null && cached?.pickupToDropoffKm != null) {
      etaToPickup = (cached!.driverToPickupMin ?? 1).ceil().clamp(1, 99);
      distToPickupMi = cached.driverToPickupKm! * 0.621371;
      tripEta = (cached.pickupToDropoffMin ?? 1).ceil().clamp(1, 99);
      tripDistMi = cached.pickupToDropoffKm! * 0.621371;
    } else {
      var dtp = _pos != null ? _hav(_pos!, pickupLL) : 0.0;
      if (!dtp.isFinite) dtp = 0;
      var trip = _hav(pickupLL, dropoffLL);
      if (!trip.isFinite) trip = 0;
      etaToPickup = (dtp * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      tripEta = (trip * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      distToPickupMi = dtp * 0.621371;
      tripDistMi = trip * 0.621371;
    }

    final totalMin = (etaToPickup + tripEta).clamp(1, 999);
    final hourly = fare / (totalMin / 60.0);
    // Same strings the card builds from the same numbers: two decimals on
    // the rate, and offerDuration so an 80-minute ride reads "1 h 20 min"
    // on the lock screen too, rather than the "80 min" the driver would
    // have had to divide in their head. "mi" is left as-is in both
    // languages, matching offerAway/offerTrip.
    final s = S.of(context);
    return {
      'fare': '\$${fare.toStringAsFixed(2)}',
      'perHour': s.offerHourlyRateShort(hourly.toStringAsFixed(2)),
      'miles': '${(distToPickupMi + tripDistMi).toStringAsFixed(1)} mi',
      'minutes': s.offerDuration(totalMin),
    };
  }

  /// Start a periodic timer to refresh earnings every 45 seconds.
  void _startEarningsRefresh() {
    _earningsRefreshTimer?.cancel();
    _earningsRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _loadAllEarnings();
    });
  }

  /// The driver's current local day as yyyymmdd.
  ///
  /// Local, not UTC, and for the same reason the backend takes a tz_offset:
  /// a UTC day starts at 6pm the evening before in Alabama, so a driver's
  /// morning would land on the day before and "Today" would reset in the
  /// middle of their afternoon.
  int _localDayStamp() {
    final n = DateTime.now();
    return n.year * 10000 + n.month * 100 + n.day;
  }

  /// Save current earnings snapshot to SharedPreferences for instant load next time.
  Future<void> _cacheEarnings() async {
    try {
      final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
      // Use same key as driver_home_screen for shared cache
      prefs.setDouble('driver_cached_earnings', _earnings);
      // Which day that figure is from. A total without a date is only good
      // until midnight, and this one was being read back for ever.
      prefs.setInt('driver_cached_earnings_day', _localDayStamp());
      prefs.setDouble('driver_online_weekly', _weeklyEarnings);
      prefs.setDouble('driver_online_last_trip', _lastTripEarnings);
    } catch (_) {}
  }

  Future<void> _loadAllEarnings() async {
    // ── Instant: load from SharedPreferences cache first (single setState) ──
    try {
      final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
      final cachedToday = prefs.getDouble('driver_cached_earnings');
      final cachedWeekly = prefs.getDouble('driver_online_weekly');
      final cachedLastTrip = prefs.getDouble('driver_online_last_trip');
      bool changed = false;
      double newEarnings = _earnings;
      double newWeekly = _weeklyEarnings;
      double newLastTrip = _lastTripEarnings;
      // Only if the cache is from today. It is there so the card is not blank
      // for the first second after a cold start, which is worth nothing at
      // all if the number it shows belongs to a day that has ended.
      final cachedDay = prefs.getInt('driver_cached_earnings_day');
      if (_earnings == 0 &&
          cachedToday != null &&
          cachedToday > 0 &&
          cachedDay == _localDayStamp()) {
        newEarnings = cachedToday;
        changed = true;
      }
      if (_weeklyEarnings == 0 && cachedWeekly != null && cachedWeekly > 0) {
        newWeekly = cachedWeekly;
        changed = true;
      }
      if (_lastTripEarnings == 0 &&
          cachedLastTrip != null &&
          cachedLastTrip > 0) {
        newLastTrip = cachedLastTrip;
        changed = true;
      }
      if (mounted && changed) {
        _setState(() {
          _prevEarnings = _earnings;
          _earnings = newEarnings;
          _prevWeeklyEarnings = _weeklyEarnings;
          _weeklyEarnings = newWeekly;
          _prevLastTripEarnings = _lastTripEarnings;
          _lastTripEarnings = newLastTrip;
        });
      }
    } catch (_) {}

    // ── Background: fetch fresh data from API (single setState) ──
    try {
      final results = await Future.wait([
        ApiService.getDriverEarnings(period: 'week'),
        ApiService.getDriverEarnings(period: 'today'),
        ApiService.getDriverEarnings(period: 'month'),
      ]);
      if (!mounted) return;

      final weekData = results[0];
      final todayData = results[1];
      final monthData = results[2];
      final weekTotal = (weekData['total'] as num?)?.toDouble() ?? 0;
      final todayTotal = (todayData['total'] as num?)?.toDouble() ?? 0;
      final monthTotal = (monthData['total'] as num?)?.toDouble() ?? 0;
      final txns = todayData['transactions'] as List<dynamic>?;
      final lastFare = (txns != null && txns.isNotEmpty)
          ? (txns.first['fare'] as num?)?.toDouble() ?? 0.0
          : 0.0;

      bool changed = true; // the chart and counters refresh every pass
      if (monthTotal != _monthlyEarnings) changed = true;
      if (weekTotal != _weeklyEarnings) changed = true;
      if (todayTotal > _earnings) changed = true;
      if (_lastTripEarnings == 0 && lastFare > 0) changed = true;

      if (changed) {
        _setState(() {
          if (weekTotal != _weeklyEarnings) {
            _prevWeeklyEarnings = _weeklyEarnings;
            _weeklyEarnings = weekTotal;
          }
          if (monthTotal != _monthlyEarnings) {
            _prevMonthlyEarnings = _monthlyEarnings;
            _monthlyEarnings = monthTotal;
          }

          // The panel's chart and counters, out of the same two responses —
          // no extra request. Kept when a response arrives without them, so
          // a partial reply never blanks a chart that was already drawn.
          _tripsToday =
              (todayData['trips_count'] as num?)?.toInt() ?? _tripsToday;
          _hoursToday =
              (todayData['online_hours'] as num?)?.toDouble() ?? _hoursToday;
          final hourly = (todayData['hourly_earnings'] as List<dynamic>?)
              ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
              .toList(growable: false);
          if (hourly != null && hourly.length == 24) _hourlySeries = hourly;
          final daily = (weekData['daily_earnings'] as List<dynamic>?)
              ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
              .toList(growable: false);
          final dayLabels = weekData['day_labels'];
          if (daily != null &&
              daily.isNotEmpty &&
              dayLabels is List &&
              dayLabels.length == daily.length) {
            _daySeries = daily;
            _daySeriesLabels = dayLabels
                .map((e) => e?.toString() ?? '')
                .toList(growable: false);
          }
          // A new local day replaces the figure; the same day only raises it.
          //
          // Without the first branch the counters carried across midnight —
          // yesterday's money still sitting under "Today", and the trip and
          // hour counts with it — because the only way in was to be a bigger
          // number than what was already there.
          final today = _localDayStamp();
          if (_earningsDay != today) {
            _earningsDay = today;
            _prevEarnings = _earnings;
            _earnings = todayTotal;
            _tripsToday = (todayData['trips_count'] as num?)?.toInt() ?? 0;
            _hoursToday = (todayData['online_hours'] as num?)?.toDouble() ?? 0;
          } else if (todayTotal > _earnings) {
            _prevEarnings = _earnings;
            _earnings = todayTotal;
          }
          if (_lastTripEarnings == 0 && lastFare > 0) {
            _prevLastTripEarnings = _lastTripEarnings;
            _lastTripEarnings = lastFare;
          }
        });
      }
      // Save fresh data to cache
      _cacheEarnings();
    } catch (_) {}
  }

  Future<void> _locate() async {
    // Use pre-loaded GPS from splash if available (instant first fix)
    final preloaded = PreloadService.initialPosition;
    if (preloaded != null && _pos == null) {
      _pos = LatLng(preloaded.latitude, preloaded.longitude);
      if (mounted) _setState(() {});
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
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
      // requestPermission() on web is a getCurrentPosition with a one-day
      // timeout: ignore the browser prompt and the future never completes.
      // getCurrentPosition itself IS the prompt there — it resolves with a
      // real fix or rejects on deny, so ask for it instead of seeding
      // downtown Birmingham (which located every web driver in Alabama no
      // matter where they actually were).
      if (kIsWeb) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10),
            ),
          );
          debugPrint('[DriverOnline] web GPS: real browser fix');
          _setState(() => _pos = LatLng(pos.latitude, pos.longitude));
        } catch (e) {
          debugPrint('[DriverOnline] web GPS unavailable ($e) — seed fallback');
          _setState(() => _pos = const LatLng(33.5186, -86.8104));
        }
        return;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
        if (p == LocationPermission.denied) return;
      }
      if (p == LocationPermission.deniedForever) {
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
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      _setState(() => _pos = ll);
      _moveToLatLng(ll);
    } catch (_) {}
  }

  Future<void> _buildVehicleIcons() async {
    // Load ALL icons in parallel instead of sequentially
    final results = await Future.wait([
      CarIconLoader.loadForRideBytes('Suburban'),
      CarIconLoader.loadForRideBytes('Camry'),
      CarIconLoader.loadUberBytes(),
      _loadDriverPhoto(),
      renderCircularPinBytes(
          icon: CircularPinIcon.person, isPickup: true, radius: 32),
    ]);
    _suvIconBytes = results[0] as Uint8List?;
    _sedanIconBytes = results[1] as Uint8List?;
    _arrowIconBytes = _suvIconBytes;
    _navCarSprites = null;
    _navCarIconBytes = results[2] as Uint8List?;
    // results[3] is void (_loadDriverPhoto sets _driverPhotoImage internally)
    _goldPinBytes = results[4] as Uint8List?;
    await _goldDot.build(this, () {
      if (mounted) _updateDriverAnnotation();
    });
    if (!mounted) return;
    _startHeadingSource();
    // The dot image is what _updateDriverAnnotation() gates on — every call
    // before this point bailed out with no bytes. Draw it now instead of
    // waiting for the next GPS tick: a driver who goes online standing still
    // never gets one, so the dot would simply never appear.
    _updateDriverAnnotation();
    _startDotWatchdog();
    _setState(() {});
  }

  /// Low-frequency safety net for the driver dot (0.5 Hz).
  ///
  /// The dot is normally redrawn by [_onSmoothTick], but that ticker parks
  /// itself once the driver reaches the target position, so a stationary
  /// driver gets no redraws at all. Anything that leaves the annotation
  /// missing or half-scaled — late icon bytes, a dropped pop-scale flush, a
  /// map recreated on resume — would then stay broken until they drove off.
  void _startDotWatchdog() {
    // Its exit condition is a live Mapbox annotation, which the browser build
    // never creates — so on web it would rasterise the marker every two
    // seconds forever.
    if (kIsWeb) return;
    _dotWatchdog?.cancel();
    _dotWatchdog = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      // The bitmap is checked BEFORE handing off to the ticker.
      //
      // It is rasterised once, and that can fail — GPU context lost while
      // backgrounded, OOM — leaving GoldLocationDot with currentBytes null,
      // which makes every draw a silent no-op for the rest of the screen's
      // life because nothing else calls build() again.
      //
      // The ticker cannot rescue that: it redraws, and a redraw with no
      // bitmap draws nothing. So skipping this check whenever the ticker
      // happened to be running left exactly one way for the arrow to vanish
      // for good — lose the bitmap while moving, and the watchdog steps
      // aside for a ticker that has nothing to paint.
      if (!_goldDot.isReady) {
        await _goldDot.build(this, () {
          if (mounted) _updateDriverAnnotation();
        });
        if (!mounted) return;
        _updateDriverAnnotation();
        return;
      }
      // Bitmap is fine and the ticker is animating — it owns the redraws.
      if (_smoothTicker?.isTicking ?? false) return;
      _updateDriverAnnotation();
    });
  }

  /// Download and decode the driver's profile photo for the map marker.
  Future<void> _loadDriverPhoto() async {
    final url = widget.photoUrl;
    if (url == null || url.isEmpty) return;
    try {
      // Hard timeout: this download sits inside the Future.wait() that gates
      // _goldDot.build(), so a stalled request would keep the driver dot off
      // the map for as long as the socket hangs.
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final codec = await ui.instantiateImageCodec(resp.bodyBytes);
        final frame = await codec.getNextFrame();
        _driverPhotoImage = frame.image;
      }
    } catch (_) {
      // fallback to golden dot
    }
  }

  /// Renders a top-down car marker with proper car silhouette using Canvas.
  ///  - Car points UP (north) so `rotation = bearing` works correctly.
  ///  - Shaped like a real car: rounded nose, wide body, tapered trunk.
  ///  - 3D depth panels visible at 55° tilt.
  Future<Uint8List> _paintCarSprite({
    required Color bodyColor,
    required Color bodyHighlight,
    required Color windowColor,
    required Color windowShine,
    required Color trimColor,
    required Color wheelColor,
    required Color shadowColor,
    required Color headlightColor,
    required Color taillightColor,
    required double widthRatio,
    required double heightRatio,
    required double roofHeightRatio,
  }) async {
    const double cW = 180.0;
    const double cH = 300.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, cW, cH));

    final double cx = cW / 2;
    final double cy = cH / 2;
    final double bW = 60.0 * widthRatio; // half-width at widest
    final double bH = 100.0 * heightRatio; // half-height
    final double depth = 20.0 * heightRatio;

    // ── 1. DROP SHADOW ───────────────────────────────────────────────────
    canvas.drawPath(
      _carBodyPath(cx, cy + 5, bW + 8, bH + 6),
      Paint()
        ..color = shadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );

    // ── 2. 3D DEPTH — bottom face (rear bumper, visible when tilted) ─────
    canvas.drawPath(
      _carBodyPath(cx, cy + depth * 0.45, bW, bH).shift(const Offset(0, 2)),
      Paint()..color = Color.lerp(bodyColor, Colors.black, 0.50)!,
    );
    // Left side depth strip
    final sideL = Path()
      ..moveTo(cx - bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx - bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(
        sideL, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.38)!);
    // Right side depth strip
    final sideR = Path()
      ..moveTo(cx + bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx + bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(
        sideR, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.28)!);

    // ── 3. WHEELS ────────────────────────────────────────────────────────
    final double wW = 16.0 * widthRatio;
    final double wH = 32.0 * heightRatio;
    final wheels = [
      Offset(cx - bW * 0.94, cy - bH * 0.48),
      Offset(cx + bW * 0.94, cy - bH * 0.48),
      Offset(cx - bW * 0.90, cy + bH * 0.50),
      Offset(cx + bW * 0.90, cy + bH * 0.50),
    ];
    for (final wp in wheels) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW, height: wH),
          const Radius.circular(4),
        ),
        Paint()..color = wheelColor,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW * 0.45, height: wH * 0.45),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xFF555555),
      );
    }

    // ── 4. BODY (car silhouette path — rounded nose, wide hips, tapered rear)
    final bodyPath = _carBodyPath(cx, cy, bW, bH);
    // Base fill
    canvas.drawPath(bodyPath, Paint()..color = bodyColor);
    // Highlight gradient
    final bodyBounds = bodyPath.getBounds();
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.4),
          radius: 0.9,
          colors: [bodyHighlight, bodyColor],
        ).createShader(bodyBounds),
    );
    // Outline
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round,
    );

    // ── 5. HOOD LINES (subtle creases on the hood) ───────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + sign * bW * 0.28, cy - bH * 0.82),
        Offset(cx + sign * bW * 0.22, cy - bH * 0.38),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.08)!
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 6. WINDSHIELD (front — wider, trapezoid shape) ───────────────────
    final wsPath = Path()
      ..moveTo(cx - bW * 0.58, cy - bH * 0.38)
      ..lineTo(cx - bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.58, cy - bH * 0.38)
      ..close();
    canvas.drawPath(wsPath, Paint()..color = windowColor);
    // Sheen
    final sheenPath = Path()
      ..moveTo(cx - bW * 0.52, cy - bH * 0.35)
      ..lineTo(cx - bW * 0.42, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.30, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.38, cy - bH * 0.35)
      ..close();
    canvas.drawPath(
        sheenPath, Paint()..color = windowShine.withValues(alpha: 0.22));

    // ── 7. ROOF PANEL (between windows) ──────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.04),
          width: bW * 0.94,
          height: bH * 0.22,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = Color.lerp(bodyColor, bodyHighlight, 0.3)!,
    );

    // ── 8. REAR WINDOW (narrower trapezoid) ──────────────────────────────
    final rwPath = Path()
      ..moveTo(cx - bW * 0.48, cy + bH * 0.18)
      ..lineTo(cx - bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.48, cy + bH * 0.18)
      ..close();
    canvas.drawPath(rwPath, Paint()..color = windowColor);

    // ── 9. SIDE WINDOWS (small trapezoids left & right) ──────────────────
    for (final sign in [-1.0, 1.0]) {
      final swPath = Path()
        ..moveTo(cx + sign * bW * 0.54, cy - bH * 0.32)
        ..lineTo(cx + sign * bW * 0.82, cy - bH * 0.22)
        ..lineTo(cx + sign * bW * 0.82, cy + bH * 0.12)
        ..lineTo(cx + sign * bW * 0.54, cy + bH * 0.12)
        ..close();
      canvas.drawPath(
          swPath, Paint()..color = windowColor.withValues(alpha: 0.7));
    }

    // ── 10. HEADLIGHTS (wraparound at front corners) ─────────────────────
    for (final sign in [-1.0, 1.0]) {
      final hlPath = Path()
        ..moveTo(cx + sign * bW * 0.50, cy - bH * 0.88)
        ..quadraticBezierTo(
          cx + sign * bW * 0.82,
          cy - bH * 0.84,
          cx + sign * bW * 0.78,
          cy - bH * 0.72,
        )
        ..lineTo(cx + sign * bW * 0.58, cy - bH * 0.74)
        ..close();
      canvas.drawPath(hlPath, Paint()..color = headlightColor);
    }

    // ── 11. TAILLIGHTS (wide bars at rear) ───────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + sign * bW * 0.48, cy + bH * 0.88),
            width: bW * 0.48,
            height: 8,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = taillightColor,
      );
    }
    // Tail connector strip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.88),
          width: bW * 0.5,
          height: 4,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = taillightColor.withValues(alpha: 0.4),
    );

    // ── 12. SIDE MIRRORS ─────────────────────────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()..color = bodyColor,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // ── 13. ENCODE ───────────────────────────────────────────────────────
    final picture = recorder.endRecording();
    final image = await picture.toImage(cW.toInt(), cH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return Uint8List(0);
    return byteData.buffer.asUint8List();
  }

  /// Car body silhouette path — rounded nose, wide at cabin, tapered trunk.
  /// Front = top, rear = bottom.
  Path _carBodyPath(double cx, double cy, double bW, double bH) {
    return Path()
      // Start at front-center (nose)
      ..moveTo(cx, cy - bH * 0.95)
      // Front bumper curve (rounded nose)
      ..quadraticBezierTo(
          cx + bW * 0.55, cy - bH * 0.94, cx + bW * 0.72, cy - bH * 0.78)
      // Front fender flare
      ..quadraticBezierTo(
          cx + bW * 0.92, cy - bH * 0.62, cx + bW * 0.92, cy - bH * 0.40)
      // Straight body sides (widest point at doors)
      ..lineTo(cx + bW * 0.88, cy + bH * 0.30)
      // Rear fender taper
      ..quadraticBezierTo(
          cx + bW * 0.86, cy + bH * 0.68, cx + bW * 0.68, cy + bH * 0.85)
      // Rear bumper curve
      ..quadraticBezierTo(cx + bW * 0.40, cy + bH * 0.95, cx, cy + bH * 0.96)
      // Mirror left side
      ..quadraticBezierTo(
          cx - bW * 0.40, cy + bH * 0.95, cx - bW * 0.68, cy + bH * 0.85)
      ..quadraticBezierTo(
          cx - bW * 0.86, cy + bH * 0.68, cx - bW * 0.88, cy + bH * 0.30)
      ..lineTo(cx - bW * 0.92, cy - bH * 0.40)
      ..quadraticBezierTo(
          cx - bW * 0.92, cy - bH * 0.62, cx - bW * 0.72, cy - bH * 0.78)
      ..quadraticBezierTo(cx - bW * 0.55, cy - bH * 0.94, cx, cy - bH * 0.95)
      ..close();
  }

  Future<void> _verifyDriverApproval() async {
    try {
      final me = await ApiService.getMe();
      if (me == null) return;
      final bgStatus = me['background_check_status'] as String? ?? 'none';
      final verStatus = me['verification_status'] as String? ?? 'none';

      // Check profile photo — mandatory for drivers
      final photoUrl =
          (me['photo_url'] ?? me['profile_photo_url'] ?? '').toString();
      final hasPhoto = photoUrl.isNotEmpty &&
          photoUrl != 'null' &&
          photoUrl != 'None' &&
          photoUrl != 'none';

      // Check user-level approval
      final userApproved = (bgStatus == 'clear' || bgStatus == 'none') &&
          (verStatus == 'approved' || verStatus == 'none');

      // If driver is already approved, only check photo — don't re-verify
      // vehicle docs (those were checked during approval process).
      if (userApproved && hasPhoto) {
        _approvalGatePassed = true;
        return;
      }

      // Not yet approved — check vehicle docs for pending applicants
      bool vehicleDocsOk = true;
      String? vehicleBlockReason;
      try {
        final v = await ApiService.getVehicle();
        if (v != null) {
          final insOk = v['insurance_valid'] == true;
          final regOk = v['registration_valid'] == true;
          if (!insOk || !regOk) {
            vehicleDocsOk = false;
            final missing = <String>[];
            if (!insOk) missing.add('Insurance');
            if (!regOk) missing.add('Registration');
            vehicleBlockReason = 'Missing: ${missing.join(', ')}';
          }
          // Check expiry dates
          final now = DateTime.now();
          for (final key in ['insurance_expiry', 'registration_expiry']) {
            final expiryStr = (v[key] ?? '') as String;
            if (expiryStr.isNotEmpty) {
              final dt = DateTime.tryParse(expiryStr);
              if (dt != null && dt.isBefore(now)) {
                vehicleDocsOk = false;
                vehicleBlockReason =
                    'One or more documents have expired. Please upload updated documents.';
                break;
              }
            }
          }
        }
      } catch (_) {}

      if (userApproved && vehicleDocsOk && hasPhoto) {
        _approvalGatePassed = true;
        return;
      }

      _approvalGatePassed = false;
      if (!mounted) return;
      String title;
      String message;

      if (!hasPhoto) {
        title = 'Profile Photo Required';
        message =
            'You must add a profile photo before going online. Riders need to recognize you.\n\nGo to Profile > add your photo.';
      } else if (!userApproved) {
        if (bgStatus == 'pending' || bgStatus == 'processing') {
          title = 'Background Check In Progress';
          message =
              'Your background check is still being processed. You\'ll be notified when it\'s complete.';
        } else if (bgStatus == 'consider' || bgStatus == 'suspended') {
          title = 'Background Check Issue';
          message =
              'There is an issue with your background check. Please contact support.';
        } else {
          title = 'Verification Required';
          message =
              'Please complete your documents and background check before going online.';
        }
      } else {
        title = 'Vehicle Documents Required';
        message =
            'You need to upload your vehicle documents before going online.\n\n${vehicleBlockReason ?? ''}\n\nGo to Vehicle > upload the missing documents.';
      }

      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(message,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(S.of(context).ok,
                  style: const TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('_verifyDriverApproval error: $e');
      _approvalGatePassed = true;
    }
  }

  /// Raise the "you are online" indicators: the iOS Live Activity and the
  /// persistent notification Android shows while the app is away.
  ///
  /// Deliberately NOT gated on the go-online network call. Both of these
  /// used to live in that call's `.then`, which meant one HTTP round trip
  /// decided whether the driver saw anything at all on either platform —
  /// and five separate paths skipped it silently: no driver id yet, the
  /// approval gate not passed, no GPS fix yet, a resumed shift (which never
  /// called it), and a failed request whose retry only fires while the phase
  /// is still `searching`.
  ///
  /// This screen only exists while the driver is online, so being mounted is
  /// the condition. Idempotent, so boot, the backend callback and the clock
  /// can all call it.
  void _showOnlinePresence() {
    if (!mounted || _presenceShown) return;
    _presenceShown = true;
    debugPrint('[DriverOnline] raising online presence (live activity)');
    // iOS only — a silent no-op on Android.
    LiveActivityService.startOnline();
    _islandState = 'online';
    // The persistent "You're Online" tray notification was retired — the
    // background-service notification is the one that anchors Android, and
    // two silent entries said the same thing.
  }

  void _goOnlineBackend() {
    // _isGoingOnline is already set to true by _verifyAndGoOnline() before
    // calling this method. The guard below would incorrectly skip if it were
    // still true — remove it since the caller already handles deduplication.
    if (_driverId == null) {
      debugPrint('⚠️ _goOnlineBackend: _driverId is null, skipping');
      _setState(() => _isGoingOnline = false);
      return;
    }
    debugPrint(
      '🟢 Going online: lat=${_pos?.latitude} lng=${_pos?.longitude}',
    );
    if (!_approvalGatePassed) {
      debugPrint('_goOnlineBackend: approval gate not passed, skipping');
      _setState(() => _isGoingOnline = false);
      return;
    }
    if (_driverId == null || _pos == null) {
      debugPrint(
          '⚠️ _goOnlineBackend: ${_driverId == null ? "driverId" : "GPS"} not ready yet, retrying in 3s');
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _phase == _Phase.searching) _goOnlineBackend();
      });
      return;
    }
    // _isGoingOnline is already true from _verifyAndGoOnline; keep it true
    // Save last known location for startup pre-caching
    LocalCache.set('last_driver_lat', _pos!.latitude);
    LocalCache.set('last_driver_lng', _pos!.longitude);
    ApiService.updateDriverLocation(
      driverId: _driverId!,
      lat: _pos!.latitude,
      lng: _pos!.longitude,
      isOnline: true,
    ).then((_) {
      _isGoingOnline = false;
      debugPrint('[DriverOnline] backend registered this driver online');
      AnalyticsService.instance.logDriverOnline();
      // Idempotent — this is the happy path, but _showOnlinePresence is also
      // driven from boot and from the clock so the indicators no longer
      // depend on this callback being reached.
      _showOnlinePresence();
      // Subscribe to scheduled rides topic — receives FCM when new
      // scheduled trips enter the marketplace.
      FirebaseMessaging.instance
          .subscribeToTopic('drivers_available')
          .catchError(
            (e) =>
                debugPrint('FCM subscribeToTopic drivers_available failed: $e'),
          );
    }).catchError((e) {
      _isGoingOnline = false;
      debugPrint('âŒ Failed to go online: $e');
      // Retry after 5s so driver doesn't stay silently offline
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted && _phase == _Phase.searching) {
          debugPrint('[DriverOnline] Retrying _goOnlineBackend after failure');
          _goOnlineBackend();
        }
      });
    });
  }

  void _goOfflineBackend() {
    if (_driverId == null || _pos == null) return;
    AnalyticsService.instance.logDriverOffline();
    // iOS: dismiss the Dynamic Island activity (no-op elsewhere)
    LiveActivityService.stop();
    // The activity is gone, so there is nothing on the island to reconcile
    // against; leaving the last state set would have the next sync push an
    // update to an activity that no longer exists.
    _islandState = null;
    _presenceShown = false;
    NotificationService.cancelDriverOnlineNotification();
    NotificationService.cancelOfferNotifications();
    // Unsubscribe from scheduled rides topic when going offline.
    FirebaseMessaging.instance
        .unsubscribeFromTopic('drivers_available')
        .catchError(
          (e) => debugPrint(
              'FCM unsubscribeFromTopic drivers_available failed: $e'),
        );
    ApiService.updateDriverLocation(
      driverId: _driverId!,
      lat: _pos!.latitude,
      lng: _pos!.longitude,
      isOnline: false,
    ).catchError((_) => <String, dynamic>{});
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BACKGROUND HEARTBEAT — keeps driver online when app is backgrounded
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startBackgroundHeartbeat() {
    _bgHeartbeatTimer?.cancel();
    // Send heartbeat every 30s to keep driver "online" in backend.
    // This prevents the backend from marking the driver offline due to
    // inactivity while the app is backgrounded.
    _bgHeartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_driverId == null || _pos == null) return;
      try {
        await ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: _pos!.latitude,
          lng: _pos!.longitude,
          isOnline: true,
        );
        debugPrint('[DriverOnline] Background heartbeat sent');
      } catch (e) {
        debugPrint('[DriverOnline] Background heartbeat failed: $e');
      }
    });
  }

  void _stopBackgroundHeartbeat() {
    _bgHeartbeatTimer?.cancel();
    _bgHeartbeatTimer = null;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DRIVER POSITION STREAM (smooth movement on map)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPosStream() {
    // Prevent duplicate GPS streams — cancel existing before creating new
    unawaited(_posStream?.stop());
    _posStream = null;

    // FIX: Ensure Socket.io is initialized so the driver can send GPS
    // via Socket.io (primary channel). Previously init() was only called
    // in main.dart or by the rider — if it failed or the socket got
    // disposed, the driver had no way to reconnect.
    if (!SocketService.isConnected && !SocketService.isConnecting) {
      unawaited(SocketService.init());
    }

    // Start GpsService for Firebase RTDB uploads + presence
    if (_driverId != null) {
      _gpsService.startTracking(_driverId.toString());
    }

    // Background-capable, or an online driver goes silent the moment their
    // screen locks — which is how the ghost agent ends up logging a working
    // driver "inactive 21 min" and forcing them offline mid-shift.
    final s = S.of(context);
    _posStream = ResilientPositionStream(
      label: 'DriverOnlineGps',
      settings: driverLocationSettings(
        // distanceFilter: 2 -> fixes every 2 meters.
        // SmoothMotion still glides smoothly. Balance accuracy/battery.
        distanceFilter: 2,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnline,
      ),
      // Re-announce presence the moment the stream is back: while it was
      // down the ghost agent has been counting this driver as inactive.
      onFirstFixAfterGap: () {
        if (_driverId != null) _gpsService.startTracking(_driverId.toString());
      },
      onPosition: (pos) {
        if (!mounted) return;
        final newLL = LatLng(pos.latitude, pos.longitude);
        // Where the arrow points is decided by _headingSource, not here.
        //
        // This used to read pos.heading directly and throw it away below
        // ~5 km/h, because the GPS course at a crawl is noise — a parked
        // car has no direction of travel, so the platform reports −1 or a
        // wandering value, and feeding that in swung the arrow to north
        // while the driver sat still.
        //
        // Discarding it was right; having nothing to put in its place was
        // the problem. The compass answers the question the GPS cannot:
        // a stationary car is still pointing somewhere. The service takes
        // this fix, works out whether the car is moving fast enough for
        // the course to be the better source, and publishes the winner on
        // the stream _startHeadingSource listens to.
        _headingSource.onFix(pos);
        _currentSpeedMph = (pos.speed * 2.23694).clamp(0.0, 200.0);
        // Snap to route polyline — prevents GPS drift off-road
        final snappedLL = _snapToRoute(newLL);
        _smoothMoveTo(snappedLL, _smoothedBearing, accuracyM: pos.accuracy);

        // Feed GpsService for RTDB upload (800ms throttled)
        _gpsService.updatePosition(newLL, pos.heading, pos.speed);

        _trimRouteBehindDriver(snappedLL);

        // Auto-reroute check: reads the smoothed position, with sustained-
        // off-route hysteresis and a fetch cooldown. No-op outside nav.
        _checkOffRouteHysteresis();

        // A driver who starts rolling while an offer is up watches the
        // preview keep up: the driver leg refetches from where they
        // actually are, the line shortens behind them, and the card's
        // min/miles drop — the same live behaviour the trip phases below
        // get from their own blocks.
        if (_previewingOffer != null) {
          unawaited(_maybeRefreshOfferRoutePreview(snappedLL));
        }

        // Phase-specific nav stats (camera handled by _onDriverAnimTick)
        if (_phase == _Phase.routeSummary) {
          final dist = _hav(newLL, _dropoffLL);
          final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
          _navDist = dist;
          _navEta = eta;
          final now = DateTime.now();
          if (now.difference(_lastNavSetState).inMilliseconds > 500) {
            _lastNavSetState = now;
            _setState(() {});
          }
        } else if (_phase == _Phase.enRouteToPickup) {
          _updateNavState(newLL);
          final dist = _hav(newLL, _pickupLL);
          final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
          final progress = _distToPickup > 0
              ? (1.0 - dist / _distToPickup).clamp(0.0, 1.0)
              : 0.0;
          _navDist = dist;
          _navEta = eta;
          _navProgress = progress;
          final now1 = DateTime.now();
          if (now1.difference(_lastNavSetState).inMilliseconds > 500) {
            _lastNavSetState = now1;
            _setState(() {});
          }
          if (dist < 0.05) {
            _onNearPickup();
          }
        } else if (_phase == _Phase.inTrip) {
          _updateNavState(newLL);
          final dist = _hav(newLL, _dropoffLL);
          final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
          final progress =
              _tripDist > 0 ? (1.0 - dist / _tripDist).clamp(0.0, 1.0) : 0.0;
          _navDist = dist;
          _navEta = eta;
          _navProgress = progress;
          final now2 = DateTime.now();
          if (now2.difference(_lastNavSetState).inMilliseconds > 500) {
            _lastNavSetState = now2;
            _setState(() {});
          }
          if (dist < 0.05) {
            _onNearDropoff();
          }
        }

        // Throttle backend location updates to max once per 5 seconds
        final now = DateTime.now();
        if (_driverId != null &&
            now.difference(_lastBackendLocSend).inSeconds >= 5) {
          _lastBackendLocSend = now;
          ApiService.updateDriverLocation(
            driverId: _driverId!,
            lat: pos.latitude,
            lng: pos.longitude,
          ).catchError((_) => <String, dynamic>{});
        }
        // Sync driver GPS to Firestore so rider tracking gets real position
        if (_tripId != null) {
          TripFirestoreService.syncDriverLocation(
            'sql_$_tripId',
            pos.latitude,
            pos.longitude,
            _smoothedBearing,
          );
        }
      },
    )..start();
  }

  /// Push one camera frame, latest-wins.
  ///
  /// This used to be a bare `_map?.setCamera(...)` fired on every one of the
  /// sixty ticks a second and never awaited. Each call is a message across
  /// the platform channel, and the channel does not deliver sixty a second
  /// while a map is rendering on the other side — so the un-awaited futures
  /// queued up. A queue is worse than a dropped frame in both ways that
  /// matter: the camera falls further behind the driver the longer they
  /// drive, and the backlog lands in bursts, which is the stutter.
  ///
  /// Dropping a frame costs nothing here. Every frame is recomputed from
  /// SmoothMotion, so the next write already carries a newer position than
  /// the one skipped — there is no information in the frames we discard.
  /// Same discipline the rider's chase camera uses (TrackingMapCamera).
  ///
  /// Almost true. The entry zoom ease (16 → 15.5 over 750 ms) is the one
  /// place where a dropped frame IS visible: while the map is busy mounting,
  /// every intermediate write was discarded and then the final one landed at
  /// once — the camera "zoomed out a little, suddenly". So writes are not
  /// dropped any more, they are coalesced: only the newest frame waits for
  /// the channel, and it goes out the moment the previous write settles.
  /// The burst queue stays impossible (one in flight, one pending, ever) and
  /// the ease arrives as a glide instead of a pop.
  void _writeCamera(mapbox.CameraOptions options) {
    final map = _map;
    if (map == null) return;
    _pendingCamWrite = options;
    if (_camWriteBusy) return; // the in-flight write flushes the newest
    _flushCameraWrite(map);
  }

  void _flushCameraWrite(mapbox.MapboxMap map) {
    final opts = _pendingCamWrite;
    if (opts == null) return;
    _pendingCamWrite = null;
    _camWriteBusy = true;
    try {
      // A write that never settles must not latch the gate: the timeout
      // frees it, and the pending flush still carries the freshest frame.
      map.setCamera(opts).timeout(const Duration(seconds: 2)).then((_) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      }).catchError((Object _) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      });
    } catch (_) {
      _camWriteBusy = false;
    }
  }

  /// Update turn-by-turn navigation state from GPS position.
  void _updateNavState(LatLng pos) {
    if (!_navService.isNavigating) return;
    final state = _navService.updatePosition(pos);
    if (state == null) return;

    _navState = state;

    // Update displayed instruction & distance from NavigationService
    if (state.currentInstruction.isNotEmpty) {
      _navInstruct = state.currentInstruction;
    }
    _navEta = state.etaMinutes;
    _navDist = state.distanceRemainingMiles;
    _navProgress = state.progress;

    // The instantaneous `state.isOffRoute` still drives the red banner via
    // _navState; the expensive auto-reroute lives in
    // _checkOffRouteHysteresis (sustained + cooldown), called from the GPS
    // handler directly so it does not depend on the nav service's state.
  }

  /// Off-route detection with hysteresis, fed by the SmoothMotion-smoothed
  /// position (never the raw fix).
  ///
  /// Beyond [_kOffRouteMeters] from the active polyline, sustained for
  /// [_kOffRouteSustainMs], fires a reroute; the state re-arms only below
  /// [_kBackOnRouteMeters] so GPS noise around the threshold cannot flap it,
  /// and a red-light stop (distance filter → no fixes → no sustained clock)
  /// never triggers it. [_kRerouteCooldownSec] between fetches keeps a long
  /// detour from hammering the directions APIs.
  void _checkOffRouteHysteresis() {
    if (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip) return;
    if (_routePts.length < 2 || _isRerouting) return;
    final probe = _pos;
    if (probe == null) return;
    // Measure against the untouched road geometry, NOT _routePts: the trim
    // rewrites _routePts[0] to the driver's own position on every fix, so
    // that line runs through them by construction and would report ~0 m
    // however far off the road they actually are.
    final against =
        _plannedRoutePts.length >= 2 ? _plannedRoutePts : _routePts;
    final offM = RouteSplice.distanceToPolylineM(against, probe);
    final now = DateTime.now();
    if (offM > _kOffRouteMeters) {
      _offRouteSince ??= now;
      final sustained =
          now.difference(_offRouteSince!).inMilliseconds >= _kOffRouteSustainMs;
      final cooledDown = _lastRerouteTime == null ||
          now.difference(_lastRerouteTime!).inSeconds >= _kRerouteCooldownSec;
      if (sustained && cooledDown && _rerouteCount < 5) {
        _triggerReroute(probe);
      }
    } else if (offM < _kBackOnRouteMeters) {
      _offRouteSince = null;
    }
  }

  /// Reroute from current position to the active destination.
  ///
  /// The redraw is a partial splice (see RouteSplice.splice): only the
  /// stretch between the deviation point and the rejoin point is replaced,
  /// cross-faded in over the old line — never a full delete-and-repaint.
  Future<void> _triggerReroute(LatLng from) async {
    if (_isRerouting) return;
    _isRerouting = true;
    _lastRerouteTime = DateTime.now();
    _rerouteCount++;
    debugPrint('Rerouting (#$_rerouteCount)');
    HapticService.mediumImpact();

    final legAtStart = _phase;
    final dest = _phase == _Phase.enRouteToPickup ? _pickupLL : _dropoffLL;
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    await _drawRoute(from, dest, routeId, _navyRoute, legAtStart: legAtStart);
    _isRerouting = false;
  }

  void _onNearPickup() {
    if (_nearPickupNotified || _phase != _Phase.enRouteToPickup) return;
    _nearPickupNotified = true;
    HapticService.heavyImpact();
    // Send final position to backend so rider sees driver at pickup
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pickupLL.latitude,
        lng: _pickupLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show ARRIVED button
    _setState(() {});
  }

  void _onNearDropoff() {
    if (_nearDropoffNotified || _phase != _Phase.inTrip) return;
    _nearDropoffNotified = true;
    HapticService.heavyImpact();
    // Send final position to backend so rider sees driver at dropoff
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _dropoffLL.latitude,
        lng: _dropoffLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show FINISH TRIP button in panel
    _setState(() {});
  }

  /// Turn the arrow from the compass, whether or not the car is moving.
  ///
  /// Feeds [_motion] the bearing on its own, separately from position, and
  /// makes sure the ticker is awake to animate it — a driver turning the
  /// phone in their hand produces headings and no fixes at all, and the
  /// ticker used to be started only by a fix arriving.
  /// The hide-earnings switch is on the Earnings screen and this one is
  /// already mounted underneath it, so the chip repaints from a listener
  /// rather than on the way back from a route.
  void _onEarningsPrivacyChanged() {
    _setState(() {});
  }

  void _startHeadingSource() {
    _headingSource.start();
    // Called from boot and again on every resume, so it has to be safe to
    // call twice — two subscriptions would apply the low-pass twice per
    // reading and turn the arrow at double speed.
    _headingSub?.cancel();
    _headingSub = _headingSource.stream.listen((deg) {
      if (!mounted) return;
      // Same low-pass the GPS course got, so the arrow's feel does not
      // change with the source. A magnetometer at rest wanders about a
      // degree; this absorbs it before SmoothMotion's own filter sees it.
      _smoothedBearing = _lerpAngle(_smoothedBearing, deg, 0.25);
      _motion.setBearing(_smoothedBearing);
      // Only wake the ticker while there is a map for it to draw on.
      //
      // _releaseMapSurface stops it precisely because the surface is going
      // away, and compass readings keep arriving afterwards — so without
      // this the sensor would restart the ticker a few milliseconds later
      // and _onSmoothTick would run camera writes and annotation updates
      // against a map that has just been handed to another screen.
      if (_mapMounted &&
          _motion.hasPosition &&
          !(_smoothTicker?.isTicking ?? false)) {
        _smoothTicker?.start();
      }
    });
  }

  void _smoothMoveTo(LatLng target, double heading, {double? accuracyM}) {
    // accuracyM sizes the standstill jitter hold — see SmoothMotion. Without
    // it the hold falls back to a flat 15 m, which is wider than a road, and
    // a parked driver gets drawn on the pavement and left there.
    _motion.setTarget(target.latitude, target.longitude,
        bearing: heading, accuracyM: accuracyM);
    // Seed _pos on the very first fix so the first render doesn't start
    // from (0, 0) — the ticker fills it in subsequent frames.
    if (_pos == null && _motion.hasPosition) {
      _pos = LatLng(_motion.lat!, _motion.lng!);
      _heading = _motion.bearing;
    }
    // Start the ticker lazily on the first real GPS position so it does not
    // burn CPU during the period before any movement data is available.
    //
    // 2026-04-27 freeze fix: Don't start the 60fps ticker until the page
    // transition (400ms fade+scale) has finished. The ticker hammers the
    // MethodChannel with annotation+camera updates at 60fps, which stacks
    // on top of the route transition animation and causes a 1-2s freeze on
    // mid-range Android devices. We defer by 500ms so the transition owns
    // the UI thread cleanly.
    //
    // The deferral applies to the FIRST start only. Later restarts happen
    // every time the driver comes back to this screen from a trip, and
    // delaying those by half a second is exactly the "dot doesn't follow me"
    // lag — the transition is long gone by then.
    //
    // Not while our map is gone. This screen stays mounted underneath the
    // trip screen and its GPS stream keeps running, so a fix arriving mid-
    // ride would restart the ticker against a surface we handed away — and
    // since the ticker no longer parks itself at the target, it would then
    // run at 60 fps for the length of the whole trip. Every write it makes
    // is guarded and does nothing; it is the running that costs.
    if (!_mapMounted) return;

    if (!(_smoothTicker?.isTicking ?? false)) {
      if (_smoothTickerStarted) {
        _smoothTicker?.start();
      } else {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _mapMounted && !(_smoothTicker?.isTicking ?? false)) {
            _smoothTickerStarted = true;
            _smoothTicker?.start();
          }
        });
      }
    }
  }

  /// Trim the route polyline behind the driver so only upcoming road is shown.
  /// Google Maps navigation style — route "disappears" behind the car.
  void _trimRouteBehindDriver(LatLng driverPos) {
    if (_routePts.length < 3) return;
    if (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip) return;

    // Find the closest point on the DISPLAY route (not the simulation copy)
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _routePts.length; i++) {
      final d = _hav(driverPos, _routePts[i]) * 1000; // meters
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }

    // Only trim if we've passed at least 1 point
    if (closestIdx > 0) {
      _routePts = _routePts.sublist(closestIdx);
      // Same cut on the untouched copy so the two stay index-aligned; it is
      // what _checkOffRouteHysteresis measures against, since the line below
      // puts the driver ON _routePts by construction.
      if (_plannedRoutePts.length > closestIdx) {
        _plannedRoutePts = _plannedRoutePts.sublist(closestIdx);
      }
    }
    // Always put driver at front for seamless line
    if (_routePts.isNotEmpty) {
      _routePts[0] = driverPos;
    }

    // Rebuild route annotation with trimmed route
    _setRouteAnnotation(List.from(_routePts), _navyRoute);
  }

  /// Continuous 60fps ticker — Google-Maps-style constant-velocity advance
  /// via [SmoothMotion]. Never resets, never stutters, keeps gliding at the
  /// measured speed between GPS fixes instead of decelerating into a stall.
  void _onSmoothTick(Duration elapsed) {
    if (!mounted || _pos == null) return;
    // Self-correcting stop. _releaseMapSurface already stops the ticker, and
    // both start paths now check the map first — this is the backstop for
    // any future one that forgets, because a ticker running against a map
    // that has been handed to another screen is invisible: every write it
    // makes is guarded, so it costs a frame's work sixty times a second and
    // shows nothing to say it is happening.
    if (!_mapMounted) {
      _smoothTicker?.stop();
      return;
    }
    if (!_motion.hasPosition) return;

    // Frame delta in seconds. Clamp huge gaps (background resume) so we
    // never teleport the marker across several seconds in one step.
    final dtMs = (elapsed - _lastTickElapsed).inMilliseconds.clamp(1, 50);
    _lastTickElapsed = elapsed;
    final dtSec = dtMs / 1000.0;

    _motion.tick(dtSec);
    _pos = LatLng(_motion.lat!, _motion.lng!);
    _heading = _motion.bearing;

    // Unified camera following (single source of truth for all phases)
    // Skip camera control when offer animation is running or route is previewing
    final isNav = _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip;
    final offerActive = _isCardAnimating || _previewingOffer != null;
    // _cameraFollowing is honoured in every phase now. Searching used to
    // ignore it, so a driver dragging the map while online was overruled
    // sixty times a second and the view snapped back under their finger.
    if (_phase == _Phase.searching && !offerActive && _cameraFollowing) {
      // Entry zoom ease: the map opens at zoom 16 (same as home) and
      // glides to the working 15.5 over ~750ms (easeOutCubic) so there
      // is no zoom "pop" when arriving from the home screen.
      double zoom = 15.5;
      if (!_zoomEaseDone) {
        _zoomEaseStartMs ??= elapsed.inMilliseconds;
        final t = ((elapsed.inMilliseconds - _zoomEaseStartMs!) / 750.0)
            .clamp(0.0, 1.0);
        final e = 1.0 - math.pow(1.0 - t, 3).toDouble();
        zoom = 16.0 - 0.5 * e;
        if (t >= 1.0) _zoomEaseDone = true;
      }
      _writeCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: zoom,
          bearing: 0,
          pitch: 0,
        ),
      );
    } else if (isNav && _cameraFollowing) {
      _cameraBearing = _heading;
      _writeCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 17.5,
          bearing: _heading,
          pitch: 55,
        ),
      );
    }

    // Repaint the Flutter marker with this frame. Cheap, and the only thing
    // that makes the overlay follow the motion instead of the 15 fps
    // setState below.
    _markerFrame.value++;

    // Annotation update every frame — write freshest geometry in-memory
    // (cheap), then flush to Mapbox. The annotation follows the dot exactly.
    _updateDriverAnnotation();

    // The ticker used to park itself here, on `_motion.isAtTarget`, and
    // restart on the next fix. That was a fair trade when the only thing it
    // animated was position: a stationary car has nothing to move, so a
    // sleeping ticker cost nothing.
    //
    // It is not true any more. The compass reports while the car is parked,
    // and turning the arrow is this ticker's job — so parking it froze the
    // arrow mid-rotation and left it pointing wherever the last frame caught
    // it. Nothing would wake it until the driver drove off, which is exactly
    // the case the compass was added for.
    //
    // isAtTarget now accounts for bearing as well, so the old condition
    // would no longer fire while the arrow is turning. Keeping the ticker
    // running outright is simpler and one less thing to be subtly wrong: it
    // stops on screen teardown and when the map surface is released, and
    // _onSmoothTick returns on its first line while there is no position.
    //
    // Throttle widget-tree rebuilds to ~15fps — map annotation updates every frame
    // but Flutter setState only fires 4x/sec so buttons stay responsive.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastUiRebuildMs >= 66) {
      _lastUiRebuildMs = nowMs;
      _setState(() {});
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  POLLING & CLOCK
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPolling() {
    // ── Debounce: ignore rapid-fire calls within 1s ──
    final now = DateTime.now();
    if (_driverOnlineLastStartPolling != null &&
        now.difference(_driverOnlineLastStartPolling!).inMilliseconds < 1000) {
      debugPrint('[DriverOnline] _startPolling debounced (called within 1s)');
      return;
    }
    _driverOnlineLastStartPolling = now;

    _pollT?.cancel();
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    _sseActive = false;

    _connectSse();

    // Polling fallback — only fires when SSE is DOWN to save battery.
    // Polls /dispatch/driver/pending every 5s; skipped entirely while SSE is active.
    final myGen = ++_driverOnlinePollingGen;
    _pollT = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      if (_sseActive) return; // SSE handles it — skip polling entirely
      if (myGen != _driverOnlinePollingGen) {
        debugPrint(
            '[DriverOnline] stale poll timer skipped (gen $myGen != $_driverOnlinePollingGen)');
        return;
      }
      debugPrint('[DriverOnline] SSE down — polling /dispatch/driver/pending');
      _poll();
    });
  }

  /// Poll for available scheduled rides every 90 seconds.
  void _startScheduledPoll() {
    _scheduledPollTimer?.cancel();
    _fetchScheduledCount();
    _scheduledPollTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (mounted) _fetchScheduledCount();
    });
  }

  Future<void> _fetchScheduledCount() async {
    try {
      // Where the driver actually is, not 0,0.
      //
      // Reserved rides are same-state only, and the server decides that from
      // this coordinate. Zeros used to switch both the distance and the
      // state rule off, so the badge counted every unclaimed reservation in
      // the country. The backend now falls back to the position the
      // heartbeat stores, so this is no longer the only guard — but sending
      // the live one keeps the count and the list the driver opens in
      // agreement.
      final here = _pos;
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: here?.latitude ?? 0,
        lng: here?.longitude ?? 0,
        radiusKm: 100,
      );
      if (!mounted) return;
      final newCount = trips.length;
      final oldCount = _scheduledAvailCount;
      _setState(() => _scheduledAvailCount = newCount);

      // Trigger bounce + toast when new scheduled rides appear
      if (newCount > oldCount && newCount > 0) {
        _scheduledBounceCtrl?.forward(from: 0);
        if (oldCount == 0 || newCount > _prevScheduledCount) {
          _setState(() => _showScheduledToast = true);
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) _setState(() => _showScheduledToast = false);
          });
        }
      }
      _prevScheduledCount = newCount;
    } catch (_) {}

    // The bell's badge is a different number from the bounce above: what
    // is waiting to be read, not what is up for grabs.
    try {
      final notifs = await ApiService.getNotifications();
      if (!mounted) return;
      final unread = notifs.where((n) => n['is_read'] != true).length;
      if (unread != _unreadCount) _setState(() => _unreadCount = unread);
    } catch (_) {}
  }

  /// Connect (or reconnect) the SSE offer stream.
  /// Automatically retries after 2 seconds on error or stream close.
  ///
  /// C4 fix: this used to be invoked from 3 different places (go-online,
  /// network change, onError/onDone) which could leave two streams active
  /// at once if timing was unlucky — both would deliver the same offer and
  /// the driver could double-accept. We now bump `_currentSseGeneration`
  /// on every reconnect and drop any event whose captured generation no
  /// longer matches the current one.
  void _connectSse() {
    // Web: fetch buffers the SSE body, so the stream never delivers events
    // nor errors — skip SSE entirely and let the 5s polling fallback in
    // _startPolling own offer delivery (it only runs while _sseActive is
    // false). Avoids a 500ms error→reconnect hot loop as well.
    if (kIsWeb) {
      _sseActive = false;
      return;
    }
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    final driverId = _driverId;
    if (driverId == null || !mounted) return;

    final int myGeneration = ++_currentSseGeneration;

    void scheduleReconnect(String reason) {
      // Only the CURRENT generation is allowed to schedule the next reconnect.
      // Events from stale generations are dropped silently.
      if (myGeneration != _currentSseGeneration) return;
      debugPrint(
          '[DriverOnline] SSE $reason — falling back to polling, reconnecting in 500ms');
      _sseActive = false;
      // Reconnect from any phase: mid-trip the stream is the only channel
      // a chained offer can arrive on, since the poll timer is parked.
      if (mounted) {
        _sseReconnectTimer =
            Timer(const Duration(milliseconds: 500), _connectSse);
      }
    }

    _offerSseSub = ApiService.streamDriverOffers(driverId).listen(
      (offers) {
        // Drop events from stale generations — another _connectSse has
        // already superseded this listener.
        if (myGeneration != _currentSseGeneration) {
          debugPrint(
            '[DriverOnline] SSE stale event dropped (gen $myGeneration < $_currentSseGeneration)',
          );
          return;
        }
        if (!_sseActive) {
          debugPrint(
              '[DriverOnline] SSE reconnected — stopping polling fallback');
        }
        _sseActive = true;
        debugPrint('SSE offers: ${offers.length}');
        if (!mounted) return;
        // Mid-trip the stream keeps delivering, but only chained offers
        // (flagged by the backend for a driver about to finish their
        // current trip) are let through — anything else belongs to a
        // phase the driver is not in.
        final visible = _phase == _Phase.searching
            ? offers
            : offers.where((o) => o['chained'] == true).toList();
        if (visible.isEmpty) return;
        _applyOffers(visible);
      },
      onError: (e) => scheduleReconnect('error: $e'),
      onDone: () => scheduleReconnect('stream ended'),
    );
  }

  /// Apply incoming offers to UI (shared by SSE + polling).
  void _applyOffers(List<Map<String, dynamic>> offers) {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // Filter out locally rejected AND already-accepted offers
    var filtered = offers.where((o) {
      final oid = toInt(o['offer_id']);
      if (oid == null) return true;
      if (_rejectedOfferIds.contains(oid)) return false;
      if (_acceptedOfferIds.contains(oid)) {
        debugPrint('[DriverOnline] already-accepted offer dropped: $oid');
        return false;
      }
      return true;
    }).toList();

    // Deduplicate by offer_id — SSE + polling can receive the same offer
    final seenIds = <int>{};
    filtered = filtered.where((o) {
      final oid = toInt(o['offer_id']);
      if (oid == null) return true; // keep offers without id
      if (seenIds.contains(oid)) {
        debugPrint('[DriverOnline] duplicate offer dropped: $oid');
        return false;
      }
      seenIds.add(oid);
      return true;
    }).toList();

    final hadOffers = _pendingOffers.isNotEmpty;

    // Detect whether the leading offer has changed — covers both the 0→N transition
    // and the case where a new offer replaces an existing one while cards are visible.
    final prevFirstId = _pendingOffers.isNotEmpty
        ? (_pendingOffers.first['offer_id'] ?? _pendingOffers.first['id'])
            ?.toString()
        : null;
    final nextFirstId = filtered.isNotEmpty
        ? (filtered.first['offer_id'] ?? filtered.first['id'])?.toString()
        : null;
    final isNewFirstOffer = nextFirstId != null && nextFirstId != prevFirstId;

    if (isNewFirstOffer) {
      // Escalating haptic burst — 3 heavy pulses spaced 160ms so the driver
      // can't miss the offer even with the phone flat on a table.
      HapticService.heavyImpact();
      Future.delayed(const Duration(milliseconds: 160), () {
        if (!mounted) return;
        HapticService.heavyImpact();
      });
      Future.delayed(const Duration(milliseconds: 320), () {
        if (!mounted) return;
        HapticService.heavyImpact();
      });
      final firstOffer = filtered.first;
      if (_appInForeground) {
        // Foreground: in-app sound + haptic is sufficient. The offer card
        // UI is already visible. Don't show a local OS notification — the
        // backend sends FCM push which the OS shows when backgrounded.
        NotificationService.playOfferSound();
      } else {
        // Background: show the local notification with fullscreen intent
        // so the driver sees it even with the phone locked.
        NotificationService.showOfferNotification(
          title: S.of(context).newRideOffer,
          body: '',
          offerId: (firstOffer['offer_id'] as num? ?? 0).toInt(),
          // 'trip_offer:<tripId>:<offerId>' — the shape
          // handleOfferNotificationPayload in main.dart splits back apart. A
          // tap on a LOCAL notification never reaches
          // FirebaseMessaging.onMessageOpenedApp, so the ids only survive if
          // they ride in this string. It used to be the bare word
          // 'trip_offer', and the driver landed on a screen that had to go
          // rediscover which offer they had just tapped.
          payload: 'trip_offer:'
              '${(firstOffer['trip_id'] as num? ?? 0).toInt()}:'
              '${(firstOffer['offer_id'] as num? ?? 0).toInt()}',
          appInForeground: false,
        );
      }
    }

    // ── Hold an offer through stream disagreements ─────────────────────
    //
    // SSE and the 5-second poll do not always answer with the same list.
    // One of them returning without an offer the other just sent took the
    // card off screen, and the next update put it back — the card flashing
    // up, vanishing, and then returning to run its countdown from the
    // start, because being removed from the tree disposes the ring. That
    // is why the card used to flicker and never time out.
    //
    // So an offer the driver can see is held until its countdown window
    // closes, however the streams disagree in between. The ring gets one
    // uninterrupted twenty-second run, and what removes the visible card
    // is the ring firing — a real reject — never a source losing a race.
    // The grace seconds exist so the ring always fires before the hold
    // lets go: the card outlives its own clock, not the other way round.
    String idOf(Map<String, dynamic> o) =>
        (o['offer_id'] ?? o['id'] ?? '').toString();

    final now = DateTime.now();
    final arrivedIds = filtered.map(idOf).toSet();
    for (final id in arrivedIds) {
      _offerFirstSeenAt.putIfAbsent(id, () => now);
    }
    const holdWindow = Duration(seconds: kOfferCountdownSeconds + 3);
    final reprieved = <Map<String, dynamic>>[];
    final expired = <Map<String, dynamic>>[];
    for (final shown in _pendingOffers) {
      final id = idOf(shown);
      if (arrivedIds.contains(id)) continue;
      // Rejected and accepted offers were already filtered out above, so
      // anything still here left for a reason we did not ask for.
      final firstSeen = _offerFirstSeenAt[id];
      if (firstSeen != null && now.difference(firstSeen) < holdWindow) {
        reprieved.add(shown);
      } else {
        expired.add(shown);
      }
    }
    if (reprieved.isNotEmpty) {
      filtered = [...filtered, ...reprieved];
      debugPrint('[Offers] held ${reprieved.length} through a '
          'disagreeing update');
    }
    // An offer that outlives the hold without its ring firing (its card
    // was not the visible page, so its clock never ran) is rejected here
    // the same way the ring would have — otherwise the next update that
    // mentions it again would resurrect the card with a fresh countdown.
    for (final o in expired) {
      final id = idOf(o);
      _offerFirstSeenAt.remove(id);
      final oid = toInt(o['offer_id']);
      if (oid != null) {
        _rejectedOfferIds.add(oid);
        if (_driverId != null) {
          ApiService.rejectRideOffer(
            offerId: oid,
            driverId: _driverId!,
          ).catchError((_) => <String, dynamic>{});
        }
      }
      if (_previewingOffer != null && idOf(_previewingOffer!) == id) {
        _previewingOffer = null;
        _offerRouteShown = false;
        _fullSegOne = [];
        _fullSegTwo = [];
        unawaited(_clearAllAnnotations().catchError((_) {}));
      }
    }

    String idsOf(List<Map<String, dynamic>> l) => l.map(idOf).join(',');
    final sameOffers = idsOf(filtered) == idsOf(_pendingOffers);

    if (!sameOffers) {
      _setState(() {
        _pendingOffers = filtered;
        if (filtered.isNotEmpty) {
          _currentOfferIndex = _currentOfferIndex.clamp(0, filtered.length - 1);
        }
        if (filtered.isNotEmpty && !hadOffers) _hideFindingBar = true;
        if (filtered.isEmpty && hadOffers) _hideFindingBar = false;
      });
    }
    // The lock-screen card, so a driver who is inside another app sees the
    // ride without going back to Cruise. After the list is assigned, not
    // inside the isNewFirstOffer block above: the card is drawn from the
    // head of _pendingOffers, which is only correct once _pendingOffers is
    // the list that just arrived.
    _syncOfferLiveActivity();
    // Fetches both legs of every offer off any frame callback. The
    // cinematic that draws the route runs from addPostFrameCallback, and
    // iOS renders no frames while the app is in another app — so it only
    // started once the driver came back, and they watched the route being
    // built instead of finding it built. This puts the road in _routeCache
    // while they are still outside; the cinematic then has its data and
    // only has to animate.
    _preFetchOfferRoutes(filtered);

    // The route draws itself as the card arrives: camera to fit, then the
    // line from the driver to the pickup, the gold dot, the line on to the
    // dropoff, the white square.
    //
    // This reverses an earlier decision to draw only on tap, which was
    // made because drawing on arrival "hijacked the map". It still does —
    // that is now the intent. It runs only on the first offer of a batch,
    // so a poll that returns the same offer again does not restart the
    // animation under the driver.
    if (filtered.isNotEmpty && _phase == _Phase.searching) {
      // The route-draw animation takes over the camera, so it stays a
      // searching-phase thing: a chained offer arriving mid-trip must not
      // hijack the active navigation view.
      //
      // _autoTriggerRoutePreview already existed for exactly this and was
      // left unreferenced when drawing moved to tap-only. It dedups on the
      // offer id, so the SSE push and the poll that follows it cannot both
      // start the animation.
      _autoTriggerRoutePreview(filtered.first);
    }
  }

  Future<void> _poll() async {
    if (_isPollingOffers) return;
    _isPollingOffers = true;
    if (_driverId == null) {
      debugPrint(
        'âš ï¸ _poll: _driverId is null, retrying getCurrentUserId...',
      );
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Recovered driverId during polling');
          _goOnlineBackend(); // Re-establish online status
          // _connectSse bails when _driverId is null, so the connection
          // attempted at boot never happened. Without this the driver runs
          // on the 5s poll for the life of the screen.
          _connectSse();
        }
      } catch (_) {}
      if (_driverId == null) {
        _isPollingOffers = false;
        return;
      }
    }
    // Heartbeat: keep last_active_at fresh so dispatch doesn't skip us.
    // Only send if GPS stream hasn't already sent recently (avoid duplicates).
    final now = DateTime.now();
    if (_driverId != null &&
        _pos != null &&
        now.difference(_lastBackendLocSend).inSeconds >= 2) {
      _lastBackendLocSend = now;
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pos!.latitude,
        lng: _pos!.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      if (!mounted) return;
      // Same rule as the SSE listener: outside the searching phase only
      // chained offers are surfaced.
      final visible = _phase == _Phase.searching
          ? offers
          : offers.where((o) => o['chained'] == true).toList();
      if (visible.isEmpty) return;
      _applyOffers(visible);
    } catch (e) {
      debugPrint('Poll error: $e');
    } finally {
      _isPollingOffers = false;
    }
  }

  void _startClock() {
    _clock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _setState(() => _online += const Duration(seconds: 5));
      // Backstops. Both are no-ops once the state already agrees, which is
      // the normal case — they exist so a path that skips the happy route
      // self-corrects within five seconds instead of leaving the driver with
      // a blank lock screen for the whole shift.
      _showOnlinePresence();
      _syncOfferLiveActivity();
    });
  }

  /// Chained accept while still driving another trip: lock the ride on
  /// the backend inside its countdown window, stash it, and let
  /// [_handoffChainedOffer] run the normal accept flow once the current
  /// trip leaves the screen. The screen stays with the trip being driven.
  Future<void> _acceptChainedOffer(Map<String, dynamic> r, int? offerId) async {
    if (offerId == null || _driverId == null) {
      _snack('Unable to accept — please try again.');
      return;
    }
    if (_chainedNextOffer != null) {
      _snack('You already have a next ride booked.');
      return;
    }
    if (_acceptedOfferIds.contains(offerId)) return;
    _acceptedOfferIds.add(offerId);

    HapticService.heavyImpact();
    _setState(() {
      _offerAcceptState = _OfferAcceptState.routing;
      _acceptingCardId = offerId.toString();
    });
    try {
      await ApiService.acceptRideOffer(offerId: offerId, driverId: _driverId!);
      _chainedNextOffer = r;
      _dropPendingOffer(offerId);
      _snack('Next ride booked — it starts after this dropoff.');
    } catch (e) {
      debugPrint('[DriverOnline] chained accept failed: $e');
      _acceptedOfferIds.remove(offerId);
      _dropPendingOffer(offerId);
      _snack('That ride is no longer available.');
    } finally {
      if (mounted) {
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
      }
    }
  }

  void _dropPendingOffer(int offerId) {
    final oid = offerId.toString();
    _setState(() {
      _pendingOffers = _pendingOffers
          .where((o) => (o['offer_id'] ?? o['id'] ?? '').toString() != oid)
          .toList();
    });
    _syncOfferLiveActivity();
  }

  /// Hand a previously chained-accepted ride to the normal accept flow.
  /// Called when the current trip leaves the screen (completed or
  /// declined) — the phase is back to searching by then.
  void _handoffChainedOffer() {
    final next = _chainedNextOffer;
    if (next == null) return;
    _chainedNextOffer = null;
    unawaited(_acceptOffer(next, alreadyAcceptedOnBackend: true));
  }

  Future<void> _acceptOffer(Map<String, dynamic> r,
      {bool alreadyAcceptedOnBackend = false}) async {
    debugPrint('[DriverOnline] _acceptOffer called — map=$_map, phase=$_phase');
    debugPrint('[DriverOnline] offer data: ${r.keys.toList()}');
    // Prevent double-tap
    final oid = (r['offer_id'] ?? r['id'] ?? '').toString();
    if (_offerAcceptState != _OfferAcceptState.normal) {
      debugPrint(
          '[DriverOnline] _acceptOffer blocked — state=$_offerAcceptState');
      return;
    }

    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final offerId = toInt(r['offer_id']);
    final tripId = toInt(r['trip_id']) ?? toInt(r['id']);
    debugPrint('[DriverOnline] parsed offerId=$offerId, tripId=$tripId');

    // Guard: driverId must be resolved before accepting
    if (_driverId == null) {
      debugPrint('[DriverOnline] _driverId is null — attempting recovery...');
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('[DriverOnline] Recovered driverId');
        }
      } catch (e) {
        debugPrint('[DriverOnline] Failed to recover driverId: $e');
      }
      if (_driverId == null) {
        debugPrint(
            '[DriverOnline] _driverId still null after recovery — aborting accept');
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
        _snack('Unable to accept — please try again.');
        return;
      }
    }

    // Chained accept: an offer that arrived while this driver is still on
    // another trip (the backend only sends those when the current trip is
    // about to end). The current trip keeps the screen — the new ride is
    // locked on the backend now and handed off when this trip wraps up.
    if (_phase != _Phase.searching) {
      await _acceptChainedOffer(r, offerId);
      return;
    }

    // C5 fix: idempotent guard keyed on offerId. If the same offer is
    // delivered twice by the SSE layer (or re-emitted from a stale stream
    // that slipped past the generation check in _connectSse), the second
    // call here is dropped silently instead of firing a second backend
    // accept request.
    if (offerId != null && !alreadyAcceptedOnBackend) {
      if (_acceptedOfferIds.contains(offerId)) {
        debugPrint(
            '[DriverOnline] duplicate accept dropped for offer=$offerId');
        return;
      }
      _acceptedOfferIds.add(offerId);
    }

    HapticService.heavyImpact();

    // Block further taps — show loading state on the button
    _setState(() {
      _offerAcceptState = _OfferAcceptState.routing;
      _acceptingCardId = oid;
    });

    // True once DriverTripAcceptScreen owns the trip. Guards the outer
    // catch below from handing back a trip that is being driven for real.
    bool handedOff = false;

    try {
      debugPrint('[DriverOnline] ▶ STEP 1: creating acceptFuture');
      final acceptFuture = (() async {
        // A chained handoff was already accepted on the backend when the
        // driver tapped the card mid-trip — do not accept it twice.
        if (alreadyAcceptedOnBackend) return true;
        if (offerId != null && _driverId != null) {
          debugPrint(
              '[DriverOnline] ▶ STEP 1a: calling acceptRideOffer(offerId=$offerId)');
          await ApiService.acceptRideOffer(
            offerId: offerId,
            driverId: _driverId!,
          );
          debugPrint('[DriverOnline] ▶ STEP 1b: acceptRideOffer SUCCESS');
          return true;
        }
        if (tripId != null && _driverId != null) {
          debugPrint(
              '[DriverOnline] ▶ STEP 1a: calling acceptTrip(tripId=$tripId)');
          await ApiService.acceptTrip(tripId: tripId, driverId: _driverId!);
          debugPrint('[DriverOnline] ▶ STEP 1b: acceptTrip SUCCESS');
          return true;
        }
        debugPrint(
            '[DriverOnline] ▶ STEP 1a: NO offerId or tripId — returning false');
        return false;
      })();

      debugPrint('[DriverOnline] ▶ STEP 2: rejecting other offers');
      // Reject all other pending offers silently
      for (final other in _pendingOffers) {
        // Parsed, not cast: a TypeError in this loop aborts the accept the
        // driver just made, over a housekeeping call to reject someone
        // else's leftover card.
        final otherId = int.tryParse('${other['offer_id']}');
        if (otherId != null && otherId != offerId && _driverId != null) {
          ApiService.rejectRideOffer(
            offerId: otherId,
            driverId: _driverId!,
          ).catchError((_) => <String, dynamic>{});
        }
      }

      debugPrint('[DriverOnline] ▶ STEP 3: populating trip data');
      // Populate active trip data from the accepted offer.
      //
      // Every field is coerced, never cast. A hard `as String` on a payload
      // field throws a TypeError the moment the backend sends a number (or
      // anything else) where a string was expected, and the only thing the
      // driver sees is "Error accepting offer" — with the trip already
      // assigned to them server-side. A wrong-looking address is survivable;
      // losing the accept is not.
      String str(dynamic v, String fallback) {
        if (v == null) return fallback;
        final s = v.toString().trim();
        return s.isEmpty ? fallback : s;
      }

      // Numbers get the same treatment as strings, which they did not before.
      // The comment above promised "every field is coerced, never cast" while
      // every numeric field right below it was still `as num?` — and that
      // cast throws a TypeError the instant the backend sends "33.41" instead
      // of 33.41, landing us in the catch with the trip already assigned
      // server-side. That is one of the ways the driver got "Error accepting
      // offer" for an accept that had worked.
      //
      // Non-finite is rejected too, not just non-numeric: a NaN coordinate
      // propagates through the haversine into the distance the driver reads,
      // which is where "NaN mi" on the trip card comes from. A wrong-looking
      // 0 is survivable; NaN poisons every number computed after it.
      double dbl(dynamic v, [double fallback = 0.0]) {
        final n = v is num ? v : num.tryParse(v?.toString().trim() ?? '');
        if (n == null) return fallback;
        final d = n.toDouble();
        return d.isFinite ? d : fallback;
      }

      final name = str(r['rider_name'], 'Rider');
      _pickupLL = LatLng(dbl(r['pickup_lat']), dbl(r['pickup_lng']));
      _dropoffLL = LatLng(dbl(r['dropoff_lat']), dbl(r['dropoff_lng']));

      _currentOfferId = offerId;
      _tripId = tripId;
      // Start the top-level cancel watcher as soon as we know the trip id.
      // It lives on this screen, so it survives the handoff to
      // DriverTripAcceptScreen and every transition after it — the only
      // sources of truth for remote cancellation are Firestore and this
      // watcher.
      if (tripId != null) {
        // Firestore access can throw synchronously when the app has no
        // Firebase instance. Losing the cancel watcher is bad; losing the
        // accept because of it is worse.
        try {
          _startActiveTripCancelWatcher(tripId);
        } catch (e) {
          debugPrint('[DriverOnline] cancel watcher failed to arm: $e');
        }
      }
      _riderName = name;
      _riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';
      _riderPhotoUrl =
          _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
      _riderPhone = str(r['rider_phone'], '');
      _riderId = (r['rider_id'] ?? '').toString();
      // Already in the offer payload — _trip_dict() has always included
      // "notes"; nothing here ever read it, so the instructions the passenger
      // typed died at this line.
      _riderNotes = str(r['notes'], '');
      _pickupAddr = str(r['pickup_address'], 'Pickup');
      _dropoffAddr = str(r['dropoff_address'], 'Drop-off');
      _fare = dbl(r['fare']);
      _vehicleType = _mapRideType(str(r['vehicle_type'], 'Comfort'));
      // Guarded at the point of use as well as at the boundary: _hav can only
      // return NaN if it was fed one, but `.ceil()` on a NaN throws an
      // UnsupportedError, so a single bad coordinate anywhere upstream would
      // abort the accept two lines later instead of just looking wrong.
      double finite(double v) => v.isFinite ? v : 0.0;
      _distToPickup = _pos != null ? finite(_hav(_pos!, _pickupLL)) : 0.0;
      _etaToPickup = (_distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _tripDist = finite(_hav(_pickupLL, _dropoffLL));
      _tripEta = (_tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

      // ── Extract cached route BEFORE clearing cache ──
      final cachedRouteData = _routeCache[oid];
      final preRoutePoints = cachedRouteData?.segOne;

      // FIX: Cancelar el stream de GPS de DriverOnlineScreen antes de navegar
      // para evitar doble stream cuando DriverTripAcceptScreen cree el suyo.
      unawaited(_posStream?.stop());
      _posStream = null;

      _setState(() => _pendingOffers = []);
      _syncOfferLiveActivity();
      _routeCache.clear();
      _expandedOfferIds.clear();
      _offerFirstSeenAt.clear();
      _offerCardHeights.clear();
      _pollT?.cancel();
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
      _nearPickupNotified = false;
      _nearDropoffNotified = false;
      debugPrint('[DriverOnline] ▶ STEP 4: clearing annotations');
      try {
        await _clearAllAnnotations();
      } catch (e) {
        debugPrint(
            '[DriverOnline] _clearAllAnnotations failed during accept: $e');
      }
      if (_pos != null) {
        try {
          _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
        } catch (e) {
          debugPrint(
              '[DriverOnline] _animateToPosition failed during accept: $e');
        }
      }

      // ── Reset offer state and navigate to full-screen accepted screen ──
      _tappedCardIds.clear();
      _lastAutoTriggeredOfferId = null;
      if (mounted) {
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
      }

      debugPrint('[DriverOnline] ▶ STEP 5: writing to Firestore');
      // Write accepted status to Firestore immediately — bypasses the 2-second
      // backend→Firestore sync delay so the rider's listener fires instantly.
      if (tripId != null) {
        String? driverFirstName;
        String? driverLastName;
        String? driverPhone;
        try {
          final driverUser = await UserSession.getUser();
          driverFirstName = driverUser?['firstName']?.toString();
          driverLastName = driverUser?['lastName']?.toString();
          driverPhone = driverUser?['phone']?.toString();
        } catch (e) {
          debugPrint(
              '[DriverOnline] UserSession.getUser() failed during accept: $e');
        }
        final fullName =
            '${driverFirstName ?? ''} ${driverLastName ?? ''}'.trim();
        final fsDocId = 'sql_$tripId';
        // This write is an accelerator, not a requirement: the backend
        // mirrors the same status a couple of seconds later. `.catchError`
        // only covers the async failure — `FirebaseFirestore.instance`
        // itself throws synchronously when the app has no Firebase (e.g.
        // `[core/no-app]`), and that escaped all the way to the generic
        // "Error accepting offer" toast while the backend had already
        // assigned the trip. Never let it kill the accept.
        try {
          unawaited(
            FirebaseFirestore.instance.collection('trips').doc(fsDocId).set({
              'status': 'driver_en_route',
              'driver_id': _driverId ?? 0,
              'driverId': _driverId?.toString() ?? '',
              'driver_name': fullName.isNotEmpty ? fullName : 'Driver',
              'driverName': fullName.isNotEmpty ? fullName : 'Driver',
              'driver_phone': driverPhone ?? '',
              'driverPhone': driverPhone ?? '',
              'driver_photo_url': widget.photoUrl ?? _driverPhotoUrl ?? '',
              'driverPhotoUrl': widget.photoUrl ?? _driverPhotoUrl ?? '',
              'acceptedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true)).catchError((_) {}),
          );
        } catch (e) {
          debugPrint('[DriverOnline] optimistic Firestore write failed: $e');
        }
      }

      if (!mounted) {
        debugPrint(
            '[DriverOnline] _acceptOffer: widget unmounted before nav — aborting');
        return;
      }
      debugPrint(
          '[DriverOnline] ▶ STEP 6: showing accepted celebration — tripId=$tripId, offerId=$offerId');
      final acceptedTripId = tripId ?? offerId ?? 0;
      final riderPhotoUrl =
          _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
      final riderRating = dbl(r['rider_rating']);
      // Use the backend's rider_is_new flag as the source of truth — it now
      // reflects rider_rides_count == 0 (first request ever), not just
      // "has never been rated".
      final riderIsNew = r['rider_is_new'] == true;
      final riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';

      // ── SINGLE CANVAS ──
      // The celebration is an overlay on the map this screen already owns.
      // It used to be TripAcceptedScreen, a pushed route carrying its own
      // MapWidget, so every accept lit up a second native Mapbox surface —
      // two GL contexts and two tile caches — on top of this one. That is
      // the crash the driver hit right after accepting. Same reason the
      // rider flow was rebuilt around one shared canvas.
      _setState(() {
        _acceptedOverlay = _AcceptedOverlayData(
          riderName: name,
          riderInitials: riderInit,
          riderPhotoUrl: riderPhotoUrl.isNotEmpty ? riderPhotoUrl : null,
          riderRating: riderRating,
          riderIsNew: riderIsNew,
          riderId: int.tryParse(_riderId),
          pickupAddress: _pickupAddr,
          distToPickupKm: _distToPickup,
          etaMinutes: _etaToPickup,
        );
      });
      // Camera + route paint onto the existing canvas. Not awaited: the
      // celebration clock must not hang on a Directions API call.
      unawaited(_paintAcceptedRoute(preRoutePoints));
      final celebration = Future<void>.delayed(_acceptedOverlayDuration);

      debugPrint('[DriverOnline] ▶ STEP 7: awaiting acceptFuture');
      try {
        await acceptFuture;
        debugPrint(
            '[DriverOnline] ▶ STEP 7a: acceptFuture completed successfully');
      } catch (e) {
        // ⚠️ CRITICAL phantom-cancel fix:
        //
        // Previously this catch fired _cancel() unconditionally, which sent
        // a PATCH /trips/{id}/status?status=canceled to the server. The
        // problem: the acceptFuture failing doesn't mean the server failed
        // — the 8s HTTP timeout on _client can fire even when the backend
        // successfully processed the accept and marked the trip
        // driver_en_route; only the response got lost / was slow. The
        // driver kept driving to pickup while the rider saw a mysterious
        // "cancelled by operator" dialog because our own client had
        // force-cancelled the trip in the background.
        //
        // Fix: verify the trip's real state server-side before cancelling.
        // If the server says the trip has a driver assigned OR is in
        // driver_en_route/arrived/in_trip, the accept WAS successful —
        // just log the timeout and continue. Only cancel if the server
        // confirms the accept actually did not stick.
        if (!mounted) return;
        debugPrint(
            '[DriverOnline] acceptFuture failed: $e — verifying server state before cancelling');
        bool serverHasTrip = false;
        bool verifyFailed = false;
        final verifyTripId = tripId ?? offerId;
        if (verifyTripId != null) {
          try {
            final serverTrip = await ApiService.getTrip(verifyTripId)
                .timeout(const Duration(seconds: 6));
            final srvStatus =
                (serverTrip['status'] ?? '').toString().toLowerCase();
            final srvDriver = serverTrip['driver_id'];
            // Accept is "good" if the backend has us as driver OR the trip
            // has already progressed past 'requested'.
            const liveStatuses = {
              'accepted',
              'driver_en_route',
              'driver_arriving',
              'arrived',
              'driver_arrived',
              'in_trip',
              'in_progress',
            };
            if (liveStatuses.contains(srvStatus) ||
                (srvDriver != null &&
                    srvDriver.toString() == _driverId.toString())) {
              serverHasTrip = true;
              debugPrint(
                '[DriverOnline] accept verified on server (status=$srvStatus driver=$srvDriver) — keeping trip alive',
              );
            }
          } catch (verifyErr) {
            debugPrint('[DriverOnline] getTrip verify failed: $verifyErr');
            verifyFailed = true;
          }
        }
        if (serverHasTrip) {
          // The client lost the accept response but the server is
          // happily running the trip. Swallow the error, stay on the
          // trip screen, let the driver continue.
          // Fall through to the normal result handling below.
        } else if (verifyFailed) {
          // getTrip itself failed (timeout/network). We cannot confirm the
          // accept failed — the original timeout was likely just the response
          // being slow. Be optimistic: assume the accept succeeded and let
          // the driver continue to the trip screen. If the accept really
          // failed, the trip screen will handle that gracefully.
          debugPrint(
            '[DriverOnline] verify failed — assuming accept succeeded optimistically',
          );
          serverHasTrip = true;
          // Fall through to normal handling.
        } else {
          // Accept genuinely failed — offer is gone. Do NOT cancel the trip
          // (the driver never owned it anyway), but DO undo the optimistic
          // Firestore write from STEP 5: it already told the rider a driver
          // was en route. Left as-is, the rider watches a driver who was
          // never dispatched while the trip is locked to this app.
          _hideAcceptedOverlay();
          if (tripId != null) {
            // notify: false — the driver already gets the clearer
            // "trip no longer available" message just below.
            await _returnTripToDispatch(
              tripId,
              reason: 'accept_failed',
              notify: false,
            );
          }
          // mounted guard required: previous awaits (getTrip, release) mean
          // context may be defunct if the driver navigated away mid-verify.
          if (mounted) {
            _setState(() {
              _offerAcceptState = _OfferAcceptState.normal;
              _acceptingCardId = null;
            });
            _snack(S.of(context).tripNoLongerAvailable);
          }
          _resetToSearchingOnRemoteCancel();
          return;
        }
      }
      // ── STEP 8: let the celebration play out, then hand the trip over ──
      // The 30s navFuture timeout that used to live here was a bandage for
      // TripAcceptedScreen crashing on its own map. There is no second route
      // to time out anymore — the overlay is ours and the handoff below is
      // a plain push we own end to end.
      await celebration;
      if (!mounted) return;

      // Hand off with the celebration still up: it covers the canvas through
      // the route fade, and _pushTripScreen drops both it and our map once
      // the trip screen is actually on top.
      handedOff = true;
      final String? result = await _pushTripScreen(
        tripId: acceptedTripId,
        riderName: name,
        riderPhotoUrl: riderPhotoUrl,
        riderRating: riderRating,
        riderIsNew: riderIsNew,
        routePoints: preRoutePoints,
      );
      if (!mounted) return;
      _hideAcceptedOverlay();
      if (result == 'completed') {
        // Back on this screen for the earnings overlay — bring the map back.
        _remountMapSurface();
        // Show the earnings / completed overlay (mirrors _complete())
        _setState(() {
          _trips++;
          _prevEarnings = _earnings;
          _earnings += _fare;
          _prevLastTripEarnings = _lastTripEarnings;
          _lastTripEarnings = _fare;
          _phase = _Phase.completed;
          _stars = 5;
        });
        _syncSearchPulse();
        _cacheEarnings();
        _doneCtrl?.forward(from: 0);
      } else if (result == 'back_to_home') {
        // Driver pressed back to go home — trip is still active.
        // Navigate to DriverHomeScreen with returnFromTrip so the Resume
        // button appears.  Do NOT call _cancel() — the trip must survive.
        _goBackToHomeWithTrip();
      } else if (result == 'cancelled') {
        // Trip screen reports a remote cancellation (dispatch or auto-cancel).
        // The driver cannot cancel trips directly anymore — this branch is
        // only reached when the trip was ended from outside the driver app.
        // Just reset local state and return to searching with a gold toast.
        debugPrint(
            '[DriverOnline] trip screen popped with result=cancelled — remote cancel, resetting');
        _resetToSearchingOnRemoteCancel();
      } else {
        // result == null — DriverTripAcceptScreen left via pushAndRemoveUntil
        // (rating screen, home) rather than popping a result, so nothing was
        // handed back. It owns the trip lifecycle from `arrived` onward and
        // its own exit navigation; touching trip state from here would race
        // its transitions. Never cancel here — that was the v293 phantom
        // cancel that showed the rider "Ride Cancelled by operator" while
        // the driver was still driving.
        debugPrint(
          '[DriverOnline] trip screen returned null — it navigated away on its '
          'own. Leaving the trip alone.',
        );
        // If we somehow survived underneath, bring the canvas back.
        _remountMapSurface();
        // Clear local offer/trip refs so a later back_to_home pop doesn't
        // make the controller think a ghost trip is still in progress.
        _tripId = null;
        _currentOfferId = null;
      }
    } catch (e, stack) {
      debugPrint('[DriverOnline] ═══════════════════════════════════════');
      debugPrint('[DriverOnline] _acceptOffer unexpected error: $e');
      debugPrint('[DriverOnline] offerId=$offerId, tripId=$tripId');
      debugPrint('[DriverOnline] mounted=$mounted, phase=$_phase');
      debugPrint(stack.toString());
      debugPrint('[DriverOnline] ═══════════════════════════════════════');
      _hideAcceptedOverlay();
      _remountMapSurface();
      // Release the accept button whatever happens next — the toast is a
      // separate decision, made below.
      if (mounted) {
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
      }
      // We may already be the assigned driver — the backend commits the
      // accept before this app finishes setting up the trip. Blowing up
      // here without releasing leaves the trip in driver_en_route owned by
      // an app that cannot drive it: the rider watches a driver who never
      // arrives and dispatch can't reassign. Hand it back.
      // `handedOff` keeps this off trips that DriverTripAcceptScreen is
      // legitimately running.
      // ...unless the trip is already ours. A 409 "offer already accepted"
      // is the expected answer when the same trip reaches this driver
      // twice: they take the first card, the trip is theirs, and tapping
      // the leftover card lands here. Releasing then hands away a trip the
      // driver legitimately holds and is about to drive — the rider is
      // shown a driver, the driver is shown an error, and the trip goes
      // back to the queue underneath both of them. Ask who owns it before
      // giving it up.
      //
      // "Error accepting offer. Please try again." used to fire from here
      // unconditionally, including on the recovery path directly below —
      // which runs when the trip turns out to be OURS and opens it. So the
      // accept had succeeded, the app was already navigating to the trip,
      // and the driver was still told it failed and to try again. Tapping
      // again is the worst thing they could do at that moment.
      //
      // The toast now belongs to whoever concludes the accept really did
      // fail: the release path, or the branch where there is nothing to
      // check because we never got a trip id.
      if (!handedOff && tripId != null) {
        unawaited(() async {
          if (await _tripIsAlreadyMine(tripId)) {
            debugPrint('[DriverOnline] accept threw but trip $tripId is '
                'already assigned to us — opening it');
            // Open it, don't just say so. The accept worked; only the
            // setup after it failed. Telling the driver "this trip is
            // already yours" and leaving them on the offers list makes
            // them find their own way to a trip they are supposed to be
            // driving — which is what "close and reopen the app puts me
            // in the ride" was really reporting.
            if (!mounted) return;
            // Coerced, not cast — the payload is the same one whose hard
            // casts used to throw and land us in this very catch.
            String text(dynamic v, String fallback) {
              if (v == null) return fallback;
              final s = v.toString().trim();
              return s.isEmpty ? fallback : s;
            }

            await _pushTripScreen(
              tripId: tripId,
              riderName: text(r['rider_name'], 'Rider'),
              riderPhotoUrl: text(r['rider_photo_url'], ''),
              riderRating: double.tryParse('${r['rider_rating']}') ?? 0.0,
              riderIsNew: r['rider_is_new'] == true,
            );
            return;
          }
          // Genuinely lost: the trip went back to dispatch, so the driver
          // does need to know and the offer really is gone.
          await _returnTripToDispatch(tripId, reason: 'driver_app_error');
          _showAcceptFailed(e);
        }());
      } else if (!handedOff) {
        // No trip id at all — nothing was ever assigned, nothing to check.
        _showAcceptFailed(e);
      }
    }
  }

  /// Tell the driver the accept failed. Only called once it is established
  /// that they do NOT hold the trip — see the catch block above.
  void _showAcceptFailed(Object e) {
    if (!mounted) return;
    final errStr = e.toString().toLowerCase();
    final isNetworkError = errStr.contains('socket') ||
        errStr.contains('timeout') ||
        errStr.contains('unreachable') ||
        errStr.contains('connection') ||
        errStr.contains('network');
    _snack(isNetworkError
        ? 'Network error. Please check your connection and try again.'
        : 'Error accepting offer. Please try again.');
  }

  // ═══════════════════════════════════════════════════════════
  //  ACCEPTED CELEBRATION — single canvas
  // ═══════════════════════════════════════════════════════════

  /// Paint the accepted trip onto the map this screen already owns:
  /// the cinematic camera toward the pickup, the pickup/dropoff pins and
  /// the gold route. All of this used to be drawn on TripAcceptedScreen's
  /// own throwaway MapWidget.
  ///
  /// Fire-and-forget: the celebration clock must not wait on a Directions
  /// API call, and every step bails the moment the overlay is gone.
  ///
  /// Nothing in here may throw. It runs unawaited, so an escaping error
  /// becomes an uncaught zone exception — cosmetic map work would be
  /// crashing the app it was meant to stop crashing.
  Future<void> _paintAcceptedRoute(List<LatLng>? preRoutePoints) async {
    try {
      await _paintAcceptedRouteInner(preRoutePoints);
    } catch (e, s) {
      debugPrint('[DriverOnline] _paintAcceptedRoute failed: $e\n$s');
    }
  }

  Future<void> _paintAcceptedRouteInner(List<LatLng>? preRoutePoints) async {
    final driverPos = _pos ?? _pickupLL;

    // Frame driver → pickup with the same tilt the old screen opened on.
    final center = safePoint(
      (driverPos.longitude + _pickupLL.longitude) / 2,
      (driverPos.latitude + _pickupLL.latitude) / 2,
    );
    if (center != null) {
      try {
        _camera(
          mapbox.CameraOptions(
            center: center,
            zoom: 14.5,
            pitch: 20.0,
            bearing: _bearingBetween(driverPos, _pickupLL),
          ),
          animateMs: 900,
        );
      } catch (e) {
        debugPrint('[DriverOnline] accepted camera failed: $e');
      }
    }

    try {
      await _setPickupDropoffAnnotations();
    } catch (e) {
      debugPrint('[DriverOnline] accepted pins failed: $e');
    }
    if (!mounted || _acceptedOverlay == null) return;

    var pts = preRoutePoints;
    if (pts == null || pts.length < 2) {
      pts = await _fetchRoutePoints(driverPos, _pickupLL);
    }
    if (!mounted || _acceptedOverlay == null || pts.length < 2) return;
    try {
      // stillWanted overrides the helper's default "a preview is open"
      // liveness check — the preview was torn down before we got here.
      await _drawGoldGlossRoute(
        pts,
        stillWanted: () => _acceptedOverlay != null,
      );
    } catch (e) {
      debugPrint('[DriverOnline] accepted route draw failed: $e');
    }
  }

  /// Take the celebration off screen. Safe to call more than once.
  void _hideAcceptedOverlay() {
    if (_acceptedOverlay == null) return;
    _setState(() => _acceptedOverlay = null);
  }

  /// Hand the trip over to [DriverTripAcceptScreen].
  ///
  /// That screen mounts its own MapWidget, so ours is dropped as soon as
  /// the transition lands — only one native Mapbox surface may be alive at
  /// a time on iOS. Remounting is the caller's call: the paths that leave
  /// this screen for good shouldn't pay for a PlatformView they are about
  /// to throw away.
  Future<String?> _pushTripScreen({
    required int tripId,
    required String riderName,
    required String riderPhotoUrl,
    required double riderRating,
    required bool riderIsNew,
    List<LatLng>? routePoints,
  }) {
    final future = Navigator.of(context).push<String>(
      tripHandoffRoute(
        DriverTripAcceptScreen(
          tripId: tripId,
          riderName: riderName,
          riderPhotoUrl: riderPhotoUrl,
          riderRating: riderRating,
          riderIsNew: riderIsNew,
          riderId: int.tryParse(_riderId),
          pickupLatLng: _pickupLL,
          dropoffLatLng: _dropoffLL,
          pickupAddress: _pickupAddr,
          dropoffAddress: _dropoffAddr,
          fare: _fare,
          vehicleType: _vehicleType,
          driverPos: _pos ?? _pickupLL,
          distToPickupKm: _distToPickup,
          etaMinutes: _etaToPickup,
          riderPhone: _riderPhone,
          routePoints: routePoints,
          pickupInstructions: _riderNotes,
        ),
      ),
    );

    // Our surface is no longer dropped on a timer — the trip screen asks
    // MapSurfaceCoordinator for it, which calls our revoke and waits for it.
    // What is left here is purely cosmetic: hide the celebration overlay
    // once the transition has landed, so the swap happens behind it rather
    // than in the driver's face.
    //
    // Derived from kTripHandoffMs, not a copied number, so lengthening the
    // transition cannot leave the overlay disappearing mid-animation.
    Future.delayed(const Duration(milliseconds: kTripHandoffMs + 200), () {
      if (!mounted) return;
      // isCurrent means nothing is on top of us anymore — the trip screen
      // came and went inside the fade window (rule 12).
      if (ModalRoute.of(context)?.isCurrent == true) return;
      _hideAcceptedOverlay();
    });

    return future;
  }

  /// Claim the one live Mapbox surface for this screen.
  ///
  /// The revoke handed over is what lets whoever comes next — the trip
  /// screen on accept, a fresh online screen at the end of a ride — take it
  /// from us and know for certain that we are down before they mount.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _kMapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        _releaseMapSurface();
        await surfaceRemoved();
      },
    );
  }

  /// Tear down our native map so the screen on top of us can own the only
  /// live Mapbox surface. Every annotation handle belongs to the
  /// PlatformView being destroyed, so they all go with it; onMapCreated
  /// rebuilds them against the fresh map on remount (same path Android
  /// already takes when it recreates the SurfaceView after a background).
  void _releaseMapSurface() {
    if (!_mapMounted) return;
    debugPrint('[DriverOnline] releasing map surface');
    _dotWatchdog?.cancel();
    _smoothTicker?.stop();
    _routeDrawTicker?.stop();
    _pinPopTicker?.stop();
    // Bump the generation so any in-flight annotation work recognises its
    // handles as dead instead of poking a destroyed native object.
    _mapGeneration++;
    _polylineAnnotMgr = null;
    _pointAnnotMgr = null;
    _pinAnnotMgr = null;
    _carAnnot = null;
    _carAnnotGen = 0;
    _goldDotAnnot = null;
    _goldDotAnnotGen = 0;
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _prevDriverAnnot = null;
    _prevPickupAnnot = null;
    _prevDropoffAnnot = null;
    _routeAnnot = null;
    _previewPickupAnnot = null;
    _previewDropoffAnnot = null;
    _dotPopDone = false;
    _dotPopScale = 0.0;
    _map = null;
    _setState(() => _mapMounted = false);
  }

  /// Bring the canvas back after the screen above us is gone.
  ///
  /// Through the coordinator, not straight to the flag: on the way back
  /// from a trip the screen above may still be tearing its own map down,
  /// and remounting into that overlap is the same crash from the other
  /// direction.
  Future<void> _remountMapSurface() async {
    if (_mapMounted || !mounted) return;
    await _acquireMapSurface();
    if (!mounted || _mapMounted) return;
    debugPrint('[DriverOnline] remounting map surface');
    _setState(() => _mapMounted = true);
    // onMapCreated redraws the driver annotation; the watchdog re-asserts
    // it if the bitmap wasn't ready on the first pass.
    _startDotWatchdog();
  }

  /// Give an assigned trip back to dispatch.
  ///
  /// This app told the backend (and, optimistically, Firestore) that it was
  /// taking the trip, and then couldn't. Left alone the trip sits in
  /// `driver_en_route` with a driver who is never coming: the rider watches
  /// a phantom car and dispatch can't reassign because the trip already has
  /// an owner. The backend puts it back to `requested` and re-offers it to
  /// the next nearest driver.
  ///
  /// The optimistic Firestore write from the accept is only undone once the
  /// backend confirms the trip has no driver — either because it released
  /// it, or because it was never ours and nobody else took it. A trip past
  /// pickup, or one another driver now owns, is left alone: wiping the
  /// rider's driver info there would be the lie.
  /// Is this trip already assigned to this driver and still live?
  ///
  /// Answers the only question that matters before handing a trip back:
  /// did the accept actually fail, or did it succeed and something after
  /// it throw. Defaults to false — if we cannot tell, the safer outcome is
  /// releasing a trip we might hold (dispatch re-offers it) rather than
  /// keeping one we do not (the rider waits for nobody).
  Future<bool> _tripIsAlreadyMine(int tripId) async {
    try {
      final trip = await ApiService.getTrip(tripId);
      final assigned = (trip['driver_id'] as num?)?.toInt();
      final status = (trip['status'] ?? '').toString().toLowerCase().trim();
      const live = {
        'accepted',
        'driver_en_route',
        'driver_arriving',
        'arrived',
        'in_trip',
        'in_progress',
      };
      return assigned != null && assigned == _driverId && live.contains(status);
    } catch (e) {
      debugPrint('[DriverOnline] ownership check failed for $tripId: $e');
      return false;
    }
  }

  Future<void> _returnTripToDispatch(
    int tripId, {
    required String reason,
    bool notify = true,
  }) async {
    final driverId = _driverId;
    if (driverId == null) return;
    debugPrint('[DriverOnline] returning trip $tripId to dispatch ($reason)');
    final released = await ApiService.releaseTrip(
      tripId: tripId,
      driverId: driverId,
      reason: reason,
    );
    if (!released) {
      debugPrint('[DriverOnline] backend refused to release trip $tripId — '
          'leaving the rider view alone');
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc('sql_$tripId')
          .set({
        // Nulls, matching the backend's own release sync — the rider's
        // listener must see "no driver", not an empty-string driver.
        'status': 'requested',
        'driver_id': null,
        'driverId': null,
        'driver_name': null,
        'driverName': null,
        'driver_phone': null,
        'driverPhone': null,
        'driver_photo_url': null,
        'driverPhotoUrl': null,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[DriverOnline] Firestore revert for trip $tripId failed: $e');
    }
    if (notify && mounted) _snack(S.of(context).tripReturnedToDispatch);
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    try {
      HapticService.lightImpact();
      final offerId = toInt(r['offer_id']);
      if (offerId != null) _rejectedOfferIds.add(offerId);
      final rejectedId = (r['offer_id'] ?? r['id'] ?? '').toString();
      _offerFirstSeenAt.remove(rejectedId);
      _offerCardHeights.remove(rejectedId);

      // INSTANT dismiss — remove card + clear map in the same frame
      if (mounted) {
        _setState(() {
          _rejectingOfferId = null;
          _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
          if (_pendingOffers.isEmpty) {
            _hideFindingBar = false;
            // FIX: Reset PageController to index 0 when no offers remain.
            // Without this, PageView keeps a stale index and crashes on
            // rebuild when new offers arrive.
            if (_offerPageCtrl.hasClients) {
              _offerPageCtrl.jumpTo(0);
            }
          }
          _previewingOffer = null;
          _offerRouteShown = false;
          _fullSegOne = [];
          _fullSegTwo = [];
        });
      }
      // Guard: don't reset a disposed controller (can throw)
      if (_rejectSlideCtrl != null &&
          (_rejectSlideCtrl!.isAnimating || _rejectSlideCtrl!.isCompleted)) {
        try {
          _rejectSlideCtrl!.reset();
        } catch (_) {}
      }

      // CRASH FIX: Defer annotation clearing to next frame so the widget
      // tree has settled after setState. If the map was destroyed during
      // the rebuild, _clearAllAnnotations would crash trying to access
      // stale annotation managers.
      await Future.delayed(Duration.zero);
      if (!mounted) return;

      try {
        await _clearAllAnnotations();
      } catch (e) {
        debugPrint('[DriverOnline] _clearAllAnnotations failed on reject: $e');
      }

      if (_pos != null && mounted) {
        try {
          _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
        } catch (e) {
          debugPrint('[DriverOnline] _animateToPosition failed on reject: $e');
        }
      }

      // Fire-and-forget API rejection — UI already updated
      if (offerId != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: offerId,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
      if (offerId != null) _routeCache.remove(offerId.toString());
    } catch (e, stack) {
      debugPrint('[DriverOnline] _rejectOffer error: $e');
      debugPrint(stack.toString());
    }
  }

  // â”€â”€ _accept and _decline removed — now using _acceptOffer / _rejectOffer â”€â”€

  Future<void> _runAcceptCameraSequence() async {
    if (_map == null || !mounted) return;
    // Both ends have to be real before either reaches the native SDK.
    //
    // cameraForCoordinatesPadding serialises these points to JSON on the way
    // across, and NaN there throws in Objective-C — "Invalid number value
    // (NaN) in JSON write" — which closes the app rather than raising
    // something the catch below could hold. The try/catch around it only ever
    // covered Dart-side failures.
    if (!isValidLatLng(_pickupLL.latitude, _pickupLL.longitude) ||
        !isValidLatLng(_dropoffLL.latitude, _dropoffLL.longitude)) {
      debugPrint('[DriverOnline] accept camera skipped — endpoint not finite');
      return;
    }

    // Phase 1: Fit route bounds with padding for bottom card
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [
          mapbox.Point(
              coordinates:
                  mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
          mapbox.Point(
              coordinates:
                  mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
        ],
        mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: 280, right: 60),
        null,
        null,
      );
      if (!mounted) return;
      await _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 300));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // Phase 2: Tilt to 55
    _camera(mapbox.CameraOptions(pitch: 55), animateMs: 800);
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    // Phase 3: Rotate 20
    _camera(mapbox.CameraOptions(bearing: 20), animateMs: 600);
  }

  void _decline() {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // Reject all pending offers if any
    for (final offer in _pendingOffers) {
      final oid = toInt(offer['offer_id']);
      if (oid != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: oid,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }
    if (_currentOfferId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: _currentOfferId!,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    _stopActiveTripCancelWatcher();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _pendingOffers = [];
    });
    _syncOfferLiveActivity();
    _offerFirstSeenAt.clear();
    _offerCardHeights.clear();
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) {
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }
    _startPolling();
    // A ride accepted mid-trip while this one was being driven starts now.
    _handoffChainedOffer();
  }

  Future<void> _complete() async {
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    HapticService.heavyImpact();
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'completed',
        );
      } catch (_) {}
      // Immediate Firestore sync so rider listener detects completion in real time
      unawaited(TripFirestoreService.syncTripCompleted('sql_$_tripId'));
    }
    if (!mounted) return;
    _setState(() {
      _trips++;
      _prevEarnings = _earnings;
      _earnings += _fare;
      _prevLastTripEarnings = _lastTripEarnings;
      _lastTripEarnings = _fare;
      _phase = _Phase.completed;
      _stars = 5;
    });
    _syncSearchPulse();
    _cacheEarnings();
    _doneCtrl?.forward(from: 0);
  }

  void _afterComplete() {
    // Submit the driver's rating for this rider (fire-and-forget)
    if (_tripId != null) {
      ApiService.rateTrip(
        tripId: _tripId!,
        stars: _stars,
      ).catchError((_) => <String, dynamic>{});
      // Clean up RTDB chat node
      ChatService().deleteChat(_tripId.toString());
    }
    _doneCtrl?.reverse();
    _stopActiveTripCancelWatcher();
    // INSTANT reset — no delay
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _plannedRoutePts = [];
      _pendingOffers = [];
    });
    _syncOfferLiveActivity();
    _offerFirstSeenAt.clear();
    _offerCardHeights.clear();
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) {
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }
    _startPolling();
    // Refresh earnings from API so weekly total stays in sync
    _loadAllEarnings();
    // A ride accepted mid-trip while this one was being driven starts now.
    _handoffChainedOffer();
  }

  void _goOffline() {
    if (!mounted) return;
    // Block going offline while an offer is visible or a chained ride is
    // already booked for when the current trip ends.
    if (_pendingOffers.isNotEmpty ||
        _previewingOffer != null ||
        _chainedNextOffer != null) {
      HapticService.heavyImpact();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1F),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Active Offer',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: const Text(
            'You have an active ride offer. Accept or dismiss it before going offline.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('OK', style: TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
      return;
    }
    HapticService.mediumImpact();
    _goOfflineBackend();

    // Cancel all background tasks before navigating to prevent post-dispose crashes
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _clock?.cancel();
    _earningsRefreshTimer?.cancel();

    // Going offline for real — this is the one exit that should silence the
    // position uploads. Every other way out of this screen leaves the driver
    // online and must keep them reporting. See dispose().
    _leavingOffline = true;

    final result = {
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': false,
    };
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop<Map<String, dynamic>>(result);
      return;
    }
    // Some flows open DriverOnlineScreen as root (pushAndRemoveUntil).
    // In that case, popping causes a black screen. Always route to Home.
    nav.pushAndRemoveUntil(
      smoothFadeRoute(const DriverHomeScreen(returnFromTrip: false)),
      (_) => false,
    );
  }

  void _pauseAvailability() {
    HapticService.mediumImpact();
    _setState(() => _isPaused = true);

    // Stop polling for offers while paused
    _pollT?.cancel();

    // Show pause dialog with timer options
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('⏸️ Paused'),
          content: const Text(
            'You are paused and won\'t receive new trip requests.\n\nHow long do you want to pause?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeFromPause();
              },
              child: Text(S.of(context).resumeNow),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 15);
                _snack('⏸️ Paused for 15 minutes');
              },
              child: Text(S.of(context).fifteenMin),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 30);
                _snack('⏸️ Paused for 30 minutes');
              },
              child: Text(S.of(context).thirtyMin),
            ),
          ],
        );
      },
    );
  }

  void _resumeFromPause() {
    _setState(() => _isPaused = false);
    _pauseTimer?.cancel();
    _startPolling(); // Resume polling
    _snack('▶️ Back online - receiving trip requests');
  }

  void _scheduleResume({required int minutes}) {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(Duration(minutes: minutes), () {
      if (mounted && _isPaused) {
        _resumeFromPause();
      }
    });
  }

  /// Go back to home without going offline — driver stays connected.
  void _goBack() {
    HapticService.lightImpact();
    final result = <String, dynamic>{
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': true,
    };
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop<Map<String, dynamic>>(result);
      return;
    }
    // Some flows open DriverOnlineScreen as root (pushAndRemoveUntil after
    // rating). In that case, popping causes a black screen. Route to Home.
    nav.pushAndRemoveUntil(
      smoothFadeRoute(const DriverHomeScreen(returnFromTrip: true)),
      (_) => false,
    );
  }

  /// Driver pressed back from the active trip screen.
  /// Navigate to home while keeping the trip alive so the Resume button works.
  void _goBackToHomeWithTrip() {
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _clock?.cancel();
    _earningsRefreshTimer?.cancel();

    // Stop navigation but do NOT cancel the trip.
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();

    final nav = Navigator.of(context);
    if (nav.canPop()) {
      // Pop back to DriverHomeScreen with stillOnline = true so it shows
      // the Resume button and keeps polling for active trip updates.
      nav.pop<Map<String, dynamic>>(<String, dynamic>{
        'earnings': _earnings,
        'trips': _trips,
        'hours': _online.inMinutes / 60.0,
        'stillOnline': true,
      });
    } else {
      nav.pushAndRemoveUntil(
        smoothFadeRoute(const DriverHomeScreen(returnFromTrip: true)),
        (_) => false,
      );
    }
  }

  /// Driver can no longer directly cancel a trip (policy 2026-04-11).
  /// When a trip is dispatch-cancelled or auto-cancelled, the rider
  /// tracking listener will fire `_handleRemoteTripCancelled()` below
  /// which resets this controller back to searching and surfaces a
  /// friendly gold SnackBar. The driver cannot initiate a cancel — the
  /// only escape path during an active trip is "Contact Support", which
  /// creates an action request for dispatch.
  ///
  /// This method now ONLY resets the local controller state and returns
  /// the screen to the searching phase. It never PATCHes the backend.
  /// Show the centred "Viaje cancelado" notice: fade in over a semi-dark
  /// wash, hold ~5 s, fade back out fluidly. It never takes a pointer —
  /// the driver is already back to searching the moment it appears.
  void _showCancelledNotice() {
    if (!mounted) return;
    _cancelledNoticeTimer?.cancel();
    _cancelledNoticeCtrl ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _cancelledNoticeFade ??= CurvedAnimation(
      parent: _cancelledNoticeCtrl!,
      curve: Curves.easeInOut,
    );
    _setState(() => _cancelledNoticeVisible = true);
    _cancelledNoticeCtrl!.forward(from: 0);
    _cancelledNoticeTimer = Timer(const Duration(seconds: 5), () async {
      if (!mounted) return;
      await _cancelledNoticeCtrl!.reverse();
      if (!mounted) return;
      _setState(() => _cancelledNoticeVisible = false);
    });
  }

  void _resetToSearchingOnRemoteCancel() {
    // All callers are async-after-await, so the State may already be
    // disposed by the time we land here.
    if (!mounted) return;
    _stopActiveTripCancelWatcher();
    _hideAcceptedOverlay();
    // We may be coming back from DriverTripAcceptScreen, which owned the
    // only live map surface while it was up.
    _remountMapSurface();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();
    // FIX: Clear _acceptedOfferIds so the driver can accept future offers
    // with the same ID. Previously this was never cleared, causing the
    // idempotent guard in _acceptOffer to permanently block re-acceptance.
    _acceptedOfferIds.clear();
    _offerFirstSeenAt.clear();
    _offerCardHeights.clear();
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _plannedRoutePts = [];
      _pendingOffers = [];
      _offerAcceptState = _OfferAcceptState.normal;
      _acceptingCardId = null;
    });
    if (!mounted) return;
    _syncOfferLiveActivity();
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) {
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }
    _startPolling();
    // The notice replaces the old corner snackbar: a rider cancel is the
    // one event the driver must not miss in their periphery, so it lands
    // centred on a semi-dark wash for ~5 s and then fades out of the way.
    _showCancelledNotice();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV — Real GPS drives the navigation now.
  //  _simNav is kept as a no-op for backward compat.
  //  (_startActiveTripCancelWatcher / _handleExternalTripCancel defined below)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _simNav() {
    // No-op: real GPS position stream handles all nav updates
  }

  /// Start a Firestore snapshot listener on the active trip doc. Fires
  /// [_handleExternalTripCancel] as soon as the backend flips the trip to
  /// cancelled, regardless of which screen is currently on top of the
  /// navigator stack. This is the definitive detection mechanism for
  /// dispatch-initiated cancels: DriverTripAcceptScreen usually leaves via
  /// pushAndRemoveUntil rather than popping a result, so the route future
  /// _acceptOffer awaits comes back null and tells the controller nothing.
  void _startActiveTripCancelWatcher(int tripId) {
    _activeTripCancelWatcher?.cancel();
    _watchedCancelTripId = tripId;
    final docId = 'sql_$tripId';
    _activeTripCancelWatcher = FirebaseFirestore.instance
        .collection('trips')
        .doc(docId)
        .snapshots()
        .listen(
      (snap) {
        if (!mounted) return;
        if (_watchedCancelTripId != tripId) return; // stale listener
        final data = snap.data();
        if (data == null) return;
        final status = (data['status'] ?? '').toString().toLowerCase();
        if (status == 'cancelled' || status == 'canceled') {
          debugPrint(
              '[DriverOnline] external cancel detected for trip $tripId (status=$status) — resetting');
          _handleExternalTripCancel();
        }
      },
      onError: (e) {
        debugPrint('[DriverOnline] cancel watcher error for $tripId: $e');
        final isPermDenied =
            e is FirebaseException && e.code == 'permission-denied';
        if (isPermDenied || e.toString().contains('permission-denied')) {
          FirebaseAuthRecovery.ensureSignedIn().ignore();
        }
      },
    );
    debugPrint('[DriverOnline] cancel watcher armed on $docId');
  }

  /// Tear down the cancel watcher. Safe to call multiple times.
  void _stopActiveTripCancelWatcher() {
    _activeTripCancelWatcher?.cancel();
    _activeTripCancelWatcher = null;
    _watchedCancelTripId = null;
  }

  /// Shared handler for a remote cancel fired from the Firestore watcher.
  /// Pops every route pushed on top of DriverOnlineScreen
  /// (DriverTripAcceptScreen, DriverNavScreen, ...) and then resets the
  /// controller back to the searching phase — which also remounts our map,
  /// since the screen above us owned the only live surface.
  void _handleExternalTripCancel() {
    if (!mounted) return;
    _stopActiveTripCancelWatcher();
    // ModalRoute.of(context) gives the route of DriverOnlineScreen itself,
    // so popUntil stops there. If we are already the top route, popUntil
    // is a no-op and _resetToSearchingOnRemoteCancel does the rest.
    final myRoute = ModalRoute.of(context);
    if (myRoute != null) {
      try {
        Navigator.of(context).popUntil((r) => r == myRoute || r.isFirst);
      } catch (e) {
        debugPrint('[DriverOnline] popUntil on cancel failed: $e');
      }
    }
    _resetToSearchingOnRemoteCancel();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DIRECTIONS API
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  /// Fetch + draw a fresh route from [o] to [d] — the auto-reroute path.
  ///
  /// Two attempts with a short backoff. When every provider fails, the line
  /// on screen is KEPT as-is — the straight-line fallback was removed: a
  /// line cutting across blocks lies to the driver, and during a reroute
  /// the old road-following line is still the better answer.
  ///
  /// [legAtStart] is the phase the caller was on when it asked. The driver
  /// can tap Start Ride while the fetch is in flight, and splicing a
  /// driver→pickup route on top of the trip route would draw a wrong line —
  /// so a leg change discards the answer and the next off-route check asks
  /// again.
  Future<void> _drawRoute(LatLng o, LatLng d, String id, Color c,
      {_Phase? legAtStart}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 700));
        if (!mounted) return;
      }
      if (await _drawRouteAttempt(o, d, c, legAtStart)) return;
    }
    debugPrint('[DriverOnline] _drawRoute: providers failed — line kept');
  }

  /// One pass over the providers (Google variants → OSRM). True on success.
  Future<bool> _drawRouteAttempt(
      LatLng o, LatLng d, Color c, _Phase? legAtStart) async {
    debugPrint(
      'ðŸ—ºï¸ _drawRoute: ${o.latitude},${o.longitude} â†’ ${d.latitude},${d.longitude}',
    );

    // Try Google Directions API with multiple parameter variants
    final variants = <Map<String, String>>[
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
        'alternatives': 'true',
      },
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      },
    ];

    for (final query in variants) {
      try {
        final uri = Uri.https(
          'maps.googleapis.com',
          '/maps/api/directions/json',
          query,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        debugPrint('ðŸ—ºï¸ Directions API status: ${res.statusCode}');
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          debugPrint(
            'ðŸ—ºï¸ Directions API response status: ${data['status']}',
          );
          if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
            final route = data['routes'][0];
            final pts = _decodePoly(
              route['overview_polyline']['points'] as String,
            );
            final leg = route['legs'][0];
            final steps = leg['steps'] as List;
            String instr = mounted ? S.of(context).headToDestination : '';
            if (steps.isNotEmpty) {
              instr = (steps[0]['html_instructions']?.toString() ?? '')
                  .replaceAll(_htmlTagRe, '');
            }

            // Parse turn-by-turn NavRoute for live navigation
            final navRoute = NavigationService.fromDirectionsResponse(data);
            if (navRoute != null) {
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              debugPrint('Nav: ${navRoute.steps.length} steps parsed');
            }

            debugPrint('ðŸ—ºï¸ Google route OK: ${pts.length} points');
            if (legAtStart != null && _phase != legAtStart) {
              debugPrint('[DriverOnline] reroute discarded — leg changed');
              return true; // answered, just no longer applicable
            }
            // Partial splice: only the stretch between the deviation point
            // and the rejoin point changes geometry; the rest of the line
            // on screen is pixel-identical, so the swap redraws nothing
            // else. The already-driven head keeps being trimmed by
            // _trimRouteBehindDriver exactly as before.
            final spliced = RouteSplice.splice(
              oldRoute: _plannedRoutePts.length >= 2 ? _plannedRoutePts : _routePts,
              newRoute: pts,
              driverPos: o,
            );
            _setState(() {
              _routePts = spliced;
              _plannedRoutePts = List.of(spliced);
              final distVal = leg['distance']['value'];
              final durVal = leg['duration']['value'];
              _navDist = (distVal is num ? distVal.toDouble() : 0.0) / 1609.34;
              _navEta = ((durVal is num ? durVal.toDouble() : 0.0) / 60).ceil();
              _navInstruct = instr;
            });
            unawaited(_crossFadeRouteAnnotation(spliced, c));
            return true;
          }
        }
      } catch (e) {
        debugPrint('ðŸ—ºï¸ Google Directions attempt failed: $e');
      }
    }

    // Fallback: OSRM (free, no API key needed)
    debugPrint('ðŸ—ºï¸ Trying OSRM fallback...');
    try {
      final path =
          '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'steps': 'true',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final route = routes[0];
          final pts = _decodePoly(route['geometry'] as String);
          final distM = (route['distance'] as num?)?.toInt() ?? 0;
          final durS = (route['duration'] as num?)?.toInt() ?? 0;
          String instr = mounted ? S.of(context).headToDestination : '';
          final legs = route['legs'] as List?;
          if (legs != null && legs.isNotEmpty) {
            final rawSteps = legs[0]['steps'] as List? ?? [];
            if (rawSteps.isNotEmpty) {
              instr = rawSteps[0]['name']?.toString().isNotEmpty == true
                  ? 'Head on ${rawSteps[0]['name']}'
                  : instr;
            }
            // Build NavRoute from OSRM steps for turn-by-turn instructions
            final navSteps = <NavStep>[];
            for (int i = 0; i < rawSteps.length - 1; i++) {
              final step = rawSteps[i] as Map<String, dynamic>;
              final nextStep = rawSteps[i + 1] as Map<String, dynamic>;
              final mv = step['maneuver'] as Map<String, dynamic>? ?? {};
              final type = mv['type']?.toString() ?? 'straight';
              final mod = mv['modifier']?.toString() ?? '';
              String maneuver;
              if (type == 'turn') {
                if (mod == 'left') {
                  maneuver = 'turn-left';
                } else if (mod == 'right') {
                  maneuver = 'turn-right';
                } else if (mod == 'slight left') {
                  maneuver = 'turn-slight-left';
                } else if (mod == 'slight right') {
                  maneuver = 'turn-slight-right';
                } else if (mod == 'sharp left') {
                  maneuver = 'turn-sharp-left';
                } else if (mod == 'sharp right') {
                  maneuver = 'turn-sharp-right';
                } else {
                  maneuver = 'straight';
                }
              } else if (type == 'merge') {
                maneuver = 'merge';
              } else if (type == 'fork') {
                maneuver = mod.contains('left') ? 'fork-left' : 'fork-right';
              } else if (type == 'ramp') {
                maneuver = mod.contains('left') ? 'ramp-left' : 'ramp-right';
              } else {
                maneuver = 'straight';
              }
              final locArr = mv['location'] as List? ?? [0, 0];
              final stepLoc = LatLng(
                (locArr[1] as num).toDouble(),
                (locArr[0] as num).toDouble(),
              );
              final nMv = nextStep['maneuver'] as Map<String, dynamic>? ?? {};
              final nArr = nMv['location'] as List? ?? [0, 0];
              final nextLoc = LatLng(
                (nArr[1] as num).toDouble(),
                (nArr[0] as num).toDouble(),
              );
              final sName = step['name']?.toString() ?? '';
              final sDist = (step['distance'] as num?)?.toDouble() ?? 0;
              final sDur = (step['duration'] as num?)?.toDouble() ?? 0;
              String instrText;
              if (type == 'depart') {
                instrText = sName.isNotEmpty ? 'Head on $sName' : 'Depart';
              } else if (type == 'arrive') {
                instrText = 'Arrive at destination';
              } else if (type == 'turn') {
                instrText = 'Turn $mod${sName.isNotEmpty ? ' on $sName' : ''}';
              } else if (type == 'merge') {
                instrText = 'Merge${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'fork') {
                instrText =
                    'Keep $mod at fork${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'ramp') {
                instrText = 'Take ramp${sName.isNotEmpty ? ' to $sName' : ''}';
              } else {
                instrText =
                    sName.isNotEmpty ? 'Continue on $sName' : 'Continue';
              }
              List<LatLng> stepPoly = [stepLoc, nextLoc];
              final stepGeo = step['geometry'];
              if (stepGeo is String && stepGeo.isNotEmpty) {
                final dec = _decodePoly(stepGeo);
                if (dec.isNotEmpty) stepPoly = dec;
              }
              navSteps.add(NavStep(
                instruction: instrText,
                maneuver: maneuver,
                distanceMeters: sDist,
                durationSeconds: sDur.toInt(),
                streetName: sName,
                startLocation: stepLoc,
                endLocation: nextLoc,
                polyline: stepPoly,
              ));
            }
            if (navSteps.isNotEmpty) {
              final navRoute = NavRoute(
                overviewPolyline: pts,
                steps: navSteps,
                totalDistanceMeters: distM.toDouble(),
                totalDurationSeconds: durS,
                startAddress: '',
                endAddress: '',
              );
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              instr = navSteps.first.instruction;
              debugPrint('OSRM Nav: ${navSteps.length} steps parsed');
            }
          }
          debugPrint('ðŸ—ºï¸ OSRM route OK: ${pts.length} points');
          if (legAtStart != null && _phase != legAtStart) {
            debugPrint('[DriverOnline] reroute discarded — leg changed');
            return true;
          }
          final splicedOsrm = RouteSplice.splice(
            oldRoute: _plannedRoutePts.length >= 2 ? _plannedRoutePts : _routePts,
            newRoute: pts,
            driverPos: o,
          );
          _setState(() {
            _routePts = splicedOsrm;
            _plannedRoutePts = List.of(splicedOsrm);
            _navDist = distM / 1609.34;
            _navEta = (durS / 60).ceil().clamp(1, 999);
            _navInstruct = instr;
          });
          unawaited(_crossFadeRouteAnnotation(splicedOsrm, c));
          return true;
        }
      }
    } catch (e) {
      debugPrint('ðŸ—ºï¸ OSRM fallback failed: $e');
    }

    return false;
  }

  List<LatLng> _decodePoly(String enc) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < enc.length) {
      int s = 0, r = 0, b;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  /// Cross-fade the active route line onto [pts]: the new line fades in over
  /// [_kRerouteFadeMs] while the old one fades out and is then deleted.
  ///
  /// The old line is never removed before the new one exists, and because
  /// the splice (RouteSplice.splice) keeps the unaffected geometry
  /// pixel-identical, the only thing that visibly changes is the re-routed
  /// stretch. Runs on a plain timer — the Mapbox SDK applies each opacity
  /// write immediately, no fade support needed from it. The chase camera is
  /// not touched.
  Future<void> _crossFadeRouteAnnotation(List<LatLng> pts, Color c) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || pts.length < 2) return;
    final safeGeom = safeLineString(pts);
    if (safeGeom == null) return;
    final old = _routeAnnot;
    if (old == null) {
      await _setRouteAnnotation(pts, c);
      return;
    }
    mapbox.PolylineAnnotation? fresh;
    try {
      fresh = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: safeGeom,
        lineColor: c.toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
        lineOpacity: 0.0,
      ));
    } catch (_) {}
    if (fresh == null) return; // old line stays; _routePts already swapped
    if (!mounted) {
      try { await polyMgr.delete(fresh); } catch (_) {}
      return;
    }
    // The per-fix trim (_trimRouteBehindDriver) writes _routeAnnot — point
    // it at the new line now so the route keeps consuming behind the car
    // during the fade.
    _routeAnnot = fresh;
    _rerouteFadeTimer?.cancel();
    final sw = Stopwatch()..start();
    _rerouteFadeTimer =
        Timer.periodic(const Duration(milliseconds: 33), (timer) {
      final t = (sw.elapsedMilliseconds / _kRerouteFadeMs).clamp(0.0, 1.0);
      try {
        fresh!.lineOpacity = t;
        polyMgr.update(fresh!);
      } catch (_) {}
      try {
        old.lineOpacity = 1.0 - t;
        polyMgr.update(old);
      } catch (_) {}
      if (t >= 1.0) {
        timer.cancel();
        _rerouteFadeTimer = null;
        try {
          polyMgr.delete(old);
        } catch (_) {}
      }
    });
  }
}
