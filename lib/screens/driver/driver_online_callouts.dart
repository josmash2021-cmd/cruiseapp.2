part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  MAP CALLOUTS — Lyft-style bubbles (owner spec 2026-11-01)
//
//  • Trips: one on the pickup of every unclaimed trip ("$10 CRUISE" /
//    "9 min away"); tap → the marketplace claim card opens on that trip.
//  • Airports: the existing airport markers wear the same bubble
//    ("BHM" / "1-5 Drivers"), visual only.
//
//  Both are FLUTTER overlays glued per camera frame with FlatMapProjection
//  (the same zero-IPC pipeline as the zone labels) — not Mapbox
//  annotations: a PNG annotation cannot morph between expanded and
//  compact without re-uploading an image every frame (rule #25), and an
//  overlay holds no native handle that could outlive the surface (the
//  stale-handle hijack). Label, geometry and morph live, pure and tested,
//  in lib/map/map_callout.dart; the bubble in
//  lib/widgets/map/map_callout_bubble.dart.
// ══════════════════════════════════════════════════════════════

/// Everything the callouts keep between frames — one field on the State.
class _MapCalloutState {
  // Trip callouts, memoised on the feed list they were built from: the
  // camera rebuilds the overlay every frame, the list only when the feed
  // (or the language) changed, and an equal poll keeps the old list.
  List<Map<String, dynamic>>? tripSource;
  int tripSourceLength = -1;
  String? tripLang;
  List<TripCallout> trips = const [];

  /// The zoom hysteresis, shared by trips and airports so both flip on the
  /// same frame.
  bool expanded = true;

  // Airport driver counts: fetched once when a callout first needs one,
  // then again only in a new local hour (owner: the label changes at most
  // once per hour).
  final AirportDriverCounts airportCounts = AirportDriverCounts();
  final ValueNotifier<int> airportTick = ValueNotifier<int>(0);
  bool airportFetchInFlight = false;
  DateTime? airportRetryAt;
  Timer? airportHourTimer;

  void dispose() {
    airportHourTimer?.cancel();
    airportHourTimer = null;
    airportTick.dispose();
  }
}

/// Room around the viewport a callout's point may sit in and still be
/// drawn — the bubble rises ~70 px above its point and spreads ~100 px.
const double _kCalloutCullMargin = 160.0;

/// After a failed count fetch, wait this long before asking again (never a
/// tight retry loop against a backend that is down).
const Duration _kAirportCountRetry = Duration(minutes: 2);

extension _DriverOnlineCallouts on _DriverOnlineScreenState {
  /// Trip callouts only while ONLINE and plainly searching: no offer card,
  /// no offer preview, no accepted celebration, no trip / navigation phase,
  /// and only over a rendered map (never on the remount veil).
  bool get _tripCalloutsWanted =>
      !kIsWeb &&
      _driverOnline &&
      _phase == _Phase.searching &&
      _pendingOffers.isEmpty &&
      _previewingOffer == null &&
      _acceptedOverlay == null &&
      _mapMounted &&
      _mapStyleLoaded &&
      _firstRenderDone;

  /// Shared expanded/compact state for this camera zoom (hysteresis).
  bool _calloutsExpandedAt(double zoom) {
    final st = _mapCallouts;
    st.expanded = calloutExpandedForZoom(zoom, wasExpanded: st.expanded);
    return st.expanded;
  }

  /// The trip callouts for the current feed.
  List<TripCallout> _tripCalloutItems(S s) {
    final st = _mapCallouts;
    final src = _availableTrips;
    final lang = s.locale.languageCode;
    if (identical(st.tripSource, src) &&
        st.tripSourceLength == src.length &&
        st.tripLang == lang) {
      return st.trips;
    }
    final next = buildTripCallouts(src, minAway: s.tripCalloutMinAway);
    st.tripSource = src;
    st.tripSourceLength = src.length;
    st.tripLang = lang;
    if (!sameTripCallouts(st.trips, next)) st.trips = next;
    return st.trips;
  }

