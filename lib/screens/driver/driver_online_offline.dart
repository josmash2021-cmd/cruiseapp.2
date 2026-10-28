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
///   * the boot guards ([_checkAccountStatus], [_checkContractsGate],
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
const double _kGoPillH = 62.0; // 2026-10-15: "un poquito más grande"
const double _kGoCircleD = 74.0;
const double _kGoSideInset = 20.0;

/// Resting sheet position while OFFLINE (user spec 2026-10-13: "el sheet
/// debe estar un poco más abierto y el botón aparecerá abajo de forma
/// píldora… si el driver desliza hacia abajo, aparece el GO normal"):
/// three snap points now — 0 collapsed (circle GO), this rest (pill
/// "Go online" fully formed at the sheet floor), 1 fully open.
/// Top-level, not a static on the extension: part-file access to extension
/// constants has failed the iOS build before.
/// 0.42 (2026-10-17, spec "un poquito mas cerrado el sheet o compacto" —
/// foto 2): el reposo abraza el contenido (header + hero + botones) sin la
/// banda muerta debajo de la tarjeta de demanda que dejaba el 0.5.
const double _kSheetRestFrac = 0.42;

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
      final reasons = (result['reasons'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      // Contracts and rest have their own gates: neither is a vehicle-document
      // failure or the GO tap would open the wrong screen.
      final vehicleDocsApproved = canGo ||
          (reasons.isNotEmpty &&
              reasons.every((r) =>
                  r == 'contracts_not_accepted' || r == 'shift_rest_required'));
      // Unsigned required contracts (e-acceptance gate, 2026-10-21): the GO
      // tap opens the contracts hub before the mode flips.
      final pending = (result['contracts_pending'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      // Daily face check (2026-10-23): a signal, never a blocker — the GO
      // tap reads it fresh and runs the liveness screen before connecting.
      final faceDue = result['face_check_due'] == true;
      // Dress-code rejection path (2026-10-23): required = the next selfie
      // needs manual dispatch review; pending = one is already in review.
      final faceReview = result['face_review_required'] == true;
      final facePending = result['face_check_pending'] == true;
      // Dispatch GO switch (2026-10-23): a blocker, unlike the face signals.
      final goDisabled = result['go_online_disabled'] == true;

      _serverRestResponseKnown = result.containsKey('rest_until');
      final serverRestRaw = result['rest_until']?.toString();
      final serverRest = serverRestRaw == null || serverRestRaw.isEmpty
          ? null
          : DateTime.tryParse(serverRestRaw);
      if (serverRest != null && serverRest.isAfter(DateTime.now())) {
        if (_restUntil?.millisecondsSinceEpoch !=
            serverRest.millisecondsSinceEpoch) {
          _setRestUntil(serverRest);
        }
      } else if (_serverRestResponseKnown && _restUntil != null) {
        _restUntil = null;
        _restJustFinishedAt = null;
        _restTickTimer?.cancel();
        _restTickTimer = null;
        PrefsCache.instance.then((p) => p.setInt('driver_rest_until', 0));
        unawaited(DriverRestService.set(null));
      }

      // Sync approval status locally
      if (result['approved'] == true) {
        await LocalDataService.setDriverApprovalStatus('approved');
      }
      if (!mounted) return;

      _setState(() {
        _vehicleDocsApproved = vehicleDocsApproved;
        _hasExpiredDocs = expired;
        _plateChangePending = platePending;
        _contractsPending = pending;
        _faceCheckDue = faceDue;
        _faceReviewRequired = faceReview;
        _faceCheckPending = facePending;
        _goOnlineDisabled = goDisabled;
        _docStatusLoaded = true;
      });
      _syncFaceReviewPoll();
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

  /// Re-acceptance gate for the five driver contracts (2026-10-21, user
  /// spec — Uber-style e-acceptance; it replaced the old single-ICA check).
  /// The server tracks each document's current version against the driver's
  /// newest acceptance (ConsentLog evidence), so a dispatch version bump —
  /// or a driver who never signed — lands here and must review and sign
  /// before continuing. Fail-open: a network failure never locks the driver
  /// out; the check simply re-runs on the next app start.
  Future<void> _checkContractsGate() async {
    try {
      final data = await ApiService.getContracts();
      if (!mounted) return;
      if (data['all_current'] == true) return;
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => const DriverContractsScreen(gate: true),
        ),
      );
      if (completed == true && mounted) {
        _setState(() => _contractsPending = const []);
      }
    } catch (e) {
      debugPrint('[DriverOnline] contracts gate skipped (fail-open): $e');
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
              stopLatLng: parseTripStop(trip)?.point,
              stopLabel: parseTripStop(trip)?.label ?? '',
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
            stopLatLng: parseTripStop(trip)?.point,
            stopLabel: parseTripStop(trip)?.label ?? '',
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
    final restRemaining = _restUntil?.difference(DateTime.now());
    if (restRemaining != null && restRemaining > Duration.zero) {
      _showRestRemaining(restRemaining);
      return;
    }
    // Dispatch GO switch (2026-10-23, owner spec — instant): a paused GO
    // never even starts the gates — the tap only explains.
    if (_goOnlineDisabled) {
      HapticService.mediumImpact();
      _showGoOnlineDisabledDialog();
      return;
    }
    // Zone selection gate (2026-10-11, user spec: "si no ha seleccionado o
    // tocado una zona se quedará el botón apagado") — with the zone layer
    // ON, the GO tap needs a tapped city first; the hint says so.
    //
    // State separation (2026-10-14): a stale pick from the OTHER state
    // (saved before the split, or before crossing a border) is not a working
    // zone — clear it and fall into the no-selection hint below.
    final selSector = _selectedZoneName != null
        ? ZoneService.sectorById(_selectedZoneName!)
        : null;
    if (selSector != null &&
        !ZoneService.visibleSectorsFor(
                _pos == null ? null : ZoneService.stateOfPoint(_pos!))
            .any((v) => v.id == selSector.id)) {
      _setState(() => _selectedZoneName = null);
      PrefsCache.instance.then((p) => p.remove('driver_selected_zone'));
      _syncZoneLayers(forceHighlight: true);
    }
    if (FeatureFlags.zonesMapEnabled && _selectedZoneName == null) {
      HapticService.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(S.of(context).zoneSelectHint),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    if (FeatureFlags.zonesMapEnabled &&
        _selectedZoneName != null &&
        ZoneService.demand[_selectedZoneName]?.off == true) {
      HapticService.mediumImpact();
      _showZoneDisabledDialog();
      return;
    }
    // Nothing about being online works without a location — dispatch ranks
    // by distance, so a driver with no fix is not "online with a bad map",
    // they are unreachable. This used to be unchecked: the button worked,
    // the app said online, and no offer could ever arrive.
    if (!await _ensureLocationReady()) return;
    if (!mounted) return;

    // Sector connect gate (2026-10-14, user spec: "dentro del cuadro podrá
    // conectarse" — ahora con sectores de Florida Y Alabama; un solo
    // dataset, el que se edita en el panel): connecting is only allowed
    // inside a sector polygon, and only enforced INSIDE the sector coverage
    // region (union bbox) — a driver out in an uncovered state/region is
    // never gated. FAIL-OPEN while the sector data isn't loaded or the
    // zones flag is off (the kill switch kills the gate with the drawing —
    // with no zone UI the driver would have no way to know why GO refuses):
    // the server's own gate (403 outside_service_area) is the backstop.
    if (FeatureFlags.zonesMapEnabled &&
        ZoneService.sectorsReady &&
        _pos != null &&
        ZoneService.insideSectorCoverage(_pos!) &&
        ZoneService.sectorContaining(_pos!) == null) {
      HapticService.mediumImpact();
      _showZoneOutsideDialog();
      return;
    }

    // Zone OFF gate (2026-10-17, owner spec "todo se controla desde
    // dispatch"): connecting inside a sector dispatch switched OFF is
    // refused — the server's own gate (403 zone_disabled) is the backstop.
    if (FeatureFlags.zonesMapEnabled &&
        ZoneService.sectorsReady &&
        _pos != null &&
        ZoneService.sectorOff(_pos!)) {
      HapticService.mediumImpact();
      _showZoneDisabledDialog();
      return;
    }

    // _ensureVerified is synchronous in practice — the driver passed the
    // splash/login gates to be standing on this screen at all.
    if (!_isVerified) _setState(() => _isVerified = true);

    // Re-verify FRESH before bouncing on a stale boot snapshot (2026-10-23,
    // owner report: firmé los contratos y el GO seguía negando con la lista
    // cacheada del boot — tuve que cerrar la app): the gates below trust the
    // last _checkVehicleDocStatus result; when it says "blocked", re-run it
    // NOW — a driver who JUST signed/approved must pass on the first tap.
    if (_docStatusLoaded &&
        (_hasExpiredDocs ||
            !_vehicleDocsApproved ||
            _contractsPending.isNotEmpty)) {
      await _checkVehicleDocStatus();
      if (!mounted) return;
    }

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
    // Unsigned contracts gate (2026-10-21, user spec item 4: a driver is
    // never activated — and never goes online — with required contracts
    // pending). The backend can_go_online refuses as the backstop.
    if (_docStatusLoaded && _contractsPending.isNotEmpty) {
      HapticService.mediumImpact();
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => const DriverContractsScreen(gate: true),
        ),
      );
      if (!mounted) return;
      if (completed == true) {
        _setState(() => _contractsPending = const []);
      } else {
        await _checkVehicleDocStatus();
        if (!mounted) return;
      }
      if (_contractsPending.isNotEmpty) return;
    }
    // else: doc status not loaded yet — don't block. _verifyAndGoOnline()
    // runs the backend check in background once the mode is on.

    // Quick check: if we already know there's an active trip, resume
    // immediately instead of entering searching.
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }

    // Daily face check (2026-10-23, owner spec — REAL, not a promise): >24 h
    // without a verified selfie → the liveness screen runs BEFORE connecting;
    // cancelling = no GO. A failed UPLOAD doesn't lock the driver out
    // (fail-open: retried on the next GO tap). Runs after the active-trip
    // resume so a mid-trip driver is never gated.
    if (_docStatusLoaded && _faceCheckDue) {
      HapticService.mediumImpact();
      final res = await Navigator.of(context).push<Map?>(
        MaterialPageRoute<Map?>(
          fullscreenDialog: true,
          builder: (_) => const SelfieCheckScreen(),
        ),
      );
      if (!mounted) return;
      final photoPath = res?['photo']?.toString();
      if (photoPath == null || photoPath.isEmpty) return; // cancelled — no GO
      // The screen uploaded the shot itself and held the verifying loader
      // (owner spec 2026-10-23): an approval closes the page with the
      // driver ALREADY connecting — no 1-3 s home detour.
      if (res!['pending'] == true) {
        // Dispatch has not decided (wait ceiling / escape X) — grey review
        // GO + 30 s poll; no connect until it clears.
        _setState(() {
          _faceReviewRequired = true;
          _faceCheckPending = true;
          _faceCheckDue = false;
        });
        _syncFaceReviewPoll();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(S.of(context).faceReviewPending),
          duration: const Duration(seconds: 3),
        ));
        return;
      }
      if (res['approved'] == false) {
        _setState(() {
          _faceReviewRequired = true;
          _faceCheckPending = false;
          _faceCheckDue = false;
        });
        _showFaceRejectedDialog();
        return;
      }
      if (res['approved'] == true) {
        _setState(() {
          _faceReviewRequired = false;
          _faceCheckPending = false;
          _faceCheckDue = false;
        });
      }
      // A bare photo = upload failed — fail-open: the GO proceeds and the
      // check retries on a later tap (same rule as before).
    }

    // The flip itself: GPS background mode, FCM token, backend online,
    // haptic + chime — all owned by _enterOnlineMode. `resuming` is the
    // pref read at boot: a shift that never closed is resumed, not started.
    // The "You're now online!" intro no longer fires here (2026-10-23 owner
    // spec): it is armed by _enterOnlineMode itself, 10 s into the shift.
    await _enterOnlineMode(resuming: _driverWasOnlineAtBoot);
  }

  /// The GO tap outside every enabled city polygon: no connect, just the
  /// explanation (ES/EN by the phone's language like every user-facing string).
  void _showZoneOutsideDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A22),
        title: Text(
          S.of(ctx).zoneOutsideTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.of(ctx).zoneOutsideBody(
              _pos == null ? null : ZoneService.stateOfPoint(_pos!)),
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(ctx).gotIt),
          ),
        ],
      ),
    );
  }

  /// The GO face states (2026-10-23, owner spec): 0 normal · 1 verify
  /// (GREY "Verificar", no animation — the owner killed the red the same
  /// day: animation belongs to GO ONLINE only) · 2 pending review (disabled
  /// grey). The collapsed GO circle does NOT render in a non-normal state
  /// (circle rule).
  int get _faceGateState =>
      _faceCheckPending ? 2 : _faceReviewRequired ? 1 : 0;

  /// While a selfie sits in manual review, a 30 s canGoOnline poll
  /// auto-clears the pending state when dispatch approves. Cancelled on
  /// dispose and as soon as the state clears.
  void _syncFaceReviewPoll() {
    if (_faceCheckPending && !_driverOnline) {
      _faceReviewTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        _checkVehicleDocStatus();
      });
    } else {
      _faceReviewTimer?.cancel();
      _faceReviewTimer = null;
    }
  }

  /// Dispatch decided the pending selfie (push face_check_rejected /
  /// face_check_approved): re-read the gate flags.
  void _onFaceReviewPush() {
    if (!mounted) return;
    _checkVehicleDocStatus();
  }

  /// Dispatch reviewed the dress-code selfie LIVE over the socket
  /// (face_check_reviewed — 2026-10-23 owner report: "rechazar no
  /// desconecta si está conectado"). Rejected && !deferred = the shift
  /// ends NOW: the backend already wrote is_online=False, so exit online
  /// mode and let the re-read flags paint the red "Verificar" GO.
  /// Deferred = rider aboard — trips.py lands the cut at trip close; no
  /// exit and no dialog mid-trip. Approved = the grey review GO unlocks.
  void _onFaceCheckReviewed(Map<String, dynamic> data) {
    if (!mounted) return;
    final approved = data['approved'] == true;
    final deferred = data['deferred'] == true;
    final wasRequired = _faceReviewRequired;
    unawaited(_checkVehicleDocStatus());
    if (approved || deferred) return;
    if (_driverOnline) unawaited(_exitOnlineMode());
    if (!wasRequired) _showFaceRejectedDialog();
  }

  /// Same copy as the rejection push (main.dart _handleFaceCheckResult) —
  /// shown by the live socket path, where no banner tap is involved.
  void _showFaceRejectedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A22),
        title: Text(
          S.of(ctx).faceRejectedTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.of(ctx).faceRejectedBody,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(ctx).gotIt),
          ),
        ],
      ),
    );
  }

  /// GO in the VERIFY state (dress-code rejection): the SAME selfie flow as
  /// the daily check, but the shot lands in MANUAL review — the screen holds
  /// its verifying loader until dispatch decides (owner spec 2026-10-23: the
  /// page closes with the driver ALREADY activating on approve; never a home
  /// detour). Undecided (ceiling/escape) → the grey review GO + poll.
  Future<void> _onFaceVerifyTap() async {
    if (_enteringOnline || _driverOnline) return;
    HapticService.mediumImpact();
    final res = await Navigator.of(context).push<Map?>(
      MaterialPageRoute<Map?>(
        fullscreenDialog: true,
        builder: (_) => const SelfieCheckScreen(),
      ),
    );
    if (!mounted) return;
    final photoPath = res?['photo']?.toString();
    if (photoPath == null || photoPath.isEmpty) return; // cancelled — no GO
    if (res!['pending'] == true) {
      _setState(() {
        _faceCheckPending = true;
        _faceCheckDue = false;
      });
      _syncFaceReviewPoll();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(S.of(context).faceReviewPending),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    if (res['approved'] == false) {
      // Rejected again — back to the grey Verificar GO + the why dialog.
      _setState(() {
        _faceReviewRequired = true;
        _faceCheckPending = false;
      });
      _showFaceRejectedDialog();
      return;
    }
    if (res['approved'] == true) {
      // Approved: connect NOW — the chime and the flip ride with the page
      // closing (owner spec: "se cerrara ya activando al driver").
      _setState(() {
        _faceReviewRequired = false;
        _faceCheckPending = false;
        _faceCheckDue = false;
      });
      _onGoTap();
      return;
    }
    // Bare photo = upload failed — fail-open: retry on the next tap.
  }

  /// The driver stands in a sector dispatch switched OFF (2026-10-17, owner
  /// spec: "si esta apagada la zona no pueden prenderse") — no connect.
  void _showZoneDisabledDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A22),
        title: Text(
          S.of(ctx).zoneDisabledTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.of(ctx).zoneDisabledBody,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(ctx).gotIt),
          ),
        ],
      ),
    );
  }

  /// Dispatch GO switch (2026-10-23, owner spec — instant): the tap on a
  /// paused GO never flips — it only explains. The socket listener and the
  /// terminal 403 path land here too.
  void _showGoOnlineDisabledDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A22),
        title: Text(
          S.of(ctx).goOnlineDisabledTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.of(ctx).goOnlineDisabledBody,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(ctx).gotIt),
          ),
        ],
      ),
    );
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
  /// `_panelFrac`, the merged screen's 0-to-1 panel fraction — remapped so
  /// the morph COMPLETES at the resting position: the button is a full pill
  /// by the time the sheet rests (2026-10-13 spec), not a half-formed
  /// in-between.
  Widget _buildMorphingGoButton(EdgeInsets pad, {bool hidden = false}) {
    final t = (_panelFrac / _kSheetRestFrac).clamp(0.0, 1.0);
    // Circle rule (2026-10-23, owner spec literal): in the VERIFY or REVIEW
    // face states the collapsed GO circle/pill does NOT render with the
    // sheet closed — the button only exists inside the open sheet.
    final faceGateHidden = _faceGateState != 0 && t < 0.99;
    final height = ui.lerpDouble(_kGoCircleD, _kGoPillH, t)!;
    // estilo píldora (2026-10-15): esquinas = mitad de la altura
    final radius = ui.lerpDouble(_kGoCircleD / 2, _kGoPillH / 2, t)!;

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

    // Inset on both sides; inside, the button travels from centred (closed
    // disc) to the LEFT half (open pill — user spec 2026-10-14: "a la
    // izquierda hasta la mitad, no en el centro").
    return Positioned(
      bottom: bottom,
      left: ui.lerpDouble(_kGoSideInset, 0, t)!,
      right: ui.lerpDouble(_kGoSideInset, 0, t)!,
      // Hidden while online (user spec 2026-08-27) — the wrapper lives
      // INSIDE the Positioned: anything between a Positioned and its Stack
      // is a StackParentData cast crash on every rebuild (2026-08-28).
      child: IgnorePointer(
        ignoring: hidden || faceGateHidden,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: (hidden || faceGateHidden) ? 0.0 : 1.0,
          child: FadeTransition(
            opacity: _goFabScale ?? const AlwaysStoppedAnimation<double>(1.0),
            child: Container(
              padding: EdgeInsets.fromLTRB(
                ui.lerpDouble(0, 20, t)!,
                ui.lerpDouble(0, 14, t)!,
                ui.lerpDouble(0, 20, t)!,
                ui.lerpDouble(0, 14 + pad.bottom, t)!,
              ),
              // SIN franja de pie (user spec 2026-10-17, foto 2): el footer
              // con fondo + hairline + sombra se leía como una barra aparte;
              // los botones van directos sobre el sheet, transparentes.
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  children: [
                    Align(
                      // Closed, the disc floats centred; as the sheet opens
                      // the alignment itself travels left and the pill ends
                      // up LONG on the left of the row, leaving room for the
                      // calendar disc (46 + 12 de aire) — user spec
                      // 2026-10-16: "el botón largo así como la foto 3".
                      alignment: Alignment.lerp(
                          Alignment.center, Alignment.centerLeft, t)!,
                      child: SizedBox(
                        width:
                            ui.lerpDouble(_kGoCircleD, box.maxWidth - 58, t),
                        height: height,
                        child: _buildGoButton(radius: radius, morph: t),
                      ),
                    ),
                    // El calendario al lado DERECHO del pill (user spec
                    // 2026-10-16: "el lado derecho donde esta el bolante
                    // colocaras igualmente el calendario") — abre la página
                    // de agendados; aparece con la forma pill. Tappable solo
                    // cuando la forma pill está puesta: invisible no puede
                    // comer taps del mapa.
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: IgnorePointer(
                          ignoring: t < 0.5,
                          child: Opacity(
                            opacity: t,
                            child: _GoScheduleButton(
                              onTap: _openScheduledRides,
                              count: _scheduledAvailCount,
                              bounceAnimation: _scheduledBounceAnim,
                            ),
                          ),
                        ),
                      ),
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

  /// El calendario junto al GO pill abre el mapa de agendados (user spec
  /// 2026-10-16). La página de agendados toma la única superficie nativa;
  /// al volver la reclamamos — la misma disciplina del toast de agendados
  /// (driver_online_screen.dart) reforzada por la red `didPopNext`.
  void _openScheduledRides() {
    HapticService.selectionClick();
    Navigator.of(context)
        .push(slideFromRightRoute(const ScheduledRidesMapScreen()))
        .then((_) {
      if (!mounted) return;
      _fetchScheduledCount();
      _remountMapSurface();
    });
  }

  void _setRestUntil(DateTime when) {
    if (!mounted) return;
    _restUntil = when;
    _restJustFinishedAt = null;
    _restSyncTicks = 0;
    PrefsCache.instance.then(
        (p) => p.setInt('driver_rest_until', when.millisecondsSinceEpoch));
    unawaited(DriverRestService.set(when));
    _restTickTimer?.cancel();
    _restTickTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _onRestTick());
    _setState(() {});
  }

  void _restoreRestUntil() {
    PrefsCache.instance.then((p) {
      if (!mounted) return;
      final ms = p.getInt('driver_rest_until') ?? 0;
      if (ms <= 0) return;
      final when = DateTime.fromMillisecondsSinceEpoch(ms);
      if (when.isAfter(DateTime.now())) {
        _setRestUntil(when);
      } else {
        p.setInt('driver_rest_until', 0);
        unawaited(DriverRestService.set(null));
      }
    });
  }

  void _onRestTick() {
    if (!mounted) return;
    _restSyncTicks++;
    if (_restSyncTicks >= 15) {
      _restSyncTicks = 0;
      unawaited(_checkVehicleDocStatus());
    }
    final now = DateTime.now();
    if (_restUntil != null) {
      if (now.isBefore(_restUntil!)) {
        _setState(() {});
        return;
      }
      _restJustFinishedAt = now;
      _restUntil = null;
      PrefsCache.instance.then((p) => p.setInt('driver_rest_until', 0));
      unawaited(DriverRestService.set(null));
      _setState(() {});
      return;
    }
    final finishedAt = _restJustFinishedAt;
    if (finishedAt != null) {
      if (now.difference(finishedAt) < const Duration(milliseconds: 2500)) {
        return;
      }
      _restJustFinishedAt = null;
      _setState(() {});
    }
    _restTickTimer?.cancel();
    _restTickTimer = null;
  }

  static String _fmtRest(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _showRestRemaining(Duration remaining) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(S.of(context).restRemainingLabel(_fmtRest(remaining))),
      behavior: SnackBarBehavior.floating,
    ));
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
    final faceState = _faceGateState;
    final now = DateTime.now();
    final restRemaining = _restUntil?.difference(now);
    final resting = restRemaining != null && restRemaining > Duration.zero;
    final readyRecently = _restJustFinishedAt != null &&
        now.difference(_restJustFinishedAt!) <
            const Duration(milliseconds: 2500);
    return GestureDetector(
      // Dispatch GO switch (2026-10-23 owner spec): paused = the tap ONLY
      // explains, never flips — and it outranks even the face gate.
      // Face gate (2026-10-23 owner spec): pending review = dead button;
      // verify = the red "Verificar" runs the liveness flow, not the flip.
      onTap: resting
          ? () => _showRestRemaining(restRemaining)
          : _goOnlineDisabled
          ? _showGoOnlineDisabledDialog
          : faceState == 2
              ? null
              : faceState == 1
                  ? _onFaceVerifyTap
              : _isVerified
                  ? _onGoTap
                  : () async {
                      // El primer tap no puede morir en "marcar verificado" (user
                      // report 2026-10-16-noche: "al boton de go online hay que
                      // darle dos veces para que se conecte") — verificar y
                      // CONTINUAR al flip en el mismo tap.
                      if (await _ensureVerified()) _onGoTap();
                    },
      child: AnimatedBuilder(
        animation: Listenable.merge([
          if (_goPulseAnim != null) _goPulseAnim!,
          if (_goBtnColorAnim != null) _goBtnColorAnim!,
          if (_goGlossCtrl != null) _goGlossCtrl!,
          if (_goThrobAnim != null) _goThrobAnim!,
          if (_goIgniteCtrl != null) _goIgniteCtrl!,
        ]),
        builder: (_, __) {
          // Breathing muerto (2026-10-15, spec "sin latido o respiración") —
          // valor fijo; el brillo lo da el gloss barrido.
          const p = 0.6;
          final docsOk = _vehicleDocsApproved || !_docStatusLoaded;
          // Look NORMAL always (user spec 2026-10-11: "el botón de GO no se
          // vea desactivado, siempre normal en amarillo") — docs/verification
          // still gate the TAP (they route to the fix), never the paint.

          // Gold body, black lettering. ONE gold in every shape (user spec
          // 2026-10-14: "cuando el sheet está abierto debe ser del mismo
          // color que cuando está GO") — the disc's deep golds, no morph
          // lerp. The pulse breathing between the two tops stays.
          const goldTop1 = Color(0xFFC9981F);
          const goldTop2 = Color(0xFFD4A82A);
          const goldBot = Color(0xFF9A7414);

          final topColor0 = Color.lerp(goldTop1, goldTop2, p)!;
          // Zone selection (user spec 2026-10-11: "si no ha seleccionado una
          // zona se queda apagado; al seleccionar se enciende animado"):
          // with the zone layer ON and the driver OFFLINE, the GO reads
          // dimmed until they tap their city on the map.
          final selectedZoneOff = _selectedZoneName != null &&
              ZoneService.demand[_selectedZoneName]?.off == true;
          final dimmed = FeatureFlags.zonesMapEnabled &&
              (_selectedZoneName == null || selectedZoneOff) &&
              !_driverOnline;
          final topColor = dimmed
              ? Color.lerp(topColor0, const Color(0xFF6B6B70), 0.55)!
              : topColor0;
          final botColor = dimmed
              ? Color.lerp(goldBot, const Color(0xFF4A4A4F), 0.55)!
              : goldBot;
          // Face gate paint (2026-10-23 owner spec, REVISED same day):
          // verify = GREY and static like pending review ("en vez de rojo
          // será gris y no tendrá animación — la animación es solo para GO
          // ONLINE") — the gold stays for the normal state. The dispatch GO
          // switch paints the same dead grey and outranks both.
          final topPaint = resting
              ? const Color(0xFF6B6B70)
              : _goOnlineDisabled
                  ? const Color(0xFF6B6B70)
                  : faceState != 0
                      ? const Color(0xFF6B6B70)
                      : topColor;
          final botPaint = resting
              ? const Color(0xFF4A4A4F)
              : _goOnlineDisabled
                  ? const Color(0xFF4A4A4F)
                  : faceState != 0
                      ? const Color(0xFF4A4A4F)
                      : botColor;
          const glowColor = Color(0xFFE8C547);

          // Black on gold — muted while dimmed.
          // Letras BLANCAS sobre el dorado (2026-10-15: "las letras de GO
          // ONLINE deben estar en blanco").
          final fgColor =
              dimmed ? Colors.white54 : Colors.white;

          // The ignite pop when a zone selection lights the GO up. Fired
          // ONLY in the normal state — a face-gated or dispatch-paused
          // button is static by owner spec (2026-10-23).
          final igniteScale = faceState == 0 && !_goOnlineDisabled
              ? (_goIgniteAnim?.value ?? 1.0)
              : 1.0;

          // The heartbeat lives on the OPEN PILL only (2026-10-14 user spec:
          // with the sheet closed and the button just "GO", it carries the
          // radar of old instead) — a soft 1.0→1.04 throb while lit; a
          // dimmed button (no zone picked) stays still.
          const throb = 1.0; // el latido murió 2026-10-15; el pop de ignite queda

          // The pill label (user spec 2026-10-14: "no debe decir verify
          // first, debe decir selecciona una zona, y al seleccionarla
          // transiciona fluido a GO ONLINE"). VERIFY FIRST is dead: with no
          // zone picked the button names the task; verification and docs
          // keep gating the TAP (they route to the fix), never the paint
          // (2026-10-11 spec).
          final pillLabel = resting
              ? '${S.of(context).restTitle} ${_fmtRest(restRemaining)}'
              : readyRecently
                  ? S.of(context).restReady
                  : _enteringOnline
                      ? 'GOING ONLINE...'
                      : faceState == 1
                          ? S.of(context).goVerify
                          : faceState == 2
                              ? S.of(context).faceReviewPending
                              : dimmed
                                  ? S.of(context).zoneSelectAction
                                  : !docsOk
                                      ? S.of(context).viewIssue
                                      : _goShowsResume
                                          ? S.of(context).resumeOnline
                                          : S.of(context).goOnline;

          return Transform.scale(
            scale: igniteScale * throb,
            child: ClipRRect(
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
                    // Slimmer at half width: the label needs the room.
                    horizontal: ui.lerpDouble(0, 16, morph)!,
                    vertical: ui.lerpDouble(0, 13, morph)!,
                  ),
                  decoration: BoxDecoration(
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
                            color: const Color(0xFF8A6A10).withValues(
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
                                          0.12, 0.3 + 0.15 * p, morph)! *
                                      (dimmed ? 0.3 : 1.0) *
                                      (faceState != 0 ? 0.25 : 1.0)),
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
                            colors: [topPaint, botPaint],
                          ),
                        ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    // Centrado SIEMPRE (user spec 2026-10-16: "centrado el
                    // Go online" — la pill larga como la foto 3 de Dash) —
                    // la alineación a la izquierda de 2026-10-14 murió. En el
                    // disco cerrado ya era centro: una sola regla.
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
                              color: Color.lerp(
                                  Colors.white.withValues(alpha: 0.10),
                                  Colors.black.withValues(alpha: 0.16),
                                  morph),
                              shape: BoxShape.circle,
                            ),
                            child: _enteringOnline
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: Colors.black87,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : !docsOk
                                    ? Icon(
                                        _hasExpiredDocs || _plateChangePending
                                            ? Icons.warning_amber_rounded
                                            : Icons.upload_file_rounded,
                                        color: fgColor,
                                        size: 16,
                                      )
                                    // Cruise logo next to "Go online" (user
                                    // specs 2026-10-13/14) — WHITE inside
                                    // the dark badge well ("el carrito
                                    // blanco"), never in the label ink.
                                    : ColorFiltered(
                                        colorFilter: ColorFilter.mode(
                                            Colors.white, BlendMode.srcIn),
                                        child: Image.asset(
                                          'assets/images/cruise_logo.png',
                                          width: 18,
                                          height: 18,
                                        ),
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
                          // Centrado en disco y en pill (misma spec
                          // 2026-10-16 que la fila de arriba).
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
                                  resting
                                      ? _fmtRest(restRemaining)
                                      : readyRecently
                                          ? S.of(context).restReady
                                          : _goShowsResume
                                              ? S.of(context).resumeOnline
                                              : 'GO',
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: fgColor,
                                    fontSize: ui.lerpDouble(
                                        _goShowsResume || readyRecently
                                            ? 15
                                            : 22,
                                        14,
                                        morph),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                            Opacity(
                              opacity: ((morph - 0.35) / 0.65).clamp(0.0, 1.0),
                              // Half-width pill + a long label ("SELECCIONA
                              // ZONA") — scale down, never clip.
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                // The fluid swap: picking a zone crossfades
                                // "Selecciona zona" into "GO ONLINE" instead
                                // of popping the string (same 2026-10-14
                                // spec; the ignite scale-pop fires on the
                                // same tap).
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 280),
                                  transitionBuilder: (child, anim) =>
                                      FadeTransition(
                                    opacity: anim,
                                    child: ScaleTransition(
                                      scale: anim.drive(Tween<double>(
                                          begin: 0.92, end: 1.0)),
                                      child: child,
                                    ),
                                  ),
                                  child: Text(
                                    pillLabel,
                                    key: ValueKey<String>(resting
                                        ? 'resting'
                                        : readyRecently
                                            ? 'ready'
                                            : pillLabel),
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: fgColor,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Brillo SOLO con el sheet abierto (user spec 2026-10-15:
                // "la animación brillante solo cuando el sheet esté
                // abierto"): una banda de luz barre la píldora; el disco
                // cerrado conserva su radar de siempre. Y SOLO en el estado
                // normal (owner spec 2026-10-23: la animación es del GO
                // ONLINE — verify/pending/paused son grises y quietos).
                if (_goGlossCtrl != null &&
                    !dimmed &&
                    morph > 0.5 &&
                    faceState == 0 &&
                    !resting &&
                    !_goOnlineDisabled)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: Builder(builder: (context) {
                          final g = _goGlossCtrl!.value * 1.7 - 0.35;
                          return Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Colors.white.withValues(alpha: 0.0),
                                  Colors.white.withValues(alpha: 0.22),
                                  Colors.white.withValues(alpha: 0.0),
                                ],
                                stops: [
                                  (g - 0.18).clamp(0.0, 1.0),
                                  g.clamp(0.0, 1.0),
                                  (g + 0.18).clamp(0.0, 1.0),
                                ],
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                // Radar sweep — SOLO en el disco cerrado (user spec
                // 2026-10-14: "cuando el sheet esté cerrado y el botón
                // solo diga GO, la animación que tenía antes"). El
                // pill abierto palpita. Y solo en el estado normal — el
                // verify/pending/paused gris no anima (2026-10-23).
                if (_goRadarCtrl != null &&
                    !dimmed &&
                    morph <= 0.5 &&
                    faceState == 0 &&
                    !resting &&
                    !_goOnlineDisabled)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _GoRadarPainter(
                          progress: _goRadarCtrl!.value,
                          // Ondas NEGRAS sobre el GO dorado.
                          color: const Color(0xFF0B0B0F),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          );
        },
      ),
    );
  }

  /// The GO-OFFLINE disc: red body with the GO button's radar waves in black
  /// (user spec 2026-10-11: "el botón de offline rojo con la misma animación
  /// del GO pero en vez de amarillo rojo, igual con ondas"). ONE look for
  /// both go-offline doors (expanded panel + the "Finding trips" sheet).
  Widget _offlineRadarDisc({double size = 62}) {
    final waves = _goRadarCtrl;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFE05555), Color(0xFF9E1B1B)],
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0x55CC3333),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
                BoxShadow(
                  color: Color(0x47000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
          if (waves != null)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipOval(
                  child: AnimatedBuilder(
                    animation: waves,
                    builder: (_, __) => CustomPaint(
                      painter: _GoRadarPainter(
                        progress: waves.value,
                        color: const Color(0xFF1A0505),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const Center(
            child: Icon(Icons.power_settings_new_rounded,
                color: Colors.white, size: 26),
          ),
        ],
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
  Widget _buildOfflinePanelContent(
      Color textMuted, EdgeInsets pad, double panelFrac) {
    final dc = DriverColors.of(context);
    final s = S.of(context);
    // Dos caras con crossfade (user spec 2026-10-16, estilo Dash): en el
    // reposo a MEDIO abrir domina el hero (headline + tarjeta de demanda);
    // al abrir completo toma el contenido normal de siempre.
    final heroT = (1 - (panelFrac - _kSheetRestFrac) / 0.3).clamp(0.0, 1.0);
    final fullT = ((panelFrac - 0.55) / 0.3).clamp(0.0, 1.0);
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
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
                        // The status line alternates smoothly (user spec
                        // 2026-10-14: "irá cambiando de forma smooth y
                        // animada") — "You're offline" ↔ "No estás en línea"
                        // on the 5 s status clock, sequential fade swap like
                        // the searching label.
                        Flexible(
                          child: _SequentialSwapLabel(
                            textKey: _statusLine,
                            builder: () => Text(
                              _statusLine == 0 ? s.youreOffline : s.notOnline,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: dc.text,
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // The consequence, under the status line (same spec:
                    // "abajo de ese texto dirá 'no recibirás ningún pedido
                    // de viaje'"). 2026-10-16 (user spec: "cuando el sheet
                    // esta por casi la mitad no sale el texto debajo del
                    // titulo"): el umbral era 0.6 y el reposo es 0.5 — la
                    // descripción nunca salía a medio abrir. Ahora aparece
                    // desde temprano en la apertura (> 0.25) y sigue
                    // colapsando con el sheet cerrado (el strip mantiene 52).
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      alignment: Alignment.topCenter,
                      child: panelFrac > 0.25
                          ? Padding(
                              padding:
                                  const EdgeInsets.only(left: 16, top: 3),
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 250),
                                opacity: panelFrac > 0.25 ? 1.0 : 0.0,
                                child: Text(
                                  s.offlineNoRideRequests,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    color: dc.textSecondary,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
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
        // ── Body — two faces crossfading on panelFrac: the Dash-style hero
        // owns the half-open rest; the scrollable list (Cruise Level,
        // earnings chart…) owns the fully-open sheet. ──
        Expanded(
          child: Stack(
            children: [
              Opacity(
                opacity: fullT,
                child: IgnorePointer(
                  ignoring: fullT < 1.0,
                  child: SingleChildScrollView(
            // Misma regla que el body online (user report 2026-09-27: "se
            // hace scroll cuando no he hecho scroll"): con el sheet cerrado
            // el gesto vertical es del SHEET (lo arrastra / lo cierra), no
            // de la lista — el contenido solo recibe scroll cuando el sheet
            // ya está prácticamente abierto.
            physics: panelFrac > 0.8
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
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
              ),
              if (heroT > 0)
                // Positioned.fill: el hero recibe TODA la altura del cuerpo
                // del sheet y reparte el espacio (spaceEvenly) — sin él el
                // contenido se apiñaba arriba y quedaba una banda muerta
                // entre la tarjeta y los botones (user spec 2026-10-16,
                // foto 1 vs foto 2).
                Positioned.fill(
                  child: Opacity(
                    opacity: heroT,
                    child: IgnorePointer(
                      ignoring: heroT < 1.0,
                      child: _buildOfflineHero(dc, s, pad),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// La cara Dash del sheet a medio abrir: headline + tarjeta de demanda
  /// (nivel + bonus). La ZONA SELECCIONADA tiene prioridad; el GPS es el
  /// fallback cuando no hay selección. Datos de ZoneService, polled 60 s.
  Widget _buildOfflineHero(DriverColors dc, S s, EdgeInsets pad) {
    final pos = _pos;
    final selectedId = _selectedZoneName;
    final sector = selectedId != null
        ? ZoneService.sectorById(selectedId)
        : pos != null
            ? ZoneService.sectorContaining(pos)
            : null;
    final d = sector != null ? ZoneService.demand[sector.id] : null;
    final off = d?.off ?? false;
    final level = off ? 0 : d?.level ?? 0;
    final bonus = d?.bonus ?? 0;
    final headline = level >= 3
        ? s.offlineHeroHeadlineHigh
        : level == 2
            ? s.offlineHeroHeadlineMedium
            : s.offlineHeroHeadlineIdle;
    final demandLabel = off
        ? s.offlineDemandZoneOff
        : level >= 3
            ? s.offlineDemandVeryBusy
            : level == 2
                ? s.offlineDemandBusy
                : level == 1
                    ? s.offlineDemandSlow
                    : s.offlineDemandNoRides;
    return Padding(
      // El hero va compacto ARRIBA (estilo Dash — foto 2 del spec
      // 2026-10-16-noche), y el padding de abajo libra la fila de botones
      // flotante (GO pill + calendario) para que la tarjeta jamás quede
      // cortada debajo de ella (foto 1 del mismo spec: la tarjeta se veía
      // cortada y el headline a media pantalla con el spaceEvenly).
      padding: EdgeInsets.fromLTRB(20, 18, 20, _kGoPillH + 26 + pad.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // El headline también cruza animado con el nivel (misma spec).
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            // Una sola línea SIEMPRE (user spec 2026-10-21: "que ese texto
            // se vea en horizontal, no que quede debajo la palabra ganar") —
            // FittedBox achica solo lo necesario para caber; nunca parte la
            // frase en dos líneas, con cualquier tamaño de pantalla/sistema.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                headline,
                key: ValueKey(headline),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: dc.text,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  height: 1.12,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: neuBox(radius: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.offlineDemandTitle,
                  style: TextStyle(
                    color: dc.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    // El nivel cambia ANIMADO (2026-10-17, owner spec: "se
                    // cambie de forma animada y fluida cuando las zonas
                    // cambien de estado") — crossfade+slide por nivel.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.35),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
                      child: Text(
                        demandLabel,
                        key: ValueKey(demandLabel),
                        style: TextStyle(
                          color: dc.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (bonus > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _offlineGold.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _offlineGold.withValues(alpha: 0.45)),
                        ),
                        child: Text(
                          '+\$${bonus.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _offlineGold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  sector?.name ?? s.offlineDemandYourArea,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dc.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
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
                    onTap: _openScheduledRides,
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

  /// Menú clásico de pantalla completa, empujado con una ruta opaca que
  /// entra desde la izquierda. El mapa sigue montado debajo y se reclama al
  /// volver solo si otra pantalla tomó su superficie.
  Future<void> _openDriverMenu() async {
    HapticService.selectionClick();
    ApiService.logClientEvent('menu_classic', 'tap left route');
    if (_menuRouteOpen) return;
    _menuRouteOpen = true;
    try {
      await Navigator.of(context)
          .push(slideFromLeftRoute(const DriverMenuScreen()));
    } finally {
      _menuRouteOpen = false;
      if (mounted) unawaited(_remountMapSurface());
    }
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
      // Ease out, softer than before (spec 2026-10-10: "más fluido") — quick
      // at birth, drifting by the time it fades. A ring travelling at
      // constant speed reads as mechanical.
      final e = 1.0 - math.pow(1.0 - t, 1.8).toDouble();
      final r = maxR * (inner + (outer - inner) * e);

      // Fade in over the first sliver so a ring never pops into existence
      // on top of the word, then fade out squared so it reads as leaving
      // rather than as being switched off.
      final fadeIn = (t / 0.12).clamp(0.0, 1.0);
      final a = fadeIn * (1.0 - e) * (1.0 - e) * 0.5;
      if (a <= 0.01) continue;

      final w = 1.8 - 0.9 * e;
      // Soft pass first: a blurred halo under the crisp ring is what makes
      // it read as a WAVE rolling outward, not a hard growing circle
      // (user spec 2026-10-10: "un poco de sombra, tipo ondas no aros").
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w + 2.4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
          ..color = color.withValues(alpha: a * 0.5),
      );
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          // Thinning as it travels: a ring keeping its weight while it
          // grows looks like it is being drawn, not like it is spreading.
          ..strokeWidth = w
          ..color = color.withValues(alpha: a),
      );
    }
  }

  @override
  bool shouldRepaint(_GoRadarPainter old) =>
      old.progress != progress || old.color != color;
}


/// The calendar button riding to the RIGHT of the open GO pill (user spec
/// 2026-10-16: "el lado derecho donde esta el bolante colocaras igualmente
/// el calendario") — opens the scheduled-rides map. Same dark disc with the
/// gold rim the wheel badge had, but this one owns its tap.
class _GoScheduleButton extends StatelessWidget {
  const _GoScheduleButton({
    required this.onTap,
    required this.count,
    required this.bounceAnimation,
  });

  final VoidCallback onTap;
  final int count;
  final Animation<double>? bounceAnimation;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF141420),
              border: Border.all(color: _offlineGold.withValues(alpha: 0.4)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Center(
              child: Icon(
                Icons.calendar_month_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -4,
              right: -4,
              child: ScaleTransition(
                scale: bounceAnimation ??
                    const AlwaysStoppedAnimation<double>(1.0),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Container(
                    key: ValueKey(count),
                    constraints: const BoxConstraints(minWidth: 20),
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _offlineGold,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.black, width: 1.5),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
