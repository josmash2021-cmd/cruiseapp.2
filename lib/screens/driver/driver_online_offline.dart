part of 'driver_online_screen.dart';

/// ═══════════════════════════════════════════════════════════════════
///  OFFLINE CHROME — ported from driver_home_screen.dart (2026-09-26,
///  single-map merge, stage 2a)
///
///  The home screen is being deleted: with the merged map, ONLINE and
///  OFFLINE are modes of THIS screen, not two routes. Everything the
///  driver needs while offline lives here now:
///
///   * the location gate that used to guard the home GO button
///     ([_ensureLocationReady]);
///   * the vehicle-document gates ([_checkVehicleDocStatus] +
///     [_startDocApprovalListener]);
///   * the boot guards ([_checkAccountStatus], [_checkDriverAgreementConsent],
///     [_runDriverPermissionFlow], [_checkScheduledRideLockout]);
///   * active-trip detection + Resume ([_refreshActiveTripStatus],
///     [_checkBackendActiveTrip], [_resumeActiveTrip]);
///   * the morphing GO button ([_buildGoButton] / [_buildMorphingGoButton]
///     / [_GoRadarPainter]) whose tap is [_onGoTap] — the home `_goOnline`
///     minus the navigation: the flip is in place, on this same map;
///   * the offline panel content ([_buildOfflinePanelContent]) reading the
///     earnings fields this screen already owns (`_earnings`, `_tripsToday`,
///     `_hoursToday`, `_weeklyEarnings`, the chart series) instead of home's
///     parallel `_refreshStats` machinery, which was NOT ported;
///   * the menu button ([_buildOfflineMenuButton] + [_openDriverMenu]).
///
///  Adaptations vs the home originals:
///   * `_isNavigatingToOnline` → `_enteringOnline` (Stage 1 machinery owns
///     the in-flight latch; `_enterOnlineMode` does the haptic + chime, so
///     both are gone from the button);
///   * the map-surface handoff (`_suspendMap` / snapshot precache) is gone:
///     a pushed trip screen takes the one live surface through
///     MapSurfaceCoordinator (our `onRevoke` → `_releaseMapSurface`), and on
///     pop `_remountMapSurface()` claims it back — the same convention
///     `_pushTripScreen` already uses;
///   * `_isStillOnline` died with the two-screen split — the mode bit is
///     `_driverOnline`, and only `_enterOnlineMode`/`_exitOnlineMode` flip
///     it. The "shift never closed" label state survives as
///     `_driverWasOnlineAtBoot` (the pref, read at boot);
///   * the GO button's clocks are `_goPulseCtrl`, `_goBtnColorCtrl`,
///     `_goGlossCtrl`, `_goRadarCtrl`, `_goFabCtrl` — the bare names were
///     taken by the offer card's tap-down pulse;
///   * the home panel's VelocityAwarePanelMixin is NOT here: the merged
///     screen keeps its own `_panelFrac` machinery, so the morphing button
///     reads that instead of `panelExtent`.
/// ═══════════════════════════════════════════════════════════════════

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

/// Firestore trip ids arrive as `sql_<id>`; the SQL id is what every
/// downstream call needs.
final RegExp _sqlPrefixRe = RegExp(r'^sql_');

// ── GO button geometry, both ends of the morph ──
const double _kGoPillH = 56.0;
const double _kGoCircleD = 74.0;
const double _kGoSideInset = 20.0;

/// The offline chrome's gold (home's `_gold`). This library's top-level
/// `_gold` is a different shade (0xFFD4A843) that belongs to the online
/// chrome — the ported widgets below keep the colour they were drawn in.
const Color _offlineGold = Color(0xFFE8C547);

extension _DriverOnlineOfflineChrome on _DriverOnlineScreenState {
  // ═══════════════════════════════════════════════════
  //  LOCATION GATE (ported from home `_ensureLocationReady`)
  // ═══════════════════════════════════════════════════