  /// The feed with the trip the driver tapped on the map first, so the
  /// claim card opens on THAT trip.
  List<Map<String, dynamic>> get _marketplaceTripsOrdered {
    final focus = _marketplaceFocusTripId;
    if (focus == null) return _availableTrips;
    final i = _availableTrips
        .indexWhere((t) => calloutNum(t['trip_id'])?.toInt() == focus);
    if (i <= 0) return _availableTrips;
    return [
      _availableTrips[i],
      ..._availableTrips.sublist(0, i),
      ..._availableTrips.sublist(i + 1),
    ];
  }

  /// The trip callouts layer. Tappable — no IgnorePointer; the Stack only
  /// takes a touch that lands on a bubble, the rest reaches the map.
  Widget _tripCalloutOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _markerFrame,
      builder: (context, _) {
        if (!_tripCalloutsWanted) return const SizedBox.shrink();
        final items = _tripCalloutItems(S.of(context));
        if (items.isEmpty) return const SizedBox.shrink();
        final cam = _onlineCamState;
        final size = _onlineMapSize;
        if (cam == null || size == null) return const SizedBox.shrink();
        final expanded = _calloutsExpandedAt(cam.zoom);
        final c = cam.center.coordinates;
        final camCenter = LatLng(c.lat.toDouble(), c.lng.toDouble());
        final shift = _camPadShift(cam);
        final children = <Widget>[];
        for (final t in items) {
          final off = FlatMapProjection.screenOffsetHeading(
            target: LatLng(t.lat, t.lng),
            cameraCenter: camCenter,
            zoom: cam.zoom,
            bearingDeg: cam.bearing,
            pitchDeg: cam.pitch,
            viewport: size,
          );
          if (off == null) continue;
          final p = off + shift;
          if (!FlatMapProjection.isOnScreen(p, size,
              margin: _kCalloutCullMargin)) {
            continue;
          }
          final id = t.tripId;
          children.add(Positioned(
            // Keyed by trip: a callout keeps its morph state while the
            // camera moves and other trips come and go.
            key: ValueKey('trip-callout-$id'),
            left: p.dx,
            top: p.dy,
            child: MapCalloutBubble(
              variant: CalloutVariant.trip,
              title: t.keepRun,
              titleFade: t.fadeRun,
              subtitle: t.subtitle,
              expanded: expanded,
              onTap: () => _onTripCalloutTap(id),
            ),
          ));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }

  /// Tap a trip callout → the trip opens as an offer card with its route
  /// drawn on the map, the same card and animation a ring gets (owner spec
  /// 2026-11-01). It used to set _marketplaceOpen, whose card only renders
  /// inside the offer stack — which never mounts with no offer: the tap did
  /// nothing. Accept claims it off the board (_claimBoardOffer); the X just
  /// closes it (_closeBoardOffer).
  void _onTripCalloutTap(int tripId) {
    if (!mounted || !_tripCalloutsWanted) return;
    Map<String, dynamic>? trip;
    for (final t in _availableTrips) {
      if (calloutNum(t['trip_id'])?.toInt() == tripId) {
        trip = t;
        break;
      }
    }
    final offer = trip == null ? null : boardOfferFrom(trip);
    if (offer == null) return;
    HapticService.lightImpact();
    _setState(() {
      _resvCardOpen = false;
      _pendingOffers = [offer];
      _currentOfferIndex = 0;
      _nextOfferRevealAt = null;
      _hideFindingBar = true;
    });
    _autoTriggerRoutePreview(offer);
  }

  // ── The driver's own reservation (owner 2026-11-05) ─────────────────────
  //
  // Lyft's "Reserved Lyft · 5:55 PM": before the reservation starts, a
  // callout sits on its pickup, online or offline. Tapped, it turns gold
  // and the "Scheduled Ride" card takes the sheet's place; More info opens
  // the reservation's own page, the X puts the sheet back.

  /// Over a plain, rendered map: no offer, no preview, no trip phase.
  bool get _reservationCalloutWanted =>
      !kIsWeb &&
      _phase == _Phase.searching &&
      _pendingOffers.isEmpty &&
      _previewingOffer == null &&
      _acceptedOverlay == null &&
      _mapMounted &&
      _mapStyleLoaded &&
      _firstRenderDone;

  /// The pickup of the driver's next reservation, or null.
  LatLng? get _reservationPickup {
    final r = _nextReservation;
    if (r == null) return null;
    final lat = calloutNum(r['pickup_lat']);
    final lng = calloutNum(r['pickup_lng']);
    if (lat == null || lng == null || !isValidLatLng(lat, lng)) return null;
    return LatLng(lat, lng);
  }

  /// The card is up: open, and its callout could be drawn.
  bool get _resvCardShown =>
      _resvCardOpen && _reservationCalloutWanted && _reservationPickup != null;

  /// The reservation's callout. Tappable: open the card, or close it again.
  Widget _reservationCalloutOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _markerFrame,
      builder: (context, _) {
        final r = _nextReservation;
        final at = r == null ? null : parseServerTime(r['scheduled_at']);
        final pickup = _reservationPickup;
        if (r == null ||
            at == null ||
            pickup == null ||
            !_reservationCalloutWanted) {
          return const SizedBox.shrink();
        }
        final cam = _onlineCamState;
        final size = _onlineMapSize;
        if (cam == null || size == null) return const SizedBox.shrink();
        final c = cam.center.coordinates;
        final off = FlatMapProjection.screenOffsetHeading(
          target: pickup,
          cameraCenter: LatLng(c.lat.toDouble(), c.lng.toDouble()),
          zoom: cam.zoom,
          bearingDeg: cam.bearing,
          pitchDeg: cam.pitch,
          viewport: size,
        );
        if (off == null) return const SizedBox.shrink();
        final p = off + _camPadShift(cam);
        if (!FlatMapProjection.isOnScreen(p, size,
            margin: _kCalloutCullMargin)) {
          return const SizedBox.shrink();
        }
        final s = S.of(context);
        return Stack(clipBehavior: Clip.none, children: [
          Positioned(
            key: ValueKey('res-callout-${r['id']}'),
            left: p.dx,
            top: p.dy,
            child: MapCalloutBubble(
              variant: CalloutVariant.reserved,
              title: s.reservedCalloutTitle,
              subtitle: reservationCalloutWhen(s, at.toLocal()),
              expanded: _calloutsExpandedAt(cam.zoom),
              selected: _resvCardOpen,
              onTap: _toggleReservationCard,
            ),
          ),
        ]);
      },
    );
  }

  void _toggleReservationCard() {
    if (!mounted || !_reservationCalloutWanted) return;
    if (_heat.open != null) _closeHeatZone(recenter: false);
    HapticService.selectionClick();
    _setState(() => _resvCardOpen = !_resvCardOpen);
  }

  void _closeReservationCard() {
    if (!mounted || !_resvCardOpen) return;
    HapticService.selectionClick();
    _setState(() => _resvCardOpen = false);
  }

  /// The card, slid in from the bottom in the sheet's place.
  Widget _reservationCardLayer() {
    final r = _nextReservation;
    if (r == null) return const SizedBox.shrink();
    final shown = _resvCardShown;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, 1),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: AnimatedOpacity(
            opacity: shown ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: ReservationMapCard(
              key: ValueKey('res-map-card-${r['id']}'),
              address: (r['pickup_address'] ?? '').toString(),
              bottomInset: MediaQuery.paddingOf(context).bottom,
              onClose: _closeReservationCard,
              onMoreInfo: () => _openReservationDetail(r),
            ),
          ),
        ),
      ),
    );
  }

  /// New trips on the board ease the follow camera OUT once, smoothly, so
  /// their callouts are on screen — the arrow stays centred, follow stays on
  /// (owner spec 2026-11-01). Once per trip id: a poll that returns the same
  /// trips again does nothing, and a recentre tap takes the zoom back. When
  /// the board empties the camera glides back to the working zoom.
  void _maybeRevealBoardTrips(List<Map<String, dynamic>> trips) {
    final ids = <int>{
      for (final t in trips)
        if (calloutNum(t['trip_id']) != null) calloutNum(t['trip_id'])!.toInt(),
    };
    final fresh = ids.difference(_revealedBoardTripIds);
    _revealedBoardTripIds.addAll(fresh);
    if (trips.isEmpty) {
      // A heat cloud may be what the camera eased out for — it stays.
      if (_searchFollowZoom < kSearchFollowZoom && _heat.zones.isEmpty) {
        _easeSearchFollowZoom(kSearchFollowZoom, ms: 900);
      }
      return;
    }
    final pos = _pos;
    final size = _onlineMapSize;
    if (fresh.isEmpty ||
        pos == null ||
        size == null ||
        !_cameraFollowing ||
        !_tripCalloutsWanted) {
      return;
    }
    var farthestM = 0.0;
    for (final t in trips) {
      final lat = calloutNum(t['pickup_lat']);
      final lng = calloutNum(t['pickup_lng']);
      if (lat == null || lng == null) continue;
      final m = _hav(pos, LatLng(lat, lng)) * 1000;
      if (m.isFinite && m > farthestM) farthestM = m;
    }
    final z = boardRevealZoom(
        latDeg: pos.latitude, farthestM: farthestM, viewport: size);
    if (z < _searchFollowZoom - 0.05) _easeSearchFollowZoom(z, ms: 1400);
  }

  /// Glide the searching follow zoom to [target] over [ms] — the same ease
  /// the entry zoom runs (easeOutCubic from wherever the camera is now).
  void _easeSearchFollowZoom(double target, {required int ms}) {
    _zoomEaseFrom = _onlineCamState?.zoom ?? _searchFollowZoom;
    _searchFollowZoom = target;
    _zoomEaseMs = ms;
    _zoomEaseStartMs = null;
    _zoomEaseDone = false;
  }

  /// The second line of an airport callout, or null until its count has
  /// arrived (no placeholder text).
  String? _airportDriversLine(S s, String code) {
    final n = _mapCallouts.airportCounts.countFor(code);
    return n == null ? null : s.airportDriversLabel(airportDriversBucket(n));
  }

  /// Called by the airport overlay with the airports it is drawing. Fetches
  /// only the codes with no value for this local hour — so once when a
  /// callout first needs one, then once per hour. Never during build: the
  /// request goes out on a microtask.
  void _maybeFetchAirportCounts(List<UsAirportGeo> onScreen) {
    final st = _mapCallouts;
    if (onScreen.isEmpty || st.airportFetchInFlight) return;
    final now = DateTime.now();
    final retryAt = st.airportRetryAt;
    if (retryAt != null && now.isBefore(retryAt)) return;
    final stale =
        st.airportCounts.staleCodes(onScreen.map((a) => a.code), now).toSet();
    if (stale.isEmpty) return;
    st.airportFetchInFlight = true;
    final ask = [
      for (final a in onScreen)
        if (stale.contains(a.code)) a,
    ];
    scheduleMicrotask(() => _fetchAirportCounts(ask));
  }

  Future<void> _fetchAirportCounts(List<UsAirportGeo> ask) async {
    final st = _mapCallouts;
    try {
      final counts = await ApiService.getAirportDriverCounts([
        for (final a in ask) {'code': a.code, 'lat': a.lat, 'lng': a.lng},
      ]);
      if (!mounted) return;
      final now = DateTime.now();
      if (counts == null) {
        st.airportRetryAt = now.add(_kAirportCountRetry);
        return;
      }
      st.airportRetryAt = null;
      st.airportCounts.store(ask.map((a) => a.code), counts, now);
      // Ask again only once the clock is in the next hour: a parked driver
      // has no camera frames to re-run the overlay, so wake it then.
      st.airportHourTimer?.cancel();
      st.airportHourTimer = Timer(
        calloutNextHour(now).difference(now) + const Duration(seconds: 2),
        () {
          if (mounted) st.airportTick.value++;
        },
      );
      st.airportTick.value++;
    } catch (e) {
      debugPrint('[DriverOnline] airport counts fetch failed: $e');
      if (mounted) {
        st.airportRetryAt = DateTime.now().add(_kAirportCountRetry);
      }
    } finally {
      st.airportFetchInFlight = false;
    }
  }
}
