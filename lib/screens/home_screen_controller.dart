part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — data, navigation, shortcuts, scheduling
// ════════════════════════════════════════════════════════════

extension _HomeScreenController on _HomeScreenState {

  // --- Service Zone support ---

  /// Fired from initState. It used to subscribe on the spot with no auth
  /// gate and no onError — the last unguarded `snapshots().listen` left in
  /// the app. `config/serviceZones` is `allow read: if isAuthenticated()`
  /// and Firebase anonymous auth is DISABLED in the console, so every rider
  /// whose custom-token session had not been minted yet got
  /// `[cloud_firestore/permission-denied]` thrown into the zone with no
  /// handler to receive it → Crashlytics. That is why this group spans
  /// 1.0.0 through 1.0.9 and keeps recurring. Now the session is
  /// established *before* the listen exists, and the listen carries its own
  /// error path, so there is no unhandled route left for the rejection.
  ///
  /// [allowRetry] caps recovery at a single re-subscribe: a session that
  /// exists and is still denied means the RULES reject this path, and
  /// re-subscribing on every error is how the verification stream turned
  /// one denial into an endless loop of Crashlytics events.
  void _listenServiceZones({bool allowRetry = true}) async {
    if (!FirebaseAuthRecovery.hasSession) {
      final ok = await FirebaseAuthRecovery.ensureSignedIn();
      if (!mounted) return;
      if (!ok) {
        // Wait for a session rather than giving up on this screen.
        //
        // `false` here does NOT mean "this rider can never sign in". It is
        // also what ensureSignedIn() answers the instant ANOTHER caller
        // attempted within its 30-second cooldown, and at startup chat, the
        // GPS mirror and the trip listener all race for exactly that — so a
        // plain `return` left service zones unsubscribed for the entire
        // session and the state gate silently stuck on its permissive
        // default. One-shot watch, cancelled the moment it fires and in
        // dispose, so it cannot outlive the screen or stack up.
        debugPrint('[Zones] no Firebase session yet — waiting for one');
        _zonesAuthSub?.cancel();
        _zonesAuthSub =
            FirebaseAuth.instance.authStateChanges().listen((fbUser) {
          if (fbUser == null || !mounted) return;
          _zonesAuthSub?.cancel();
          _zonesAuthSub = null;
          _listenServiceZones(allowRetry: allowRetry);
        });
        return;
      }
    }
    _zonesSub?.cancel();
    _zonesSub = FirebaseFirestore.instance
        .collection('config')
        .doc('serviceZones')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          final states = (snap.data()?['activeStates'] as List<dynamic>? ?? [])
              .map((s) => s.toString())
              .toSet();
          _setState(() {
            _activeServiceStates = states;
            // If no states configured → allow all (feature not yet set up)
            if (states.isEmpty) {
              _serviceZoneActive = true;
            } else if (_userStateName.isNotEmpty) {
              _serviceZoneActive = states.contains(_userStateName);
            }
          });
        }, onError: (e) async {
          debugPrint('[Zones] Firestore error: $e');
          // A Firestore listen is terminal once it errors — it never emits
          // again. Drop the handle so dispose isn't cancelling a corpse and
          // so the retry below starts from a clean subscription.
          _zonesSub?.cancel();
          _zonesSub = null;
          if (!allowRetry) return;
          // Only a missing session is worth retrying; anything else (rules
          // change, backend outage) resolves nothing by re-listening, and
          // the gate stays open meanwhile.
          if (!e.toString().contains('permission-denied')) return;
          final ok = await FirebaseAuthRecovery.ensureSignedIn();
          if (!mounted || !ok) return;
          _listenServiceZones(allowRetry: false);
        });
  }

  /// Listen for rider verification approval from Dispatch.
  /// When approved, unlock the app and show a notification.
  void _listenVerificationStatus() async {
    final user = await UserSession.getUser();
    final userId = user?['userId'];
    if (userId == null || userId.isEmpty) return;
    final userIdInt = int.tryParse(userId) ?? 0;
    if (userIdInt <= 0) return;

    // Load cached verification status
    final cachedStatus = user?['verificationStatus'] ?? '';
    if (mounted && cachedStatus.isNotEmpty) {
      _setState(() => _verificationStatus = cachedStatus);
    }

    // Ensure Firebase Auth
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuthRecovery.ensureSignedIn();
      }
    } catch (_) {
      return;
    }

    // NOTE: the retry count is deliberately NOT reset here. The denied
    // handler below re-enters this method for its single recovery attempt;
    // resetting on every subscription turned the one-attempt cap into an
    // infinite 1 s re-subscribe loop (each denied error logging its own
    // Crashlytics event — caught live in the browser on 2026-08-04).
    // Transient-error recovery resets it in the data callback instead.
    _verificationSub?.cancel();
    _verificationSub = FirebaseFirestore.instance
        .collection('verifications')
        .where('userId', isEqualTo: userIdInt)
        .snapshots()
        .listen((snapshot) async {
      // Live data — the stream genuinely works; re-arm the error budget.
      _verificationRetryCount = 0;
      if (!mounted) return;

      // Decided over the WHOLE snapshot, never doc by doc. The query is not
      // limited to one document, so a rider who was rejected and then
      // approved keeps both, and Firestore does not promise an order: the
      // stale rejected one could be read first, arm the flag, and hand the
      // approved one a celebration on every single sign-in — the exact bug
      // this is here to prevent.
      final anyApproved = snapshot.docs.any((d) {
        final data = d.data();
        final status = data['status'] as String? ??
            data['verificationStatus'] as String? ??
            '';
        return status == 'approved' ||
            data['isVerified'] == true ||
            data['isApproved'] == true;
      });
      if (!anyApproved) _sawUnapprovedThisSession = true;

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status = data['status'] as String? ??
            data['verificationStatus'] as String? ??
            '';
        final isApproved = status == 'approved' ||
            data['isVerified'] == true ||
            data['isApproved'] == true;

        if (isApproved && !_isVerified) {
          await LocalDataService.setIdentityVerified('license');
          await UserSession.updateField('isVerified', 'true');
          await UserSession.updateField('verificationStatus', 'approved');

          // Update profile photo from Firestore
          final photoUrl = data['profilePhotoUrl'] as String? ??
              data['selfieUrl'] as String?;
          if (photoUrl != null && photoUrl.isNotEmpty) {
            await UserSession.updateField('photo', photoUrl);
          }

          if (!mounted) return;

          // Approval notification is sent via FCM push from backend.
          // No local notification needed — the OS shows the push when app
          // is backgrounded, and the approval dialog below handles in-app UX.

          _setState(() {
            _isVerified = true;
            _verificationStatus = 'approved';
          });

          // Only celebrate an approval that happened while they watched.
          //
          // Arriving already approved is not news — it is every sign-in of
          // every verified rider, and it was being congratulated as if it
          // had just happened.
          if (_sawUnapprovedThisSession) _showApprovalDialog();
          return;
        } else if (status == 'pending') {
          if (mounted) {
            _setState(() => _verificationStatus = 'pending');
          }
        } else if (status == 'rejected') {
          if (mounted) {
            _setState(() => _verificationStatus = 'rejected');
          }
        }
      }
    }, onError: (e) async {
      debugPrint('[Verification] Firestream error: $e');
      // permission-denied is NOT transient: without a Firebase session the
      // rules reject every attempt identically, and the old backoff loop
      // re-subscribed forever — each denied subscription logging its own
      // Crashlytics event (the 136-crash group at the top of the
      // dashboard). Try to establish a session ONCE; if there is none to
      // be had, stop — _checkBackendVerification() already answers the
      // same question over HTTP.
      final denied = e.toString().contains('permission-denied');
      if (denied) {
        _verificationRetryCount++;
        // One recovery attempt, ever: a session that exists but is still
        // denied means the RULES reject this path — re-subscribing again
        // would loop at 1 s forever.
        if (_verificationRetryCount > 1) {
          debugPrint('[Verification] still denied with a session — rules '
              'block this path; stream off, backend polling covers it');
          return;
        }
        final ok = await FirebaseAuthRecovery.ensureSignedIn();
        if (!mounted) return;
        if (!ok) {
          debugPrint('[Verification] no Firebase session — stream off, '
              'backend polling covers verification status');
          return;
        }
        // Fresh session: ONE re-subscribe. 3 s, not 1 — the web SDK can
        // open the listen channel before the auth token is attached on a
        // cold boot, and re-subscribing inside that window burns the only
        // retry on the same race. (Verified 2026-08-04: the identical
        // query passes over REST with the same uid while the SDK listen
        // reports denied at boot.)
        _verificationRetryTimer?.cancel();
        _verificationRetryTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) _listenVerificationStatus();
        });
        return;
      }
      // Transient errors (network blips) keep the old backoff.
      _verificationRetryCount++;
      final delay = Duration(seconds: math.min(30, 2 << _verificationRetryCount));
      debugPrint('[Verification] Retrying in ${delay.inSeconds}s (attempt $_verificationRetryCount)');
      _verificationRetryTimer?.cancel();
      _verificationRetryTimer = Timer(delay, () {
        if (mounted) _listenVerificationStatus();
      });
    });
  }

  /// Check backend for verification status using dashboard (single call).
  /// Handles reinstall/new device where SharedPreferences is empty but the
  /// user was already approved via dispatch.
  Future<void> _checkBackendVerification() async {
    try {
      final dashboard = await ApiService.getDashboard();
      if (dashboard == null || !mounted) return;
      // Definitive answer received — the hero may now show the blocked
      // state if the account is genuinely unverified.
      if (!_verificationResolved) {
        _setState(() => _verificationResolved = true);
      }
      
      // Check verification status
      final verification = dashboard['verification'] as Map<String, dynamic>?;
      final backendVerified = verification?['is_verified'] == true;
      final backendStatus = (verification?['status'] ?? '').toString();
      if (backendVerified || backendStatus == 'approved') {
        await LocalDataService.setIdentityVerified('license');
        await UserSession.updateField('isVerified', 'true');
        await UserSession.updateField('verificationStatus', 'approved');
        if (mounted) {
          _setState(() {
            _isVerified = true;
            _verificationStatus = 'approved';
          });
        }
      }
      
      // Check account status in same call
      final account = dashboard['account'] as Map<String, dynamic>?;
      final accountStatus = (account?['status'] ?? 'active').toString();
      if (accountStatus == 'blocked' || accountStatus == 'deleted') {
        await UserSession.logout();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const WelcomeScreen()),
          (_) => false,
        );
      } else if (accountStatus == 'deactivated') {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const AccountDeactivatedScreen()),
          (_) => false,
        );
      }
      
      // Check active trip in same call
      final activeTrip = dashboard['active_trip'] as Map<String, dynamic>?;
      if (activeTrip != null && mounted) {
        _handleActiveTripFromDashboard(activeTrip);
      }
    } catch (_) {}
  }
  
  void _handleActiveTripFromDashboard(Map<String, dynamic> trip) {
    // If there's an active trip, the SSE stream will handle real-time updates
    // But we can pre-populate UI state here if needed
  }

  void _showApprovalDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1E24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        contentPadding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE8C547), Color(0xFFFBE47A)],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Colors.black,
                size: 40,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              S.of(ctx).accountApproved,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              S.of(ctx).accountApprovedDesc,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8C547),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  S.of(ctx).gotIt,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Refresh GPS in background after using pre-loaded position
  void _refreshGpsInBackground() {
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    ).then((pos) {
      if (!mounted) return;
      _currentLatLng = LatLng(pos.latitude, pos.longitude);
      // Glide, don't snap: the preloaded position already rendered a dot
      // and the accurate fix is usually metres away — snapping teleported it.
      _feedHomeDot(_currentLatLng!.latitude, _currentLatLng!.longitude);
      _recenterHomeMiniMap();
    }).catchError((e) {
      if (kDebugMode) debugPrint('[GPS] getCurrentPosition error: $e');
    });
    // Start continuous location stream
    _lastGpsFixAt = DateTime.now();
    _locationSub?.cancel();
    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0, // Every GPS fix
      ),
    ).listen(
      (Position p) {
        if (!mounted) return;
        _lastGpsFixAt = DateTime.now();
        final ll = LatLng(p.latitude, p.longitude);
        _currentLatLng = ll;
        // Feed the mini map dot + throttled follow camera (same hooks as
        // the listener in _fetchCurrentLocation — the preloaded startup
        // path runs its stream here).
        _feedHomeDot(ll.latitude, ll.longitude);
        _recenterHomeMiniMap();
      },
      onError: (e) {
        if (kDebugMode) debugPrint('[GPS] Position stream error: $e');
      },
    );
  }

  /// Start the watchdog that keeps the GPS stream healthy.
  /// Call from initState and again on app resume.
  void _startLocationWatchdogs() {
    // Start the grace period now so the watchdog doesn't fire before the
    // first GPS fix has had a chance to arrive.
    _lastGpsFixAt = DateTime.now();

    _gpsStreamWatchdog?.cancel();
    _gpsStreamWatchdog = Timer.periodic(const Duration(seconds: _gpsWatchdogSec), (_) {
      _checkGpsStreamHealth();
    });
  }

  /// Stop the GPS watchdog. Call from dispose.
  void _stopLocationWatchdogs() {
    _gpsStreamWatchdog?.cancel();
    _gpsStreamWatchdog = null;
  }

  /// If no GPS fix has arrived recently, restart the position stream.
  /// Geolocator streams can die silently on some Android/iOS devices.
  /// Also retries the initial fetch when no stream ever started (services
  /// disabled or permission denied at launch) — throttled so it doesn't
  /// spam the system permission dialog.
  void _checkGpsStreamHealth() {
    if (!mounted || _fetchingLocation) return;
    if (_locationSub == null) {
      // Never got a stream and no position at all — retry the initial
      // fetch at most every 30s.
      // Nunca arrancó el stream: reintenta la obtención inicial (máx. 30s).
      if (_currentLatLng != null) return;
      final now = DateTime.now();
      if (_lastGpsRetryAt != null &&
          now.difference(_lastGpsRetryAt!).inSeconds < 30) {
        return;
      }
      _lastGpsRetryAt = now;
      _retryInitialLocation();
      return;
    }
    final elapsed = DateTime.now().difference(_lastGpsFixAt).inSeconds;
    if (elapsed < _gpsWatchdogSec) return;
    _fetchCurrentLocation();
  }

  /// Throttled recovery when the initial location fetch failed (services
  /// disabled or permission denied). Re-checks service status and only
  /// restarts the fetch when permission is ALREADY granted — it never
  /// pops the system permission dialog itself.
  /// Recuperación sin diálogo de permisos: solo reintenta si ya hay permiso.
  Future<void> _retryInitialLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      // Permission already granted — seed from the last known fix for an
      // instant dot, then run the full fetch (starts the stream).
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null && mounted && _currentLatLng == null) {
        _setState(() {
          _currentLatLng = LatLng(last.latitude, last.longitude);
        });
        _feedHomeDot(last.latitude, last.longitude);
      }
      _fetchCurrentLocation();
    } catch (_) {
      // Location still unavailable — the next watchdog tick retries.
    }
  }

  // ─── Ride progress countdown ───

  void _startCountdown(int etaMinutes) {
    _totalSeconds = etaMinutes * 60;
    _remainingSeconds = _totalSeconds;
    _tripStartTime = DateTime.now();
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        if (_remainingSeconds <= 0) {
          _countdownTimer?.cancel();
          _loadSavedData(); // refresh active ride state → may unlock panel
          return;
        }
        _setState(() {
          _remainingSeconds--;
        });
      },
    );

    // Prepare route progress math + start driver tracking. There is no map
    // on home anymore — this only feeds the hero card progress bar.
    final ride = _activeRide;
    if (ride != null) {
      _prepareRouteProgress(ride);
      _listenToDriverLocation();
    }

    // Ensure fade controller is at full opacity for active ride
    _rideFadeCtrl.value = 1.0;
  }

  // ─── Driver location tracking for active trip ───

  void _listenToDriverLocation() {
    if (_activeRide == null) return;

    // Cancel existing subscriptions and bump generation to discard stale callbacks
    _driverLocationSub?.cancel();
    _tripDocSub?.cancel();
    _tripStatusSub?.cancel();
    _trackedDriverId = null;
    final gen = ++_driverLocationGeneration;

    // Listen to driver location from Firestore (ride document has driver_id)
    final tripId = _activeRide!.firestoreTripId;
    if (tripId == null) return;

    // Get driver ID from trip data first, then subscribe to their location
    _tripDocSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .snapshots()
        .listen((tripSnap) async {
      if (!mounted || gen != _driverLocationGeneration) return;

      final driverId = tripSnap.data()?['driver_id']?.toString();
      if (driverId == null) return;
      if (_trackedDriverId == driverId && _driverLocationSub != null) return;
      _trackedDriverId = driverId;

      // Subscribe to this driver's location in RTDB
      _driverLocationSub?.cancel();
      _driverLocationSub = FirebaseDatabase.instance
          .ref('driver_locations/$driverId')
          .onValue
          .listen((event) {
        if (!mounted || gen != _driverLocationGeneration) return;

        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data == null) return;

        final newLat = (data['lat'] as num?)?.toDouble() ?? 0.0;
        final newLng = (data['lng'] as num?)?.toDouble() ?? 0.0;

        // Recompute hero-card route progress on every RTDB event (~1/sec).
        // No 60fps interpolation ticker anymore — there is no map to animate.
        _setState(() => _updateRouteProgress(LatLng(newLat, newLng)));
      }, onError: (e) {
        debugPrint('[DriverLoc] RTDB error: $e');
      });
    }, onError: (e) {
      debugPrint('[DriverLoc] Firestore trip error: $e');
    });

    // Also listen for trip completion
    _tripStatusSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .snapshots()
        .listen((tripSnap) {
      if (!mounted || gen != _driverLocationGeneration) return;

      final status = tripSnap.data()?['status']?.toString() ?? '';
      if (status == 'completed' || status == 'cancelled' || status == 'canceled') {
        _onTripCompleted();
      }
    }, onError: (e) {
      debugPrint('[DriverLoc] Firestore status error: $e');
    });
  }

  /// Cache route points + total distance for the hero card progress bar.
  /// Pure math — the home no longer renders a map. Called once per ride
  /// from [_startCountdown]; RTDB driver updates then feed
  /// [_updateRouteProgress].
  void _prepareRouteProgress(ActiveRideInfo ride) {
    if (ride.routePoints.isEmpty) return;

    _routeLatLngs = ride.routePoints.map((p) => LatLng(p[0], p[1])).toList();

    // Cap route endpoints to exact pin coordinates
    if (_routeLatLngs.length >= 2) {
      _routeLatLngs[0] = LatLng(ride.pickupLat, ride.pickupLng);
      _routeLatLngs[_routeLatLngs.length - 1] = LatLng(ride.dropoffLat, ride.dropoffLng);
    }

    // Cache the total route length once — recomputing it on every RTDB
    // event was wasted work (audit perf finding M7).
    double total = 0;
    for (int i = 0; i < _routeLatLngs.length - 1; i++) {
      total += _haversine(_routeLatLngs[i], _routeLatLngs[i + 1]);
    }
    _routeTotalDist = total;
  }

  /// Compute how far along the route the driver is (0.0→1.0).
  void _updateRouteProgress(LatLng driverPos) {
    if (_routeLatLngs.length < 2 || _routeTotalDist <= 0) return;

    double closestDist = double.infinity;
    double distAtClosest = 0;
    double runningDist = 0;

    for (int i = 0; i < _routeLatLngs.length - 1; i++) {
      final a = _routeLatLngs[i];
      final b = _routeLatLngs[i + 1];
      final segLen = _haversine(a, b);

      // Project driver onto this segment
      final proj = _projectOntoSegment(driverPos, a, b);
      final dist = _haversine(driverPos, proj);
      if (dist < closestDist) {
        closestDist = dist;
        distAtClosest = runningDist + _haversine(a, proj);
      }
      runningDist += segLen;
    }

    final newProgress = (distAtClosest / _routeTotalDist).clamp(0.0, 1.0);
    // Only update if moving forward (prevent backward jumps)
    if (newProgress >= _routeProgress) {
      _routeProgress = newProgress;
    }
  }

  /// Haversine distance in meters.
  static double _haversine(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sLat = math.sin(dLat / 2);
    final sLng = math.sin(dLng / 2);
    final h = sLat * sLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sLng * sLng;
    return 2 * R * math.asin(math.sqrt(h));
  }

  /// Project point P onto segment AB, clamped to [A, B].
  static LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0) return a;
    final t = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        (dx * dx + dy * dy);
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  void _onTripCompleted() {
    if (!mounted) return;

    // Cancel ALL trip-related subscriptions and timers up-front so a
    // late RTDB / Firestore event can't re-render route/driver state
    // after the reset starts.
    _driverLocationSub?.cancel();
    _driverLocationSub = null;
    _tripDocSub?.cancel();
    _tripDocSub = null;
    _tripStatusSub?.cancel();
    _tripStatusSub = null;
    _trackedDriverId = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;

    // Fade out ride UI, then reset state
    _rideFadeCtrl.reverse().then((_) async {
      if (!mounted) return;

      // Drop the cached active ride from local storage so the next
      // _loadSavedData() can't resurrect it. This is the path that
      // matters when dispatch cancels remotely while the rider is on
      // home — without this the next entry into _openSearchThenRide
      // would mis-route to _resumeActiveRide() on a dead trip.
      try {
        await LocalDataService.clearActiveRide();
      } catch (_) {}

      if (!mounted) return;
      _setState(() {
        _activeRide = null;
        _pendingSearchTripId = null;
        _didAutoResumeRide = false;
        _routeProgress = 0.0;
        _routeLatLngs = [];
        _routeTotalDist = 0.0;
      });

      // Fade in normal content
      _rideFadeCtrl.forward();

      // Refresh saved data to update UI (reads fresh state — _activeRide
      // will be null since we just cleared the cache).
      _loadSavedData();
    });
  }

  void _showPlaceOptions(String label, String address, VoidCallback editTap) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              address,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Edit Address
            _placeOptionBtn(Icons.edit_rounded, S.of(context).editAddressLabel, () {
              Navigator.pop(ctx);
              editTap();
            }),
            const SizedBox(height: 8),
            // Request a Ride
            _placeOptionBtn(Icons.directions_car_rounded, S.of(context).requestRideLabel, () {
              Navigator.pop(ctx);
              _requestRideToAddress(address);
            }, highlight: true),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// Open the search screen (photo 3) directly, then push RideRequestScreen
  /// with the pickup/dropoff results pre-filled.
  Future<void> _openSearchThenRide({String? rideId, bool applyPromo = false}) async {
    // Re-entry guard. If a previous tap already opened the search /
    // ride_request stack, ignore the new tap until the first finishes.
    // Without this, double-taps on a tier card (or fast tap-cancel-tap
    // sequences) could push two PickupDropoffSearchScreens or skip
    // straight to ride_request before the first finished disposing.
    if (_openingRideFlow) return;

    // Refresh cached state before deciding what to do — _activeRide can
    // be stale in memory after a back-without-Request-Ride sequence,
    // which made the next tap mis-route to _resumeActiveRide() and
    // either skip the dropoff search or jump straight into Choose a
    // vehicle on a half-empty trip.
    final freshActive = await LocalDataService.getActiveRide();
    if (mounted && freshActive != _activeRide) {
      _setState(() => _activeRide = freshActive);
    }
    if (_activeRide != null) {
      _resumeActiveRide();
      return;
    }
    if (!await _ensureVerified()) return;
    if (!mounted) return;

    _openingRideFlow = true;
    try {
      final result = await Navigator.of(context).push<Map<String, dynamic>>(
        // Fluid slide-up + fade (same transition as the tracking screen and
        // the address sheet) instead of the shared-axis zoom.
        slideUpFadeRoute(
          PickupDropoffSearchScreen(
            initialPickupLat: _currentLatLng?.latitude,
            initialPickupLng: _currentLatLng?.longitude,
          ),
        ),
      );

      if (result == null || !mounted) return;

      final pickupDetails = result['pickup'] as PlaceDetails?;
      final dropoffDetails = result['dropoff'] as PlaceDetails?;
      final pickupLabel = result['pickupLabel'] as String? ?? '';
      final dropoffLabel = result['dropoffLabel'] as String? ?? '';

      if (dropoffDetails == null) return;

      // Use current location as pickup if search didn't provide one
      final effectivePickup = pickupDetails ?? (
        _currentLatLng != null
            ? PlaceDetails(
                address: pickupLabel.isNotEmpty ? pickupLabel : 'Current location',
                lat: _currentLatLng!.latitude,
                lng: _currentLatLng!.longitude,
              )
            : null
      );

      final effectiveDropoffLabel = dropoffLabel.isNotEmpty
          ? dropoffLabel
          : dropoffDetails.address;

      // Pre-fetch route — start immediately, pass to RideRequestScreen
      // Don't wait here: navigate instantly so the transition feels seamless
      Future<RouteResult?>? routeFuture;
      if (effectivePickup != null) {
        final origin = LatLng(effectivePickup.lat, effectivePickup.lng);
        final dest = LatLng(dropoffDetails.lat, dropoffDetails.lng);
        routeFuture = DirectionsService(ApiKeys.webServices)
            .getRoute(origin: origin, destination: dest);
      }

      // Quick check — if route already completed (cached/fast), use it
      RouteResult? preloadedRoute;
      if (routeFuture != null) {
        preloadedRoute = await routeFuture.timeout(
          const Duration(milliseconds: 200),
          onTimeout: () => null,
        );
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        slideUpFadeRoute(
          RideRequestScreen(
            initialPickupDetails: effectivePickup,
            initialDropoffDetails: dropoffDetails,
            initialPickupLabel: pickupLabel,
            initialDropoffLabel: effectiveDropoffLabel,
            initialDropoffAddress: effectiveDropoffLabel,
            initialRideId: rideId,
            preloadedRoute: preloadedRoute,
            applyPromo: applyPromo,
          ),
        ),
      );
      if (mounted) _loadSavedData();
    } finally {
      // Always release the guard — covers early returns, back-pop,
      // unmount, and uncaught navigator errors. Without this, a single
      // partial flow could permanently lock the rider out of opening
      // the search again.
      if (mounted) _openingRideFlow = false;
    }
  }

  /// The one entry into scheduling (dock tab + hero row). Opens the hub;
  /// the hub's own button drives the datetime page and the shared booking
  /// continuation (schedule_flow_entry.dart). The legacy sheet chain was
  /// retired with the hub (2026-08-22).
  Future<void> _openScheduleSheet() async {
    // Same gate the old sheet had: an unapproved rider never sees the
    // booking flow — the hub's gate lives at its entry, not inside it.
    if (!await _ensureVerified()) return;
    if (!mounted) return;
    Navigator.of(context).push(slideUpFadeRoute(const ScheduleHubScreen()));
  }

  void _resumeActiveRide() {
    // Idempotency guard: both this path (local-cache resume) and
    // _checkBackendActiveTrip (backend resume) can fire in parallel
    // during home screen init. Without this guard a slow backend call
    // that returns after the local cache has already pushed the tracking
    // screen would push a SECOND tracking screen on top — the duplicate
    // the user reported.
    if (_didAutoResumeRide) {
      debugPrint('[HomeScreen] _resumeActiveRide skipped — already auto-resumed');
      return;
    }
    _didAutoResumeRide = true;
    final ride = _activeRide;
    if (ride == null) {
      _didAutoResumeRide = false; // nothing to resume, allow retry
      return;
    }
    // Map persisted phase to initialStatus so the tracking controller
    // starts at the correct phase even before Firestore delivers an update.
    String? resumeStatus;
    switch (ride.phase) {
      case 'onTrip':
      case 'nearDestination':
        resumeStatus = 'in_trip';
      case 'arrived':
        resumeStatus = 'arrived';
      default:
        resumeStatus = null;
    }
    Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: LatLng(ride.pickupLat, ride.pickupLng),
          dropoffLatLng: LatLng(ride.dropoffLat, ride.dropoffLng),
          routePoints: ride.routePoints.map((p) => LatLng(p[0], p[1])).toList(),
          driverName: ride.driverName,
          driverRating: ride.driverRating,
          vehicleMake: ride.vehicleMake,
          vehicleModel: ride.vehicleModel,
          vehicleColor: ride.vehicleColor,
          vehiclePlate: ride.vehiclePlate,
          vehicleYear: ride.vehicleYear,
          rideName: ride.rideName,
          price: ride.price,
          pickupLabel: ride.pickupLabel,
          dropoffLabel: ride.dropoffLabel,
          tripId: ride.tripId,
          firestoreTripId: ride.firestoreTripId,
          driverPhotoUrl: ride.driverPhotoUrl,
          driverId: ride.driverId,
          initialStatus: resumeStatus,
          onTripComplete: () {
            LocalDataService.clearActiveRide();
            Navigator.of(context).pop();
            _loadSavedData();
          },
        ),
      ),
    );
  }

  /// Opens the scheduled ride's live state: if the trip is already active
  /// (en route / arrived / in trip), navigates to RiderTrackingScreen at the
  /// current phase. Otherwise falls back to the schedule hub (the rider's
  /// scheduled-rides list screen was retired with the hub, 2026-08-22).
  Future<void> _openScheduledRideLive() async {
    final ride = _nextScheduledRide;
    if (ride == null) {
      await Navigator.of(context).push(
        slideFromRightRoute(const ScheduleHubScreen()),
      );
      _loadSavedData();
      return;
    }

    // Fetch fresh trip status from backend
    try {
      final tripId = ride['id'] as int?;
      if (tripId != null) {
        final fresh = await ApiService.getTrip(tripId);
        if (mounted) {
          final status = (fresh['status'] ?? '').toString().toLowerCase();
          // If trip is actively in progress, open tracking screen
          const activeStatuses = {
            'accepted', 'en_route', 'en_route_to_pickup',
            'arriving', 'arrived', 'in_trip', 'in_progress',
            'near_destination',
          };
          if (activeStatuses.contains(status) && fresh['driver_id'] != null) {
            final pickupLat = (fresh['pickup_lat'] as num?)?.toDouble();
            final pickupLng = (fresh['pickup_lng'] as num?)?.toDouble();
            final dropoffLat = (fresh['dropoff_lat'] as num?)?.toDouble();
            final dropoffLng = (fresh['dropoff_lng'] as num?)?.toDouble();
            if (pickupLat != null && pickupLng != null &&
                dropoffLat != null && dropoffLng != null) {
              Navigator.of(context).push(
                slideUpFadeRoute(
                  RiderTrackingScreen(
                    pickupLatLng: LatLng(pickupLat, pickupLng),
                    dropoffLatLng: LatLng(dropoffLat, dropoffLng),
                    driverName: (fresh['driver_name'] ?? 'Driver').toString(),
                    driverPhone: (fresh['driver_phone'] ?? '').toString().isNotEmpty
                        ? (fresh['driver_phone']).toString()
                        : null,
                    driverRating: (fresh['driver_rating'] as num?)?.toDouble() ?? 4.9,
                    vehicleMake: (fresh['vehicle_make'] ?? '').toString(),
                    vehicleModel: (fresh['vehicle_model'] ?? '').toString(),
                    vehicleColor: (fresh['vehicle_color'] ?? '').toString(),
                    vehiclePlate: (fresh['vehicle_plate'] ?? '').toString(),
                    vehicleYear: (fresh['vehicle_year'] ?? '').toString(),
                    rideName: (fresh['vehicle_type'] ?? 'Ride').toString(),
                    price: (fresh['fare'] as num?)?.toDouble() ?? 0,
                    pickupLabel: (fresh['pickup_address'] ?? '').toString(),
                    dropoffLabel: (fresh['dropoff_address'] ?? '').toString(),
                    tripId: tripId,
                    firestoreTripId: 'sql_$tripId',
                    driverPhotoUrl: (fresh['driver_photo_url'] ?? '').toString(),
                    driverId: (fresh['driver_id'] ?? '').toString(),
                    initialStatus: status,
                    onTripComplete: () {
                      LocalDataService.clearActiveRide();
                      Navigator.of(context).pop();
                      _loadSavedData();
                    },
                  ),
                ),
              );
              return;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[HomeScreen] Scheduled ride live check failed: $e');
    }

    // Fallback: open the schedule hub
    if (!mounted) return;
    await Navigator.of(context).push(
      slideFromRightRoute(const ScheduleHubScreen()),
    );
    _loadSavedData();
  }

  /// Check backend for an active trip (handles reinstall / re-login where
  /// SharedPreferences are cleared but trip is still in-progress).
  /// Cross-check a locally cached active ride against the backend.
  /// If the backend says the trip is already cancelled or completed
  /// (typical when dispatch cancels remotely while the rider is in
  /// home), wipe the cache and the in-memory state so the rider lands
  /// on a clean home. Without this check the stale cache would
  /// auto-resume a dead trip.
  Future<void> _verifyActiveRideAgainstBackend(ActiveRideInfo cached) async {
    try {
      final tripId = cached.tripId;
      if (tripId == null) return;
      final trip = await ApiService.getActiveTrip();
      if (!mounted) return;
      // No trip on backend at all OR backend trip id doesn't match the
      // cached one → cache is stale. Same handling as cancelled.
      final backendTripId = trip == null ? null : trip['id'] as int?;
      final status = (trip?['status'] ?? '').toString();
      final isDeadTrip = trip == null ||
          backendTripId != tripId ||
          status == 'completed' ||
          status == 'canceled' ||
          status == 'cancelled';
      if (isDeadTrip) {
        debugPrint('[HomeScreen] Cached active ride is dead (status=$status) — resetting');
        _onTripCompleted();
      }
    } catch (_) {
      // Network blip: keep the cache and let the next loadSavedData try.
    }
  }

  Future<void> _checkBackendActiveTrip() async {
    // Idempotency guard at entry: claim the auto-resume slot IMMEDIATELY
    // so a parallel _resumeActiveRide() triggered by the local cache
    // loading in the meantime can't race us to a double-push.
    if (_didAutoResumeRide) {
      debugPrint('[HomeScreen] _checkBackendActiveTrip skipped — already auto-resumed');
      return;
    }
    _didAutoResumeRide = true;
    try {
      final trip = await ApiService.getActiveTrip();
      if (!mounted || trip == null) {
        // No active trip — release the slot so a later reload (new trip)
        // can auto-resume normally.
        _didAutoResumeRide = false;
        return;
      }
      final status = (trip['status'] ?? '').toString();
      // Skip completed/cancelled/scheduled trips — never auto-navigate for scheduled rides
      if (status == 'completed' || status == 'canceled' || status == 'cancelled' ||
          status == 'scheduled_accepted' || status == 'driver_assigned' ||
          status == 'scheduled') {
        _didAutoResumeRide = false; // release slot — nothing to resume
        return;
      }

      // If trip was originally scheduled (has scheduled_at), never auto-navigate.
      // The rider must tap the card to open the tracking screen.
      final scheduledAt = trip['scheduled_at'];
      if (scheduledAt != null && scheduledAt.toString().isNotEmpty) {
        _didAutoResumeRide = false;
        return;
      }

      // If still searching for a driver — show a pending trip indicator
      // so rider knows their search is still active after reopen/reinstall.
      // Backend uses 'requested' as the searching status.
      if (status == 'searching' || status == 'pending' || status == 'requested') {
        final tripId = trip['id'] as int?;
        if (tripId == null || !mounted) {
          _didAutoResumeRide = false;
          return;
        }
        _setState(() => _pendingSearchTripId = tripId);
        // Poll every 6s until driver assigned or trip cancelled
        _pendingSearchTimer?.cancel();
        _pendingSearchTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
          if (!mounted) { _pendingSearchTimer?.cancel(); return; }
          try {
            final updated = await ApiService.getActiveTrip();
            if (!mounted) return;
            final updatedStatus = (updated?['status'] ?? '').toString();
            if (updatedStatus == 'completed' || updatedStatus == 'canceled' || updatedStatus == 'cancelled' || updated == null) {
              _pendingSearchTimer?.cancel();
              _setState(() => _pendingSearchTripId = null);
              return;
            }
            // Driver assigned → open tracking screen
            if (updated['driver_id'] != null) {
              _pendingSearchTimer?.cancel();
              _setState(() => _pendingSearchTripId = null);
              // Release the auto-resume slot BEFORE re-entering — the entry
              // guard returns early while the flag is still true.
              _didAutoResumeRide = false;
              await _checkBackendActiveTrip();
            }
          } catch (_) {}
        });
        // Leave _didAutoResumeRide=true so the 6s polling loop is the
        // only one that can re-trigger _checkBackendActiveTrip — don't
        // want a parallel path to race it. The polling loop releases the
        // flag itself right before re-entering on driver assigned.
        return;
      }

      // Only resume trips that have a driver assigned
      if (trip['driver_id'] == null && trip['driver_name'] == null) {
        _didAutoResumeRide = false;
        return;
      }

      final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
      final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
      final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
      final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();
      if (pickupLat == null || pickupLng == null || dropoffLat == null || dropoffLng == null) {
        _didAutoResumeRide = false;
        return;
      }

      final tripId = trip['id'] as int?;
      final driverName = (trip['driver_name'] ?? 'Driver').toString();
      final driverRating = (trip['driver_rating'] as num?)?.toDouble() ?? 4.9;
      final driverPhotoUrl = (trip['driver_photo_url'] ?? '').toString();
      final driverId = (trip['driver_id'] ?? '').toString();
      final driverPhone = (trip['driver_phone'] ?? '').toString();
      final vehicleMake = (trip['vehicle_make'] ?? '').toString();
      final vehicleModel = (trip['vehicle_model'] ?? '').toString();
      final vehicleColor = (trip['vehicle_color'] ?? '').toString();
      final vehiclePlate = (trip['vehicle_plate'] ?? '').toString();
      final vehicleYear = (trip['vehicle_year'] ?? '').toString();
      final vehicleType = (trip['vehicle_type'] ?? 'Ride').toString();
      final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
      final pickupLabel = (trip['pickup_address'] ?? '').toString();
      final dropoffLabel = (trip['dropoff_address'] ?? '').toString();

      // Flag was already claimed at the top of this method — no need to
      // re-set it here. Leaving it as-is so the slot stays reserved while
      // we push the tracking screen.

      // Final safety check: re-verify trip hasn't been cancelled/scheduled since we started
      if (!mounted) {
        _didAutoResumeRide = false;
        return;
      }
      final verifyStatus = (trip['status'] ?? '').toString();
      if (verifyStatus == 'canceled' || verifyStatus == 'cancelled' ||
          verifyStatus == 'completed' || verifyStatus == 'scheduled_accepted' ||
          verifyStatus == 'driver_assigned' || verifyStatus == 'scheduled') {
        _didAutoResumeRide = false;
        return;
      }

      await Navigator.of(context).push(
        slideUpFadeRoute(
          RiderTrackingScreen(
            pickupLatLng: LatLng(pickupLat, pickupLng),
            dropoffLatLng: LatLng(dropoffLat, dropoffLng),
            driverName: driverName,
            driverPhone: driverPhone.isNotEmpty ? driverPhone : null,
            driverRating: driverRating,
            vehicleMake: vehicleMake,
            vehicleModel: vehicleModel,
            vehicleColor: vehicleColor,
            vehiclePlate: vehiclePlate,
            vehicleYear: vehicleYear,
            rideName: vehicleType,
            price: fare,
            pickupLabel: pickupLabel,
            dropoffLabel: dropoffLabel,
            tripId: tripId,
            firestoreTripId: 'sql_$tripId',
            driverPhotoUrl: driverPhotoUrl,
            driverId: driverId,
            initialStatus: status,
            onTripComplete: () {
              LocalDataService.clearActiveRide();
              Navigator.of(context).pop();
              _loadSavedData();
            },
          ),
        ),
      );
      // Reset so HomeScreen can re-check for an active trip if the screen
      // was dismissed without trip completion (e.g. system back gesture).
      _didAutoResumeRide = false;
    } catch (e) {
      debugPrint('[HomeScreen] Backend active trip check failed: $e');
      _didAutoResumeRide = false; // release slot on error so retries work
    }
  }

  /// Full-screen autocomplete address picker using PlacesService.
  Future<String?> _showAddressAutocomplete({
    required String title,
    required String hint,
  }) async {
    // Full-screen page with the project's fluid slide-up + fade transition
    // (instead of the default modal sheet animation). The Material wrapper
    // replaces the ancestor the modal route used to provide (TextField
    // requires it).
    return Navigator.of(context).push<String>(
      slideUpFadeRoute<String>(
        Material(
          type: MaterialType.transparency,
          child: _AddressAutocompleteSheet(
            title: title,
            hint: hint,
            currentLatLng: _currentLatLng,
          ),
        ),
      ),
    );
  }

  void _openTripReceipt(TripHistoryItem trip) {
    Navigator.of(
      context,
    ).push(sharedAxisVerticalRoute(TripReceiptScreen(trip: trip)));
  }
}
