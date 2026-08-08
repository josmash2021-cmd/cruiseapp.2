part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  DRIVER INFO CARD — driver details, avatar, plate
// ════════════════════════════════════════════════════════════

extension _RiderTrackingDriverInfoCard on _RiderTrackingScreenState {

  /// The same render the rider picked on "Choose a ride".
  ///
  /// Keys and files are deliberately identical to _carAssetForOption in
  /// ride_request_widgets.dart — the rider chose a tier by looking at one
  /// of these cars, so the card that says their ride arrived has to show
  /// that same car. The old car_suv/car_sedan/car_economy set was a
  /// different set of renders entirely.
  ///
  /// Tier first, model as the fallback: rideName carries the tier the
  /// rider actually paid for, and a VIP booking stays a VIP render even
  /// when dispatch sends a differently-named vehicle.
  String get _vehicleAsset {
    final rn = widget.rideName.toLowerCase();
    final m = widget.vehicleModel.toLowerCase();
    if (rn.contains('vip') || rn.contains('black') ||
        rn.contains('suv') || rn.contains('suburban') ||
        m.contains('suburban')) {
      return 'assets/images/cruisert1.png';
    }
    if (rn.contains('sedan') || rn.contains('premium') ||
        rn.contains('camry') || m.contains('camry')) {
      return 'assets/images/cruisert2.png';
    }
    // comfort / fusion and anything unrecognised. Deliberately NOT in the
    // branch above: the picker sends the Fusion here too, and the whole
    // point is that both screens show the rider the same car.
    return 'assets/images/cruisert3.png';
  }