  /// Can this driver actually be found? Answers only after trying to fix it.
  ///
  /// A driver app without a location is not degraded, it is broken: dispatch
  /// ranks candidates by distance, so a driver with no fix is invisible.
  /// Going online in that state produced the worst outcome available — the
  /// app said "you are online", the driver waited a whole shift, and not one
  /// offer could ever have reached them.
  ///
  /// So this is a gate, not a warning. It asks, re-asks, and sends the
  /// driver to Settings when only Settings can fix it, and going online is
  /// refused until it answers true.
  Future<bool> _ensureLocationReady() async {
    if (kIsWeb) return true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!mounted) return false;
        await showDialog<void>(
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
                  Geolocator.openLocationSettings();
                },
                child: Text(S.of(ctx).openSettings),
              ),
            ],
          ),
        );
        return false;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        if (!mounted) return false;
        // Refusable, so offer the prompt again rather than Settings.
        final retry = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of(ctx).locationPermissionRequired),
            content: Text(S.of(ctx).locationRequiredForDriver),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(S.of(ctx).cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(S.of(ctx).retry),
              ),
            ],
          ),
        );
        if (retry != true || !mounted) return false;
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        if (!mounted) return false;
        await showDialog<void>(
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
        return false;
      }
      if (perm == LocationPermission.denied) return false;

      // Permission granted but no fix yet — start the path that produces
      // one rather than reporting ready on a promise. `_locate()` is this
      // screen's `_initLocation`: it seeds `_pos` and starts the stream.
      if (_pos == null) {
        unawaited(_locate());
      }
      return true;
    } catch (e) {
      debugPrint('[DriverOnline] location gate failed: $e');
      // Never let a thrown check be the thing that stops a shift.
      return true;
    }
  }

  // ═══════════════════════════════════════════════════
  //  IDENTITY VERIFICATION GATE (ported from home)
  // ═══════════════════════════════════════════════════
  Future<void> _checkVerification() async {
    // Driver reached this screen after passing splash/login approval gates,
    // so they are already verified. Sync local status to match.
    await LocalDataService.setDriverApprovalStatus('approved');
    if (mounted) _setState(() => _isVerified = true);
  }

  Future<bool> _ensureVerified() async {
    if (_isVerified) return true;
    // Driver is on the merged screen — they passed all gates already.
    if (mounted) _setState(() => _isVerified = true);
    return true;
  }

  // ═══════════════════════════════════════════════════
  //  VEHICLE DOCUMENT STATUS CHECK (ported from home; the
  //  `_btnColorCtrl.value = 1.0` line died with that controller — the
  //  animation it fed is only a Listenable in the GO button's merge)
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

      _setState(() {
        _vehicleDocsApproved = canGo;
        _hasExpiredDocs = expired;
        _plateChangePending = platePending;
        _docStatusLoaded = true;
      });
    } catch (e) {
      debugPrint('[DriverOnline] _checkVehicleDocStatus error: $e');
      // On error, fail-closed: require docs to be explicitly approved
      if (mounted) {
        _setState(() {
          _vehicleDocsApproved = false;
          _docStatusLoaded = true;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  REAL-TIME DOC APPROVAL LISTENER (ported from home)
  //  Fires immediately when admin approves docs in Firestore,
  //  so the driver doesn't need to restart the app.
  // ═══════════════════════════════════════════════════
  Future<void> _startDocApprovalListener() async {
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuthRecovery.ensureSignedIn();
      }
    } catch (e) {
      debugPrint('[DriverOnline] Firebase Auth for doc listener failed: $e');
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
            '[DriverOnline] Firestore doc-approval listener fired — refreshing doc status');
        _checkVehicleDocStatus();
      }
    }, onError: (e) {
      debugPrint('[DriverOnline] Doc approval listener error: $e');
    });
  }

  // ═══════════════════════════════════════════════════
  //  ACCOUNT STATUS CHECK (ported from home, timer included)
  // ═══════════════════════════════════════════════════
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

  /// Re-acceptance gate for the Independent Contractor Agreement (current
  /// version: [kDriverAgreementVersion]). Every acceptance is logged
  /// server-side (ConsentLog) with the document version, so when the
  /// agreement version bumps, a driver whose newest
  /// 'independent_contractor_agreement' acceptance is stale — or who has
  /// none — must review and accept the new version before continuing.
  /// Fail-open: a network failure never locks the driver out; the check
  /// simply re-runs on the next app start.
  Future<void> _checkDriverAgreementConsent() async {
    try {
      final items = await ApiService.fetchConsentHistory();
      if (!mounted) return;
      // The history comes newest-first: the first match is the latest.
      String? acceptedVersion;
      for (final item in items) {
        if (item['consent_type'] == 'independent_contractor_agreement' &&
            item['action'] == 'accepted') {
          acceptedVersion = item['version']?.toString();
          break;
        }
      }
      if (acceptedVersion == kDriverAgreementVersion) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => DriverAgreementScreen(
            onAccept: () => ApiService.recordConsent(
              consentType: 'independent_contractor_agreement',
              action: 'accepted',
              version: kDriverAgreementVersion,
            ),
          ),
        ),
      );
    } catch (e) {
      debugPrint(
          '[DriverOnline] agreement consent check skipped (fail-open): $e');
    }
  }

  // ── Driver permission flow (cold start) ─────────────────────────────
  //
  /// Every cold start with a signed-in driver (user spec 2026-08-25): if
  /// notifications or location are still missing, push the "Help us keep
  /// you informed" page over the map — its appear auto-fires the native
  /// asks (the OS decides whether a dialog can re-show), Allow asks again,
  /// X dismisses for the session. Both granted → nothing is shown, ever.
  Future<void> _runDriverPermissionFlow() async {
    if (kIsWeb || _DriverOnlineScreenState._permsScreenShownThisProcess) {
      return;
    }
    try {
      final locPerm = await Geolocator.checkPermission();
      final locOk = locPerm == LocationPermission.always ||
          locPerm == LocationPermission.whileInUse;
      final notifOk = await NotificationService.isPermissionGranted();
      if (!mounted || (locOk && notifOk)) return;
      _DriverOnlineScreenState._permsScreenShownThisProcess = true;
      await Navigator.of(context).push(slideUpFadeRoute(
        const DriverNotificationsScreen(
          popOnDone: true,
          requestLocation: true,
        ),
      ));
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════
  //  SCHEDULED RIDE LOCKOUT (ported from home)
  // ═══════════════════════════════════════════════════

  /// Check if driver has a scheduled ride approaching — navigate to details
  /// if locked.
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
                '[DriverOnline] Auto-start scheduled trip failed: $e — showing countdown instead');
            if (!mounted) return;
            _showScheduledCountdown(trip, minutesUntil);
          }
          return;
        }

        // ── >15 min but locked → show countdown screen ──
        _showScheduledCountdown(trip, minutesUntil);
      }
    } catch (e) {
      debugPrint('[DriverOnline] Scheduled ride check failed: $e');
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
    final driverPos = _pos ?? pickup;
    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);
    final tripId = (trip['id'] as num?)?.toInt() ?? 0;
    final riderName = _pickString(trip, ['rider_name'], fallback: 'Rider');
    final riderId = int.tryParse((trip['rider_id'] ?? '').toString());

    // No surface handoff here (mapa único): the trip screen claims the one
    // live surface through MapSurfaceCoordinator, which revokes ours; on pop
    // we claim it back.
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
        .whenComplete(() {
      if (mounted) unawaited(_remountMapSurface());
    });
  }

  // ═══════════════════════════════════════════════════
  //  ACTIVE TRIP DETECTION + RESUME (ported from home)
  // ═══════════════════════════════════════════════════

  /// Resolve driver ID first, THEN check Firestore for an active trip —
  /// the refresh cannot match rows while `_driverId` is null (home's
  /// `_resolveDriverIdThenRefresh`; `_boot` already resolves the id in the
  /// background, this is the same belt home wore over those braces).
  Future<void> _resolveDriverIdThenRefreshTrip() async {
    if (_driverId == null) {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null && mounted) _driverId = id;
      } catch (_) {}
    }
    if (_driverId == null || !mounted) return;
    await _refreshActiveTripStatus();
    // Auto-resume on cold start (same as home): a trip still live belongs
    // on screen, not behind a RESUME button.
    if (_activeTripData != null && mounted) {
      unawaited(_resumeActiveTrip());
    }
  }

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
            '[DriverOnline] ignoring stale Firestore trip ${active['_docId']}');
        active = null;
        confirmedOver = true;
      }
      if (!mounted) return;

      if (active != null) {
        // Home also flipped `_isStillOnline` here; that bit died with the
        // two-screen split — the mode is `_driverOnline` and only
        // `_enterOnlineMode` flips it. What the offline chrome needs from an
        // active trip is the RESUME affordance, and that reads this field.
        _setState(() => _activeTripData = active);
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
        _setState(() => _activeTripData = null);
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
      _setState(() => _activeTripData = trip);
      // Auto-navigate to the active trip screen
      if (mounted) _resumeActiveTrip();
    } catch (e) {
      debugPrint('[DriverOnline] Backend active trip check failed: $e');
    }
  }

  Future<void> _resumeActiveTrip() async {
    // Idempotency guard — its callers fire concurrently, and any two of them
    // would push DriverTripAcceptScreen twice.
    if (_resumingActiveTrip) {
      debugPrint(
          '[DriverOnline] _resumeActiveTrip skipped — already in progress');
      return;
    }
    // Don't re-push DriverTripAcceptScreen if this screen is not the topmost
    // route — that means a trip screen is already on the stack and pushing
    // another one on top would reset its local state (the Arrived slider,
    // Start Ride button, etc.) back to phase 1. This fires on every
    // app-resume after the driver used Google Maps for turn-by-turn.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      debugPrint(
          '[DriverOnline] _resumeActiveTrip skipped — another route is on top');
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
    final driverPos = _pos ?? pickup;
    final tripId = _tripSqlId(trip);
    if (tripId <= 0) {
      // Nothing downstream works without the real id — the trip screen would
      // PATCH /trips/0, the rating screen would rate trip 0, and every one of
      // those calls comes back 404. The driver ends up on a screen whose
      // buttons do nothing, which is how a finished trip turned into a trap.
      debugPrint(
          '[DriverOnline] active trip has no usable id: ${trip.keys.toList()}');
      if (mounted) _setState(() => _activeTripData = null);
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

    // Mapa único: no `_suspendMap()` before the push — the trip screen takes
    // the one live surface through MapSurfaceCoordinator (our `onRevoke`
    // releases it), and on pop `_remountMapSurface()` claims it back. Same
    // convention as `_pushTripScreen`.
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
      if (mounted) unawaited(_remountMapSurface());
    }

    // After trip screen pops, re-check if the trip is still active.
    // If completed/cancelled, clear state and — with the shift still on —
    // restart the offer pipeline (home's `_startTripPolling`; here the
    // online poll already owns trip detection).
    // If still active, just refresh _activeTripData so RESUME shows — do NOT
    // auto-navigate back (driver chose to leave the trip screen).
    if (!mounted) return;
    await _refreshActiveTripStatus();
    if (_activeTripData == null && _driverOnline) {
      _startPolling(force: true);
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

  // ═══════════════════════════════════════════════════
  //  GO TAP (home `_goOnline`, minus the navigation)
  // ═══════════════════════════════════════════════════

  /// The offline GO tap: gates first, then the mode flips in place on this
  /// same map — no push, no snapshot, no surface handoff (mapa único).
  void _onGoTap() async {
    // The mode flip dedups itself; two taps must not run the gates twice.
    if (_enteringOnline || _driverOnline) return;
    // Nothing about being online works without a location — dispatch ranks
    // by distance, so a driver with no fix is not "online with a bad map",
    // they are unreachable. This used to be unchecked: the button worked,
    // the app said online, and no offer could ever arrive.
    if (!await _ensureLocationReady()) return;
    if (!mounted) return;

    // _ensureVerified is synchronous in practice — the driver passed the
    // splash/login gates to be standing on this screen at all.
    if (!_isVerified) _setState(() => _isVerified = true);

    // If doc status has loaded, enforce doc gates synchronously (no await):
    // docs expired or the active vehicle not approved → documents page on
    // the problem car, and re-check on return.
    if (_docStatusLoaded && (_hasExpiredDocs || !_vehicleDocsApproved)) {
      HapticService.mediumImpact();
      final activeVehicle = await ApiService.getVehicle();
      if (!mounted) return;
      await Navigator.of(context).push(
        slideFromRightRoute(DriverDocumentsScreen(
          vehicleId: activeVehicle?['id'] as int?,
        )),
      );
      if (mounted) await _checkVehicleDocStatus();
      return;
    }
    // else: doc status not loaded yet — don't block. _verifyAndGoOnline()
    // runs the backend check in background once the mode is on.

    // Quick check: if we already know there's an active trip, resume
    // immediately instead of entering searching.
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }

    // The flip itself: GPS background mode, FCM token, backend online,
    // haptic + chime — all owned by _enterOnlineMode. `resuming` is the
    // pref read at boot: a shift that never closed is resumed, not started.
    await _enterOnlineMode(resuming: _driverWasOnlineAtBoot);
  }

  // ═══════════════════════════════════════════════════
  //  GO BUTTON (ported from home; clocks renamed `_go*` —
  //  `_pulseCtrl`/`_pulseAnim` here belong to the offer card)
  // ═══════════════════════════════════════════════════

  /// The GO button, morphing between two shapes as the sheet is dragged.
  ///
  /// Open, it is the wide pill at the foot of the sheet — the one action the
  /// panel offers. Closed, there is no sheet to sit in, so it becomes the
  /// round GO hovering over the map.
  ///
  /// Both are the same widget travelling, not two widgets swapping. Every
  /// property — width, height, corner radius, height above the screen floor,
  /// and which of the two labels is showing — is read straight off
  /// `_panelFrac`, the merged screen's 0-to-1 panel fraction (home read its
  /// VelocityAwarePanelMixin's `panelExtent`; the mixin was not ported).
  Widget _buildMorphingGoButton(EdgeInsets pad, {bool hidden = false}) {
    final t = _panelFrac.clamp(0.0, 1.0); // 0 = closed circle, 1 = open pill
    final height = ui.lerpDouble(_kGoCircleD, _kGoPillH, t)!;
    final radius = ui.lerpDouble(_kGoCircleD / 2, 16.0, t)!;

    // Closed: floating clear of the sheet's rounded top. Open: resting on the
    // sheet's floor, above the home indicator.
    //
    // The disc carries a gold glow that reaches roughly eight points past its
    // edge, so a gap measured to the edge is not the gap anyone sees. At 40
    // the glow ends 32 pt clear of the sheet on every device (home's number,
    // measured against its `_panelCollapsedH`; the merged collapsed sheet is
    // the same two rows — grab handle over status — so it carries over).
    final insetShortfall = math.max(0.0, 24 - pad.bottom);
    final bottomClosed = _offlinePanelCollapsedH + 40 + insetShortfall;
    final bottom = ui.lerpDouble(bottomClosed, 0, t)!;

    // Inset on both sides and centred inside whatever that leaves, rather
    // than positioned from the screen's width.
    return Positioned(
      bottom: bottom,
      left: ui.lerpDouble(_kGoSideInset, 0, t)!,
      right: ui.lerpDouble(_kGoSideInset, 0, t)!,
      // Hidden while online (user spec 2026-08-27) — the wrapper lives
      // INSIDE the Positioned: anything between a Positioned and its Stack
      // is a StackParentData cast crash on every rebuild (2026-08-28).
      child: IgnorePointer(
        ignoring: hidden,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: hidden ? 0.0 : 1.0,
          child: FadeTransition(
            opacity: _goFabScale ?? const AlwaysStoppedAnimation<double>(1.0),
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
        ),
      ),
    );
  }

  /// Collapsed height of the sheet the closed GO disc floats above — home's
  /// `_panelBaseH` (grab handle + status row, 52, plus the home-indicator
  /// inset). The merged panel's own collapsed geometry lives with the
  /// `_panelFrac` machinery in driver_online_widgets.dart; this is what the
  /// disc's bottom offset measures from until the two are reconciled in the
  /// build integration.
  double get _offlinePanelCollapsedH =>
      52.0 + (MediaQuery.maybeOf(context)?.padding.bottom ?? 0);

  /// A driver who never went offline is not starting a shift, they are
  /// stepping back into one — so the button says RESUME, the same word the
  /// home pill used in that state (user spec 2026-08-06).
  bool get _goShowsResume => _activeTripData != null || _driverWasOnlineAtBoot;

  // ═══════════════════════════════════════════════════
  //  FLOATING GO BUTTON — inner pulse glow
  // ═══════════════════════════════════════════════════
  Widget _buildGoButton({double radius = 16.0, double morph = 1.0}) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: _isVerified
          ? _onGoTap
          : () async {
              await _ensureVerified();
            },
      child: AnimatedBuilder(
        animation: Listenable.merge([
          if (_goPulseAnim != null) _goPulseAnim!,
          if (_goBtnColorAnim != null) _goBtnColorAnim!,
          if (_goGlossCtrl != null) _goGlossCtrl!,
          if (_goRadarCtrl != null) _goRadarCtrl!,
        ]),
        builder: (_, __) {
          final p = _goPulseAnim?.value ?? 1.0;
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
          // the bar.
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
          const glowColor = _offlineGold;

          // Gold on black, then black on gold.
          final fgColor = enabled
              ? Color.lerp(_offlineGold, const Color(0xFF0B0B0F), morph)!
              : dc.textSecondary;

          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              // Without this the body never fills its own button.
              //
              // A Stack hands loose constraints to its non-positioned
              // children, so the Container below sized itself to the Row
              // inside it and sat in the top-left corner of the rest. The
              // Row below already says mainAxisAlignment.center, which only
              // means anything in a box wider than the Row. This is what
              // makes the box wider than the Row.
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
                            color: _offlineGold.withValues(
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
                      // the spinner while entering online and the warning
                      // when documents are missing — states where the button
                      // is refusing to do what it says and has to look like
                      // it.
                      if (_enteringOnline || !docsOk || morph > 0.35) ...[
                        Opacity(
                          opacity: (_enteringOnline || !docsOk)
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
                            child: _enteringOnline
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: enabled
                                          ? Colors.black87
                                          : _offlineGold,
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
                              // Scale-down rather than a smaller fixed size:
                              // the circle was cut for two letters, and
                              // REANUDAR is eight.
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _goShowsResume
                                      ? S.of(context).resumeOnline
                                      : 'GO',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: fgColor,
                                    fontSize: ui.lerpDouble(
                                        _goShowsResume ? 15 : 22, 14, morph),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                            Opacity(
                              opacity: ((morph - 0.35) / 0.65).clamp(0.0, 1.0),
                              child: Text(
                                _enteringOnline
                                    ? 'GOING ONLINE...'
                                    : _isVerified
                                        ? (!docsOk
                                            // A plate change is the driver's
                                            // own doing and has one fix, so
                                            // the button names the problem
                                            // rather than the folder.
                                            ? S.of(context).viewIssue
                                            : _goShowsResume
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
                if (enabled && morph < 0.9 && _goRadarCtrl != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: (1 - morph).clamp(0.0, 1.0),
                        child: CustomPaint(
                          painter: _GoRadarPainter(
                            progress: _goRadarCtrl!.value,
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

  // ═══════════════════════════════════════════════════
  //  OFFLINE PANEL CONTENT (the home sheet's column; its drag
  //  machinery stayed behind — the merged screen's `_panelFrac`
  //  panel owns the gesture)
  // ═══════════════════════════════════════════════════

  /// The sheet the driver gets while OFFLINE: the static "You're offline"
  /// header (tap does nothing — going online is the GO button's job), then
  /// the scrollable body ported from the home panel: Cruise Level, the
  /// reserved-rides card, earnings with its chart, trips/hours counters and
  /// the recommendation row.
  ///
  /// Data reconciliation: home fed this from its own `_refreshStats` and
  /// `_todayEarnings`/`_todayTrips`/`_todayHours` fields. This screen already
  /// owns the same numbers (`_earnings`, `_tripsToday`, `_hoursToday`,
  /// `_weeklyEarnings`, `_hourlySeries`, `_daySeries`) via `_loadAllEarnings`
  /// + `_startEarningsRefresh`, which run in both modes — so the builders
  /// below read those and `_refreshStats` was not ported.
  Widget _buildOfflinePanelContent(Color textMuted, EdgeInsets pad) {
    final dc = DriverColors.of(context);
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header row: status | chevron — static in offline mode ──
        //
        // Home's row flipped between "You're offline" and "Finding trips"
        // and doubled as the way back online; both died with the two-screen
        // split. Offline there is one true sentence, and the drag affordance
        // belongs to the merged panel's own handle.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dc.text.withValues(alpha: 0.3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.youreOffline,
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
              // The chevron that says there is more below. Tap is a no-op on
              // purpose: the sheet's own handle takes the gesture.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: dc.textSecondary,
                      size: 30,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // ── Body — scrollable, where it used to be locked. The content grew
        // (Cruise Level, the earnings chart) and locked physics do not shrink
        // to fit, they clip. ──
        Expanded(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            // The foot of the list clears the GO button hovering over it: the
            // button's own height, the gap it keeps above the home indicator,
            // and a little air on top. Without this the last row sits
            // underneath it.
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 8 + _kGoPillH + 26 + pad.bottom),
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
                  s.earningsTitle,
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
                // Earnings moved to the pill and the chart above, so only the
                // two figures that are not money live here.
                Row(
                  children: [
                    Expanded(
                      child: _panelStat(
                        Icons.local_taxi_rounded,
                        '$_tripsToday',
                        s.tripsToday,
                        true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _panelStat(
                        Icons.schedule_rounded,
                        _onlineTimeText(_hoursToday),
                        s.hoursOnline,
                        true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  s.recommendedForYou,
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
                        s.seeEarningsTrends,
                        () {
                          Navigator.of(context).push(
                            slideFromRightRoute(const DriverEarningsScreen()),
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
      ],
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
              child: Icon(icon, color: _offlineGold, size: 22),
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
                  color: _offlineGold, size: Responsive.sp(19)),
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

  /// The reserved-rides card, which is only there when there is one.
  ///
  /// It grows into the sheet rather than appearing: a card that pops into
  /// a list the driver is already reading shoves everything below it down
  /// by its full height in one frame, and whatever they were about to tap
  /// is somewhere else by the time their thumb lands.
  ///
  /// AnimatedSize carries the height, a fade and a small rise carry the
  /// card. Home showed it on its `_scheduledBannerVisible` (online and no
  /// active trip and count > 0); here the count this screen already polls
  /// (`_scheduledAvailCount`) is the whole condition — the same number the
  /// calendar FAB's badge wears.
  Widget _buildReservedRidesCard(DriverColors dc) {
    final show = _scheduledAvailCount > 0;
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
                key: ValueKey('reserved_$_scheduledAvailCount'),
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
                                        _scheduledAvailCount,
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

  Widget _buildEarningsSection(DriverColors dc) {
    final s = S.of(context);
    final total = _panelWeekTab ? _weeklyEarnings : _earnings;
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.w(14), Responsive.h(12),
          Responsive.w(14), Responsive.h(10)),
      decoration: neuBox(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _periodPill(dc, s.today, !_panelWeekTab, () {
                if (!_panelWeekTab) return;
                HapticService.selectionClick();
                _setState(() => _panelWeekTab = false);
              }),
              SizedBox(width: Responsive.w(8)),
              _periodPill(dc, s.weekLabel, _panelWeekTab, () {
                if (_panelWeekTab) return;
                HapticService.selectionClick();
                _setState(() => _panelWeekTab = true);
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
                        color: _offlineGold,
                        fontSize: Responsive.sp(13),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: Responsive.w(4)),
                    Icon(Icons.arrow_forward_rounded,
                        color: _offlineGold, size: Responsive.sp(15)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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
            color: selected ? _offlineGold : dc.textSecondary,
            fontSize: Responsive.sp(12),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// Bars for the selected period. Hand-drawn rather than pulling in a chart
  /// package: it is a row of rectangles, and a dependency for that would cost
  /// a native rebuild to ship.
  Widget _earningsChart(DriverColors dc) {
    final week = _panelWeekTab;
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
                                      color: _offlineGold.withValues(alpha: 0.85),
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
            color: isNow ? _offlineGold : _offlineGold.withValues(alpha: 0.30),
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

  // ═══════════════════════════════════════════════════
  //  MENU BUTTON (the home top bar's `_glassBtn`, menu flavour)
  // ═══════════════════════════════════════════════════

  /// The driver menu, with the fade the home top bar gave it.
  void _openDriverMenu() {
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
  }

  /// The offline chrome's menu button.
  ///
  /// 48 flat, not Responsive.w(48): Responsive.w is `px * (width / 390)`, so
  /// the button grew with the viewport while this screen's side buttons are
  /// passed a plain 48 — the same two controls came out different sizes on
  /// anything that is not a 390-wide phone. Round, with the same faint gold
  /// rim the online screen's side buttons carry.
  Widget _buildOfflineMenuButton() {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: _openDriverMenu,
      child: Container(
        width: 48,
        height: 48,
        decoration: neuBox(
          radius: 24,
          borderColor: const Color(0xFFE8C547).withValues(alpha: 0.18),
        ),
        // 48 * 0.44, the ratio `_fab` uses.
        child: Icon(Icons.menu_rounded, color: dc.text, size: 48 * 0.44),
      ),
    );
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