  Widget _driverInitial() => Container(
    color: const Color(0xFF1A1A1A),
    child: Center(
      child: Text(
        widget.driverName.isNotEmpty ? widget.driverName[0].toUpperCase() : 'D',
        style: TextStyle(
          color: AppColors.kGold, fontSize: Responsive.sp(18), fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  // ── Driver info card (floats at top) ──
  /// Shown in the driver card's place while the trip is back in the
  /// dispatch queue, after the assigned driver handed it back.
  Widget _buildSearchingDriverCard() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.w(18),
        vertical: Responsive.h(18),
      ),
      decoration: neuBox(radius: 22),
      child: Row(
        children: [
          SizedBox(
            width: Responsive.w(22),
            height: Responsive.w(22),
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation(AppColors.kGold),
            ),
          ),
          SizedBox(width: Responsive.w(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  S.of(context).findingYouAnotherDriver,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: Responsive.sp(15),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: Responsive.h(3)),
                Text(
                  S.of(context).yourPickupIsUnchanged,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: Responsive.sp(12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverCard() {
    final s = S.of(context);
    String statusLabel;
    switch (_phase) {
      case _TrackPhase.arriving:
        statusLabel = s.meetDriverAtPickup;
      case _TrackPhase.arrived:
        statusLabel = s.yourDriverArrivedExcl;
      case _TrackPhase.onTrip:
        statusLabel = s.onTripToDestination;
      case _TrackPhase.nearDestination:
        statusLabel = s.arrivingAtDestination;
      case _TrackPhase.completed:
        statusLabel = s.youHaveArrived;
    }

    final vehicleLabel = [
      widget.vehicleColor,
      widget.vehicleMake,
      widget.vehicleModel,
    ].where((v) => v.isNotEmpty).join(' ');

    return Container(
      // Welded to the bottom edge and both sides, so only the top corners
      // round. The safe area is inside the padding, not a strip of map
      // under the card.
      decoration: neuBox(radius: 24).copyWith(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: EdgeInsets.fromLTRB(
        Responsive.w(14),
        Responsive.w(14),
        Responsive.w(14),
        Responsive.w(14) + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status label
          Row(
            children: [
              Container(
                width: Responsive.w(8), height: Responsive.w(8),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.kGold,
                ),
              ),
              SizedBox(width: Responsive.w(8)),
              Flexible(
                child: Text(
                  statusLabel,
                  style: TextStyle(color: AppColors.kGold, fontSize: Responsive.sp(11), fontWeight: FontWeight.w600, letterSpacing: 0.6),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.h(10)),
          // Driver row
          Row(
            children: [
              // Driver photo with verified badge
              VerifiedAvatar(
                photoUrl: _driverPhotoUrl,
                radius: Responsive.w(22),
                fallbackName: widget.driverName,
                uid: widget.driverId,
                role: 'driver',
                isVerified: true,
              ),
              SizedBox(width: Responsive.w(10)),
              // Name + rating
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nh.displayName(widget.driverName, widget.rideName),
                      style: TextStyle(color: Colors.white, fontSize: Responsive.sp(15), fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.star_rounded, color: AppColors.kGold, size: Responsive.sp(14)),
                        SizedBox(width: Responsive.w(3)),
                        Text(
                          widget.driverRating.toStringAsFixed(1),
                          style: TextStyle(color: Colors.white60, fontSize: Responsive.sp(13)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Vehicle identity, stacked so the rider can match the car at
              // a glance: model on top, the car itself, plate underneath.
              SizedBox(
                width: Responsive.w(92),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (vehicleLabel.isNotEmpty)
                      Text(
                        vehicleLabel,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: Responsive.sp(10),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    SizedBox(height: Responsive.h(3)),
                    _buildVehicleRender(),
                    SizedBox(height: Responsive.h(3)),
                    // Plate: smaller than before — it is the confirmation,
                    // not the headline. White, because a plate should read
                    // like a plate.
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: Responsive.w(7),
                          vertical: Responsive.h(2)),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        widget.vehiclePlate.isNotEmpty
                            ? widget.vehiclePlate.toUpperCase()
                            : '---',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: Responsive.sp(11),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.h(10)),
          // Action row: chat + call + more
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    HapticService.selectionClick();
                    // Push FIRST, resolve the id after. Awaiting
                    // getCurrentUserId here meant the chat only started
                    // opening once an HTTP call came back — the tap felt
                    // dead for as long as the network took. ChatScreen
                    // resolves the id itself when it is not supplied.
                    if (!mounted) return;
                    final nav = _nav;
                    if (nav == null) return;
                    final userIdFuture = ApiService.getCurrentUserId();
                    nav.push(
                      chatOpenRoute(
                        ChatScreen(
                          // Full name, not just the first word — the header
                          // showed "Jhon" where the driver is "Jhon
                          // martinez".
                          recipientName: widget.driverName,
                          recipientPhotoUrl: _driverPhotoUrl,
                          recipientId: widget.driverId,
                          recipientRole: 'driver',
                          avatarInitial: widget.driverName.isNotEmpty
                              ? widget.driverName[0].toUpperCase()
                              : 'D',
                          tripId: widget.tripId,
                          currentRole: 'rider',
                          currentUserId: null,
                        ),
                      ),
                    );
                    unawaited(userIdFuture);
                  },
                  child: widget.tripId != null
                      ? StreamBuilder<int>(
                          stream: ChatService().unreadCountStream(
                            rideId: widget.tripId.toString(),
                            readerRole: 'rider',
                          ),
                          builder: (context, snap) {
                            final count = snap.data ?? 0;
                            return _ChatPromptPill(count: count);
                          },
                        )
                      : const _ChatPromptPill(count: 0),
                ),
              ),
              SizedBox(width: Responsive.w(8)),
              _buildCardIconBtn(icon: Icons.phone_rounded, onTap: _handleCallDriver),
              SizedBox(width: Responsive.w(8)),
              _buildCardIconBtn(
                icon: Icons.share_rounded,
                onTap: _handleShareTrip,
              ),
              SizedBox(width: Responsive.w(8)),
              _buildMoreMenuButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCardIconBtn({required IconData icon, required VoidCallback onTap}) {
    final d = Responsive.w(40);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: d, height: d,
        // Sunken well — the established neumorphic idiom for icon buttons.
        // radius = half the box, so the well reads as a circle.
        decoration: neuBox(
          radius: d / 2,
          pressed: true,
          borderColor: AppColors.kGold.withValues(alpha: 0.35),
        ),
        child: Icon(icon, color: AppColors.kGold, size: Responsive.sp(18)),
      ),
    );
  }

  /// Call the driver through the masked-call bridge — fetches a short-lived
  /// masked contact (Twilio number + extension) and dials that, so neither
  /// side ever sees the other's real phone number.
  Future<void> _handleCallDriver() async {
    final name = nh.displayName(widget.driverName, widget.rideName);
    final tripId = widget.tripId;
    if (tripId == null) {
      _messenger?.showSnackBar(
        SnackBar(
          content: Text('${S.of(context).phoneNotAvailable} - $name'),
          // Uses global snackBarTheme
        ),
      );
      return;
    }

    final ok = await MaskedCallService.callCounterparty(tripId: tripId, role: 'rider');
    if (!ok && mounted) {
      _messenger?.showSnackBar(
        SnackBar(
          content: Text('${S.of(context).phoneNotAvailable} - $name'),
          // Uses global snackBarTheme
        ),
      );
    }
  }

  /// Share a Google Maps deep-link to the driver's current GPS location.
  /// Falls back to the trip tracking link if driver position is not yet known.
  void _handleShareDriverLocation() {
    final lat = _animPos.latitude;
    final lng = _animPos.longitude;
    final name = nh.displayName(widget.driverName, widget.rideName);

    if (lat != 0 && lng != 0) {
      // Driver live position known — share live Google Maps link
      final mapsUrl = 'https://maps.google.com/?q=$lat,$lng';
      unawaited(shareText(
        context,
        'I\'m on a Cruise ride! My driver $name is on the way.\n\n'
        '📍 Live location: $mapsUrl\n\n'
        'From: ${widget.pickupLabel}\n'
        'To: ${widget.dropoffLabel}\n\n'
        'Track my ride in real time!',
        subject: 'My Cruise ride — live tracking',
      ));
    } else {
      // Fallback: share pickup/dropoff info
      unawaited(shareText(
        context,
        'I\'m on a Cruise ride with $name!\n\n'
        'From: ${widget.pickupLabel}\n'
        'To: ${widget.dropoffLabel}\n\n'
        'Powered by Cruise 🚗',
        subject: 'My Cruise ride',
      ));
    }
  }

  Widget _buildMoreMenuButton() {
    final d = Responsive.w(40);
    return GestureDetector(
      onTap: () => _setState(
          () => _supportPage = _supportPage == 0 ? 1 : 0),
      child: Container(
        width: d, height: d,
        // Open state pops OUT of the well (pressed: false) so the button
        // visibly holds the panel it opened.
        decoration: neuBox(
          radius: d / 2,
          pressed: _supportPage == 0,
          borderColor: AppColors.kGold
              .withValues(alpha: _supportPage != 0 ? 0.8 : 0.35),
        ),
        // Support agent, not three dots: this is where the rider reaches
        // help, and an ellipsis promises nothing.
        child: Icon(Icons.support_agent_rounded,
            color: AppColors.kGold, size: Responsive.sp(18)),
      ),
    );
  }

  // ═══ Safety & Support panel — the bottom card TRANSFORMED (2026-08-05) ═══

  BoxDecoration get _panelShell => neuBox(radius: 24).copyWith(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      );

  Widget _buildSupportPanel() {
    final s = S.of(context);
    return Container(
      key: const ValueKey('support-panel'),
      decoration: _panelShell,
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, MediaQuery.of(context).padding.bottom + 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.support_agent_rounded,
                  color: AppColors.kGold, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.safetyAndSupport,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => _setState(() => _supportPage = 0),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: neuBox(radius: 17, pressed: true),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildMenuItem(
            icon: Icons.report_problem_outlined,
            label: S.of(context).problemWithTrip,
            color: AppColors.kGold,
            onTap: () {
              _setState(() => _supportPage = 0);
              _openSupportChat();
            },
          ),
          _menuDivider(),
          _buildMenuItem(
            icon: Icons.add_location_alt_outlined,
            label: s.addStopLabel,
            color: AppColors.kGold,
            onTap: () => _openRouteChangePage(2),
          ),
          _menuDivider(),
          _buildMenuItem(
            icon: Icons.edit_location_alt_outlined,
            label: s.changeDestination,
            color: AppColors.kGold,
            onTap: () => _openRouteChangePage(3),
          ),
          _menuDivider(),
          _buildMenuItem(
            icon: Icons.emergency_outlined,
            label: s.call911,
            color: const Color(0xFFEF4444),
            onTap: () {
              _setState(() => _supportPage = 0);
              _callEmergency();
            },
          ),
          _menuDivider(),
          _buildMenuItem(
            icon: Icons.headset_mic_outlined,
            label: s.contactSupport,
            color: AppColors.kGold,
            onTap: () {
              _setState(() => _supportPage = 0);
              _openSupportChat();
            },
          ),
        ],
      ),
    );
  }

  void _openRouteChangePage(int page) {
    _rcSearchCtrl.clear();
    _rcSuggestions = [];
    _rcPicked = null;
    _rcQuoteCents = null;
    _setState(() => _supportPage = page);
  }

  Widget _buildRouteChangePanel() {
    final s = S.of(context);
    final isStop = _supportPage == 2;
    final mq = MediaQuery.of(context);
    return Container(
      key: ValueKey('route-change-$_supportPage'),
      decoration: _panelShell,
      // viewInsets so the panel rides the keyboard while typing.
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, mq.viewInsets.bottom + mq.padding.bottom + 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _setState(() => _supportPage = 1),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: neuBox(radius: 17, pressed: true),
                  child: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white, size: 18),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isStop ? s.addStopLabel : s.changeDestination,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: neuBox(radius: 14, pressed: true),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _rcSearchCtrl,
              autofocus: true,
              onChanged: _rcOnQueryChanged,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
              decoration: InputDecoration(
                border: InputBorder.none,
                icon: Icon(Icons.search_rounded,
                    color: Colors.white.withValues(alpha: 0.4), size: 20),
                hintText: isStop ? s.addStopHint : s.newDestinationHint,
                hintStyle:
                    TextStyle(color: Colors.white.withValues(alpha: 0.35)),
              ),
            ),
          ),
          if (_rcSearching || _rcQuoting) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFFE8C547),
              backgroundColor: Colors.transparent,
            ),
          ],
          // Suggestions — up to 4, tap to quote.
          for (final sg in _rcSuggestions.take(4)) ...[
            InkWell(
              onTap: () => _rcPick(sg),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.place_outlined,
                        color: Colors.white.withValues(alpha: 0.45),
                        size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sg.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _menuDivider(),
          ],
          // Quote + confirm
          if (_rcPicked != null && _rcQuoteCents != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.kGold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: AppColors.kGold.withValues(alpha: 0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _rcPicked!.address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isStop
                        ? s.stopExtraCharge(
                            '\$${(_rcQuoteCents!.abs() / 100).toStringAsFixed(2)}')
                        : (_rcQuoteCents! >= 0
                            ? s.destChargeUp(
                                '\$${(_rcQuoteCents! / 100).toStringAsFixed(2)}')
                            : s.destChargeDown(
                                '\$${(_rcQuoteCents!.abs() / 100).toStringAsFixed(2)}')),
                    style: TextStyle(
                        color: AppColors.kGold,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: _rcCommitting ? null : _confirmRouteChange,
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.kGold,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: _rcCommitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Color(0xFF1A1400)),
                              )
                            : Text(
                                S.of(context).confirm,
                                style: const TextStyle(
                                    color: Color(0xFF1A1400),
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800),
                              ),
                      ),
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

  void _rcOnQueryChanged(String q) {
    _rcDebounce?.cancel();
    _rcDebounce = Timer(const Duration(milliseconds: 420), () async {
      if (!mounted || q.trim().length < 3) return;
      _setState(() => _rcSearching = true);
      try {
        final near =
            _driverPos.latitude != 0 ? _driverPos : widget.pickupLatLng;
        final res = await PlacesService(ApiKeys.webServices).autocomplete(
          q,
          latitude: near.latitude,
          longitude: near.longitude,
        );
        if (!mounted) return;
        _setState(() {
          _rcSuggestions = res;
          _rcSearching = false;
        });
      } catch (e) {
        debugPrint('[RouteChange] autocomplete failed: $e');
        if (mounted) _setState(() => _rcSearching = false);
      }
    });
  }

  Future<void> _rcPick(PlaceSuggestion sg) async {
    FocusScope.of(context).unfocus();
    _setState(() {
      _rcQuoting = true;
      _rcSuggestions = [];
      _rcSearchCtrl.text = sg.description;
    });
    try {
      PlaceDetails? det;
      if (sg.lat != null && sg.lng != null) {
        det = PlaceDetails(
            address: sg.description, lat: sg.lat!, lng: sg.lng!);
      } else {
        det = await PlacesService(ApiKeys.webServices).details(sg.placeId);
      }
      if (det == null) throw Exception('no place details');
      final cents = await _rcQuote(det);
      if (!mounted) return;
      _setState(() {
        _rcPicked = det;
        _rcQuoteCents = cents;
        _rcQuoting = false;
      });
    } catch (e) {
      debugPrint('[RouteChange] quote failed: $e');
      if (mounted) {
        _setState(() => _rcQuoting = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(S.of(context).routeChangeFailed),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  LatLng get _currentDropoffLL => _dropoffOverride ?? widget.dropoffLatLng;

  /// Street-routed delta for the picked place, priced with the SAME
  /// anchored per-mile/per-minute rates the trip carries
  /// (stop_pricing.dart). Stop page → extra cents (≥ \$2.50);
  /// destination page → SIGNED fare delta cents.
  Future<int> _rcQuote(PlaceDetails det) async {
    final ds = DirectionsService(ApiKeys.webServices);
    final onTripNow = _phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination;
    final origin = (onTripNow && _driverPos.latitude != 0)
        ? _driverPos
        : widget.pickupLatLng;
    final dest = _currentDropoffLL;
    final base = await ds.getRoute(origin: origin, destination: dest);
    final baseMi = (base?.distanceMeters ?? 0) / 1609.344;
    final baseMin = ((base?.durationSeconds ?? 0) / 60.0).ceil();
    if (_supportPage == 2) {
      final stopLL = LatLng(det.lat, det.lng);
      final leg1 = await ds.getRoute(origin: origin, destination: stopLL);
      final leg2 = await ds.getRoute(origin: stopLL, destination: dest);
      if (leg1 == null || leg2 == null) throw Exception('no route');
      final mi =
          (leg1.distanceMeters + leg2.distanceMeters) / 1609.344 - baseMi;
      final mins = (((leg1.durationSeconds ?? 0) +
                      (leg2.durationSeconds ?? 0)) /
                  60.0)
              .ceil() -
          baseMin;
      return stopExtraCents(
          tier: widget.rideName, deltaMiles: mi, deltaMins: mins);
    }
    final nr = await ds.getRoute(
        origin: origin, destination: LatLng(det.lat, det.lng));
    if (nr == null) throw Exception('no route');
    final mi = nr.distanceMeters / 1609.344 - baseMi;
    final mins = ((nr.durationSeconds ?? 0) / 60.0).ceil() - baseMin;
    return destinationDeltaCents(
        tier: widget.rideName, deltaMiles: mi, deltaMins: mins);
  }

  Future<void> _confirmRouteChange() async {
    final det = _rcPicked;
    final cents = _rcQuoteCents;
    final tripId = widget.tripId;
    if (det == null || cents == null || tripId == null || _rcCommitting) {
      return;
    }
    final s = S.of(context);
    final isStop = _supportPage == 2;
    final amt = '\$${(cents.abs() / 100).toStringAsFixed(2)}';
    final msg = isStop
        ? s.stopExtraCharge(amt)
        : (cents >= 0 ? s.destChargeUp(amt) : s.destChargeDown(amt));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C24),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(s.areYouSureTitle,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800)),
        content: Text('${det.address}\n\n$msg',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.confirm,
                style: const TextStyle(
                    color: Color(0xFFE8C547),
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _commitRouteChangeCore();
  }

  /// The API call + map choreography, shared by the rider's own flow
  /// (after its Are-you-sure dialog) and the driver-proposal sheet
  /// (whose Confirm button IS the consent).
  Future<void> _commitRouteChangeCore() async {
    final det = _rcPicked;
    final cents = _rcQuoteCents;
    final tripId = widget.tripId;
    if (det == null || cents == null || tripId == null || _rcCommitting) {
      return;
    }
    final s = S.of(context);
    final isStop = _supportPage == 2;
    _setState(() => _rcCommitting = true);
    try {
      if (isStop) {
        await ApiService.addTripStop(
          tripId: tripId,
          lat: det.lat,
          lng: det.lng,
          label: det.address,
          extraCents: cents,
        );
      } else {
        final newFare =
            (widget.price + cents / 100.0).clamp(3.0, 500.0).toDouble();
        await ApiService.changeTripDestination(
          tripId: tripId,
          lat: det.lat,
          lng: det.lng,
          label: det.address,
          newFare: newFare,
        );
      }
      if (!mounted) return;
      HapticService.mediumImpact();
      _setState(() {
        _rcCommitting = false;
        _supportPage = 0;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content:
              Text(isStop ? s.stopAddedToast : s.destinationChangedToast),
          behavior: SnackBarBehavior.floating));
      _writePendingProposal(null); // clear any driver proposal it answered
      unawaited(_applyCommittedRouteChange(det, isStop: isStop));
    } catch (e) {
      debugPrint('[RouteChange] commit failed: $e');
      if (mounted) {
        _setState(() => _rcCommitting = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(s.routeChangeFailed),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  // ═══ Fase 2: the DRIVER proposed a route change ═══

  /// null clears the field; a map writes it (declined answers).
  void _writePendingProposal(Map<String, dynamic>? value) {
    final fs = widget.firestoreTripId;
    final tid = widget.tripId;
    final docId =
        (fs != null && fs.isNotEmpty) ? fs : (tid != null ? 'sql_$tid' : null);
    if (docId == null) return;
    FirebaseFirestore.instance
        .collection('trips')
        .doc(docId)
        .set({'pending_route_change': value ?? FieldValue.delete()},
            SetOptions(merge: true))
        .catchError((Object e) {
      debugPrint('[Proposal] pending write failed: $e');
    });
  }

  /// Called from the trip-doc stream: show the confirm sheet ONCE per
  /// distinct proposal, quote it with the same anchored pricing the
  /// rider's own flow uses, and commit through the same endpoints.
  void _handleDriverProposal(Map<String, dynamic> data) {
    if (!mounted || _phase == _TrackPhase.completed) return;
    final prc = data['pending_route_change'];
    if (prc is! Map) return;
    if ((prc['proposed_by'] ?? '') != 'driver') return;
    if ((prc['status'] ?? '') != 'proposed') return;
    final lat = (prc['lat'] as num?)?.toDouble();
    final lng = (prc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    final isStop = (prc['type'] ?? '') != 'change_destination';
    if (isStop && _committedStop != null) return; // one stop per trip
    final key = '${prc['type']}|$lat|$lng';
    if (_proposalSheetOpen || _handledProposalKey == key) return;
    _handledProposalKey = key;
    unawaited(_showDriverProposalSheet(
        isStop: isStop,
        lat: lat,
        lng: lng,
        label: (prc['label'] ?? '').toString()));
  }

  Future<void> _showDriverProposalSheet({
    required bool isStop,
    required double lat,
    required double lng,
    required String label,
  }) async {
    if (!mounted) return;
    _proposalSheetOpen = true;
    HapticService.mediumImpact();
    int? cents;
    try {
      _supportPage = isStop ? 2 : 3; // _rcQuote keys stop-vs-dest off this
      cents = await _rcQuote(PlaceDetails(address: label, lat: lat, lng: lng));
    } catch (e) {
      debugPrint('[Proposal] quote failed: $e');
    } finally {
      _supportPage = 0;
    }
    if (!mounted) {
      _proposalSheetOpen = false;
      return;
    }
    final s = S.of(context);
    String money = '';
    if (cents != null) {
      final amt = '\$${(cents.abs() / 100).toStringAsFixed(2)}';
      money = isStop
          ? s.stopExtraCharge(amt)
          : (cents >= 0 ? s.destChargeUp(amt) : s.destChargeDown(amt));
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: neuBox(radius: 24).copyWith(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: EdgeInsets.fromLTRB(
            20, 14, 20, MediaQuery.of(ctx).padding.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              isStop ? s.driverProposesStop : s.driverProposesDestination,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
            ),
            if (money.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                money,
                style: TextStyle(
                    color: AppColors.kGold,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(false),
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        s.decline,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(true),
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.kGold,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        s.confirm,
                        style: const TextStyle(
                            color: Color(0xFF1A1400),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    _proposalSheetOpen = false;
    if (!mounted) return;
    if (ok == true) {
      _supportPage = isStop ? 2 : 3;
      _rcPicked = PlaceDetails(address: label, lat: lat, lng: lng);
      _rcQuoteCents = cents ?? (isStop ? 250 : 0);
      await _commitRouteChangeCore();
      _supportPage = 0;
    } else {
      _writePendingProposal({
        'proposed_by': 'driver',
        'status': 'declined',
      });
    }
  }

  /// Backend committed — now the map: stop pin (same golden circle the
  /// dropoff wears) or moved dropoff pin, the new line crossfaded in by
  /// the same path every reroute takes, and a smooth zoom-out that shows
  /// the whole new plan before the chase camera takes over again.
  Future<void> _applyCommittedRouteChange(PlaceDetails det,
      {required bool isStop}) async {
    final target = LatLng(det.lat, det.lng);
    if (isStop) {
      _committedStop = target;
      _committedStopLabel = det.address;
      unawaited(_drawStopPin(target));
    } else {
      _dropoffOverride = target;
      unawaited(_moveDropoffPin(target));
    }
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      final onTripNow = _phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination;
      final origin = (onTripNow && _driverPos.latitude != 0)
          ? _driverPos
          : widget.pickupLatLng;
      final dest = _currentDropoffLL;
      List<LatLng> pts = [];
      final stop = _committedStop;
      if (stop != null) {
        final l1 = await ds.getRoute(origin: origin, destination: stop);
        final l2 = await ds.getRoute(origin: stop, destination: dest);
        if (l1 != null && l2 != null) {
          pts = [...l1.points, ...l2.points.skip(1)];
        }
      } else {
        final r = await ds.getRoute(origin: origin, destination: dest);
        if (r != null) pts = r.points;
      }
      if (!mounted || pts.length < 2) return;
      _tripRoutePts = List<LatLng>.from(pts);
      await _applyReroutedPolyline(pts);
      _zoomOutForRouteChange(
          [origin, if (stop != null) stop, dest, ...pts]);
    } catch (e) {
      debugPrint('[RouteChange] redraw failed: $e');
    }
  }

  Future<void> _drawStopPin(LatLng p) async {
    try {
      final bytes = await renderCircularPinBytes(
          icon: CircularPinIcon.flag, isPickup: false, radius: 32);
      if (!mounted) return;
      if (kIsWeb) {
        _webMapCtrl?.addMarker('stop', p.longitude, p.latitude,
            iconBytes: bytes, widthPx: 52, heightPx: 48, anchor: 'bottom');
        return;
      }
      final mgr = _pointAnnotMgr;
      final geom = safePoint(p.longitude, p.latitude);
      if (mgr == null || geom == null) return;
      final old = _stopAnnot;
      if (old != null) {
        _stopAnnot = null;
        try {
          await mgr.delete(old);
        } catch (_) {}
      }
      _stopAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: geom,
        image: bytes,
        iconSize: 0.86,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
    } catch (e) {
      debugPrint('[RouteChange] stop pin failed: $e');
    }
  }

  Future<void> _moveDropoffPin(LatLng p) async {
    try {
      if (kIsWeb) {
        final bytes = await renderCircularPinBytes(
            icon: CircularPinIcon.home, isPickup: false, radius: 32);
        _webMapCtrl?.removeMarker('dropoff');
        _webMapCtrl?.addMarker('dropoff', p.longitude, p.latitude,
            iconBytes: bytes, widthPx: 52, heightPx: 48, anchor: 'bottom');
        return;
      }
      final mgr = _pointAnnotMgr;
      final annot = _dropoffAnnot;
      final geom = safePoint(p.longitude, p.latitude);
      if (mgr == null || annot == null || geom == null) return;
      annot.geometry = geom;
      mgr.update(annot).catchError((_) {});
    } catch (_) {}
  }

  /// One smooth wide shot of the whole new plan, then hand the camera
  /// back to the chase — nothing is rebuilt, only flown.
  void _zoomOutForRouteChange(List<LatLng> pts) {
    if (pts.length < 2) return;
    _userControllingCamera = true;
    if (kIsWeb) {
      _webFitRouteBounds();
    } else {
      final mc = _map;
      if (mc != null) {
        double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
        for (final p in pts) {
          if (p.latitude < minLat) minLat = p.latitude;
          if (p.latitude > maxLat) maxLat = p.latitude;
          if (p.longitude < minLng) minLng = p.longitude;
          if (p.longitude > maxLng) maxLng = p.longitude;
        }
        unawaited(() async {
          try {
            final cam = await mc.cameraForCoordinateBounds(
              mapbox.CoordinateBounds(
                southwest: mapbox.Point(
                    coordinates: mapbox.Position(minLng, minLat)),
                northeast: mapbox.Point(
                    coordinates: mapbox.Position(maxLng, maxLat)),
                infiniteBounds: false,
              ),
              mapbox.MbxEdgeInsets(
                  top: _topCardHeight + 90,
                  left: 60,
                  bottom: _bottomCardHeight + 90,
                  right: 60),
              0,
              0,
              null,
              null,
            );
            await mc.flyTo(
              mapbox.CameraOptions(
                  center: cam.center,
                  zoom: cam.zoom,
                  bearing: 0,
                  pitch: 0),
              mapbox.MapAnimationOptions(duration: 1400),
            );
          } catch (e) {
            debugPrint('[RouteChange] zoom-out failed: $e');
          }
        }());
      }
    }
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      _recenter();
    });
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: color == AppColors.kGold ? Colors.white : color,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCancelConfirmDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cancel_outlined, color: Color(0xFFEF4444), size: 28),
              ),
              const SizedBox(height: 16),
              const Text(
                '¿Cancelar viaje?',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).cancelAfterAssignBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _cancelTripInstantly();
                  },
                  child: Text(S.of(context).yesCancelTrip, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity, height: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'No, continuar',
                    style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Hairline rule between menu rows — the shared neu grouping idiom.
  Widget _menuDivider() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: Colors.white.withValues(alpha: 0.05),
      );

  /// Dial emergency services.
  ///
  /// Confirms first: this sits one tap from Contact Support and a
  /// misdialled 911 is not a small thing.
  void _callEmergency() {
    HapticService.heavyImpact();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: neuSurface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text(S.of(ctx).call911,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800)),
        content: Text(
          S.of(ctx).call911OrEmergency,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.of(ctx).cancel,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse('tel:911'));
            },
            child: Text(S.of(ctx).call911,
                style: const TextStyle(
                    color: Color(0xFFEF4444), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Ask dispatch to change the drop-off.
  ///
  /// Routed through support on purpose, not stubbed: changing the
  /// destination mid-trip re-prices the ride and has to reach the driver,
  /// and there is no backend endpoint for either yet. Dispatch can do both
  /// today, so the rider gets a real outcome instead of a dead button —
  /// the same shape the cancel policy already uses.
  void _requestDestinationChange() {
    HapticService.selectionClick();
    _openSupportChat();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(S.of(context).changeDestinationViaSupport),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _openSupportChat() {
    _nav?.push(
      slideFromRightRoute(
        ChatScreen(
          recipientName: 'Support',
          avatarInitial: 'S',
          tripId: widget.tripId,
          isSupport: true,
        ),
      ),
    );
  }

  /// The car render, sitting on the card instead of floating over it.
  ///
  /// Two shadows, because on a PNG neither one alone works. A BoxShadow
  /// shadows the image's bounding box, not the car — a rectangle of grey
  /// under a car-shaped hole. A blurred silhouette alone reads as a sticker
  /// lifting off the surface, because nothing anchors it to a ground plane.
  /// Together:
  ///   • a soft elliptical pool under the wheels gives contact with the card
  ///   • a blurred copy of the car's own alpha gives height above that pool
  ///
  /// clipBehavior: none — the car is letterboxed edge to edge horizontally,
  /// so a clipping Stack would cut the blur off in a straight line down both
  /// sides, which is the one thing that makes a shadow look fake.
  Widget _buildVehicleRender() {
    final h = Responsive.h(34);
    return SizedBox(
      height: h,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Ground pool. A radial gradient in a wide, short box is already
          // an ellipse with a soft edge, so this needs no blur filter of
          // its own — it is the cheapest of the three layers.
          Positioned(
            left: Responsive.w(6),
            right: Responsive.w(6),
            bottom: h * 0.04,
            height: h * 0.24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // Silhouette: the car's own alpha, tinted black and blurred.
          // srcIn keeps the shape and throws away the colour.
          Transform.translate(
            offset: Offset(0, Responsive.h(2)),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: Image.asset(
                _vehicleAsset,
                width: double.infinity,
                height: h,
                fit: BoxFit.contain,
                color: Colors.black.withValues(alpha: 0.5),
                colorBlendMode: BlendMode.srcIn,
                // No fallback icon here: if the asset is missing the real
                // image below already draws the icon, and a blurred black
                // copy of it would sit behind that as a smudge.
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          // The car itself. errorBuilder, not a bare Image.asset: a missing
          // render must not take the whole card down mid-trip.
          //
          // width too, not height alone: the picker renders are wide, so a
          // height-only constraint left the car floating small against the
          // right edge. Letterboxed into the full column width it reads as
          // the same car the rider chose.
          Image.asset(
            _vehicleAsset,
            width: double.infinity,
            height: h,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Icon(
              Icons.directions_car_rounded,
              color: AppColors.kGold.withValues(alpha: 0.5),
              size: Responsive.sp(22),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chat input pill on the rider tracking driver-info card.
/// - Idle: dark "Type a message..." chip with subtle gold border.
/// - Unread > 0: turns gold, shows "X new message(s) from driver" with
///   a shimmer sweep that loops every 1.8s to draw the eye, plus a
///   small unread counter on the right.
class _ChatPromptPill extends StatefulWidget {
  final int count;
  const _ChatPromptPill({required this.count});

  @override
  State<_ChatPromptPill> createState() => _ChatPromptPillState();
}

class _ChatPromptPillState extends State<_ChatPromptPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.count > 0) _shimmer.repeat();
  }

  @override
  void didUpdateWidget(covariant _ChatPromptPill old) {
    super.didUpdateWidget(old);
    if (widget.count > 0 && !_shimmer.isAnimating) {
      _shimmer.repeat();
    } else if (widget.count == 0 && _shimmer.isAnimating) {
      _shimmer.stop();
      _shimmer.reset();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = widget.count > 0;
    final s = S.of(context);

    if (!hasUnread) {
      // Idle: a sunken well, like a real text input carved into the card.
      return Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.w(14), vertical: Responsive.h(10)),
        decoration: neuBox(
          radius: 24,
          pressed: true,
          borderColor: AppColors.kGold.withValues(alpha: 0.35),
        ),
        child: Text(
          s.typeMessage,
          style: TextStyle(color: Colors.white30, fontSize: Responsive.sp(13)),
        ),
      );
    }

    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, _) {
        final t = _shimmer.value;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.w(14), vertical: Responsive.h(10)),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFE8C547), Color(0xFFD4A574)],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: AppColors.kGold.withValues(alpha: 0.9), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.kGold.withValues(alpha: 0.35),
                blurRadius: 14,
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Shimmer sweep overlay — bright streak slides L -> R.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Transform.translate(
                      offset: Offset(380 * (t * 1.4 - 0.4), 0),
                      child: Transform.rotate(
                        angle: 0.25,
                        child: Container(
                          width: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                Colors.white.withValues(alpha: 0.55),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_rounded,
                        color: Colors.black, size: Responsive.sp(14)),
                    SizedBox(width: Responsive.w(8)),
                    Flexible(
                      child: Text(
                        s.newMessagesFromDriver(widget.count),
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: Responsive.sp(13),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
