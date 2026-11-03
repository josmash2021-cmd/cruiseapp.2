part of '../../screens/rider_tracking_screen.dart';

/// Rider cancel policy shown in the post-assignment dialog. Mirrors the
/// backend (backend/routers/trips.py: `minutes_elapsed > 2` → fee 5.0); if
/// that rule changes, change these two and the copy follows.
const int kRiderCancelFreeMinutes = 2;
const String kRiderCancelFeeUsd = '5.00';

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
  /// The category's render (shared with the driver-arrived screen).
  String get _vehicleAsset => vehicleRenderAsset(
      rideName: widget.rideName, model: widget.vehicleModel);

  /// errorBuilder for [_vehicleAsset] renders: the electric PNG is not in
  /// older bundles (Shorebird patches carry no new assets), so it tries the
  /// backend-hosted copy (/static) and then the SUV render bundled since
  /// release — every other asset falls straight to [icon].
  Widget _vehicleImageFallback(Widget icon,
      {double? width, double? height}) {
    if (!_vehicleAsset.endsWith('car_electric.png')) return icon;
    return otaImageFallback(
      'car_electric.png',
      Image.asset(
        'assets/images/cruisert_compact.png',
        width: width,
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => icon,
      ),
      width: width,
      height: height,
    );
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

  // ══════════════════════════════════════════════════════════════════════
  //  THE TRIP SHEET (owner 2026-11-03, drawing J6zTb8hfeKDqfFbzpx5jXb)
  //  Resting semi-open on [_buildSheetFace]; open on [_buildSheetBody], the
  //  driver's whole-trip layout with the rider's data. Mechanics live in
  //  RiderTripSheet.
  // ══════════════════════════════════════════════════════════════════════

  /// The trip's status, in gold over the driver: what the rider does now.
  String get _sheetStatusText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        return s.trackMeetAtPickup;
      case _TrackPhase.arrived:
        return s.trackDriverWaiting;
      case _TrackPhase.onTrip:
        // At the rider's stop the driver waits: said here, not in a
        // floating banner (owner 2026-11-03).
        return _stopWaitSince != null ? s.riderStopWaiting : s.trackOnTheWay;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestination;
      case _TrackPhase.completed:
        return s.tripCompletedTitle;
    }
  }

  /// Color square + "Chevrolet Suburban" (no color word when the square
  /// says it), the category's car render, the plate — whole, never cut. The
  /// same piece the driver-arrived screen shows (vehicle_identity.dart).
  Widget _sheetCarColumn() => VehicleIdentityColumn(
        colorWord: widget.vehicleColor,
        name: '${widget.vehicleMake} ${widget.vehicleModel}'.trim(),
        plate: widget.vehiclePlate,
        asset: _vehicleAsset,
        minWidth: Responsive.w(92),
        maxWidth: Responsive.w(165),
        renderWidth: Responsive.w(92),
        renderHeight: Responsive.h(34),
      );

  /// Photo · "Eduardo R." · ★ 4.9 (· [sub]) · the car.
  Widget _sheetDriverRow({required double avatar, String? sub}) {
    return Row(
      children: [
        VerifiedAvatar(
          photoUrl: _driverPhotoUrl,
          radius: avatar / 2,
          fallbackName: widget.driverName,
          uid: widget.driverId,
          role: 'driver',
          isVerified: true,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // First name + surname initial, "Eduardo R." (owner
              // 2026-11-03): the full name ran off the card.
              Text(
                nh.shortName(widget.driverName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(Icons.star_rounded,
                      color: AppColors.kGold, size: 15),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      sub == null
                          ? widget.driverRating.toStringAsFixed(1)
                          : '${widget.driverRating.toStringAsFixed(1)} · $sub',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _sheetCarColumn(),
      ],
    );
  }

  /// A round action with its name under it; [badge] > 0 adds the gold count.
  Widget _sheetAction({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    int badge = 0,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                child: Icon(icon, color: AppColors.kGold, size: 22),
              ),
              if (badge > 0)
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: AppColors.kGold,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// Subscribes ONCE (from initState) to the driver's unread chat count.
  void _startChatUnreadWatch() {
    final id = widget.tripId;
    if (id == null || _chatUnreadSub != null) return;
    _chatUnreadSub = ChatService()
        .unreadCountStream(rideId: id.toString(), readerRole: 'rider')
        .listen((n) => _chatUnread.value = n, onError: (Object e) {
      debugPrint('[Tracking] chat unread stream error: $e');
    });
  }

  /// The driver's unread chat count (0 off a trip), from the one
  /// subscription above.
  Widget _withChatUnread(Widget Function(int unread) child) =>
      ValueListenableBuilder<int>(
        valueListenable: _chatUnread,
        builder: (context, unread, _) => child(unread),
      );

  /// Chat with the driver. Push first, resolve the id after — awaiting
  /// getCurrentUserId made the tap feel dead for a network round trip.
  void _openDriverChat() {
    if (!mounted) return;
    final nav = _nav;
    if (nav == null) return;
    final userIdFuture = ApiService.getCurrentUserId();
    nav.push(
      chatOpenRoute(
        ChatScreen(
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
  }

  /// "Contactar": write or call the driver.
  Future<void> _showContactDriver() async {
    final s = S.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A21),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 14),
              _withChatUnread((unread) => _buildMenuItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: unread > 0
                        ? '${s.trackMessage} ($unread)'
                        : s.trackMessage,
                    color: AppColors.kGold,
                    onTap: () {
                      Navigator.maybeOf(ctx)?.pop();
                      _openDriverChat();
                    },
                  )),
              _menuDivider(),
              _buildMenuItem(
                icon: Icons.phone_rounded,
                label: s.trackCall,
                color: AppColors.kGold,
                onTap: () {
                  Navigator.maybeOf(ctx)?.pop();
                  unawaited(_handleCallDriver());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The support page inside the open sheet (Safety & Support, add a stop,
  /// change the destination, 911, chat with support).
  void _openSheetSupport() {
    _setState(() => _supportPage = 1);
    _tripSheet.open();
  }

  /// RESTING, semi-open: status · driver with the car · Mensaje · Llamar ·
  /// Compartir · Soporte.
  /// The pickup code for the sheet: the rider's own trip read carries it
  /// (the driver's never does).
  Future<void> _loadSheetPickupPin() async {
    final id = widget.tripId;
    if (id == null) return;
    try {
      final t = await ApiService.getTrip(id);
      if (!mounted) return;
      final pin = (t['pickup_pin'] ?? '').toString().trim().toUpperCase();
      if (pin.length == 4 && pin != _sheetPickupPin) {
        setState(() => _sheetPickupPin = pin);
      }
    } catch (e) {
      debugPrint('[RiderTracking] pickup code failed: $e');
    }
  }

  /// "Código K M T R" at the right of the sheet's status line.
  Widget _sheetPinChip(String pin) {
    final s = S.of(context);
    return Row(
      key: const ValueKey('sheet-pickup-code'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.pickupCodeShort,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            )),
        const SizedBox(width: 6),
        for (final ch in pin.split(''))
          Container(
            width: 22,
            height: 26,
            margin: const EdgeInsets.only(left: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: AppColors.kGold.withValues(alpha: 0.12),
              border: Border.all(
                  color: AppColors.kGold.withValues(alpha: 0.55), width: 1.2),
            ),
            child: Text(ch,
                style: const TextStyle(
                  color: AppColors.kGold,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                )),
          ),
      ],
    );
  }

  Widget _buildSheetFace() {
    final s = S.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).padding.bottom + 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.kGold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _sheetStatusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.kGold,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_sheetPickupPin != null) ...[
                const SizedBox(width: 8),
                _sheetPinChip(_sheetPickupPin!),
              ],
            ],
          ),
          const SizedBox(height: 14),
          _sheetDriverRow(avatar: 56),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _withChatUnread((unread) => _sheetAction(
                      key: const ValueKey('sheet-message'),
                      icon: Icons.chat_bubble_outline_rounded,
                      label: s.trackMessage,
                      badge: unread,
                      onTap: _openDriverChat,
                    )),
                _sheetAction(
                  key: const ValueKey('sheet-call'),
                  icon: Icons.phone_rounded,
                  label: s.trackCall,
                  onTap: () => unawaited(_handleCallDriver()),
                ),
                _sheetAction(
                  key: const ValueKey('sheet-share'),
                  icon: Icons.share_rounded,
                  label: s.trackShare,
                  onTap: () => unawaited(_handleShareTrip()),
                ),
                _sheetAction(
                  key: const ValueKey('sheet-support'),
                  icon: Icons.support_agent_rounded,
                  label: s.trackSupport,
                  onTap: _openSheetSupport,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A gold disc for the list (pickup, stop, destination).
  Widget _sheetGoldDisc(Widget child) => Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFE8C547),
        ),
        alignment: Alignment.center,
        child: child,
      );

  /// One row of the trip list: [lead] on the left with the gold lane marks
  /// down to the next row ([line]), title and line(s) of text on the right.
  Widget _sheetStep({
    required Widget lead,
    required String title,
    String? sub,
    Widget? trailing,
    bool done = false,
    required bool line,
  }) {
    final dim = Colors.white.withValues(alpha: 0.42);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Column(
              children: [
                lead,
                if (line)
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: SizedBox(width: 44, child: RiderLaneDashes()),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: done ? dim : Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (sub != null && sub.trim().isNotEmpty)
                          Text(
                            sub,
                            style: TextStyle(
                              color: done
                                  ? dim
                                  : Colors.white.withValues(alpha: 0.75),
                              fontSize: 15,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// OPEN: the driver's whole-trip layout with the rider's data. The support
  /// and route-change pages replace it inside the same open sheet.
  Widget _buildSheetBody() {
    final Widget page = _supportPage == 0
        ? KeyedSubtree(key: const ValueKey('sheet-trip'), child: _sheetTrip())
        : _supportPage == 1
            ? _buildSupportPanel()
            : _buildRouteChangePanel();
    return AnimatedSize(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubicEmphasized,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 340),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (cur, prev) => Stack(
          alignment: Alignment.topCenter,
          children: [
            for (final p in prev)
              Positioned(left: 0, right: 0, top: 0, child: p),
            if (cur != null) cur,
          ],
        ),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: page,
      ),
    );
  }

  Widget _sheetTrip() {
    final s = S.of(context);
    final onTrip = _phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination ||
        _phase == _TrackPhase.completed;
    final stopLabel = (_committedStopLabel.isNotEmpty
            ? _committedStopLabel
            : widget.stopLabel)
        .trim();
    final hasStop = _committedStop != null || widget.stopLatLng != null;
    final dropLabel = (_committedDropoffLabel.isNotEmpty
            ? _committedDropoffLabel
            : widget.dropoffLabel)
        .trim();
    final fare = _fareOverride ?? widget.price;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CRUISE IN RIDE',
                      style: TextStyle(
                        color: AppColors.kGold,
                        fontSize: 15,
                        letterSpacing: 0.9,
                      ),
                    ),
                    Text(
                      s.trackYourTrip,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (fare > 0)
                      Text(
                        '\$${fare.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      key: const ValueKey('sheet-receipt'),
                      onTap: () {
                        HapticService.selectionClick();
                        unawaited(_openReceipt());
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: AppColors.kGold.withValues(alpha: 0.55)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.receipt_long_rounded,
                                color: AppColors.kGold, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              s.trackReceipt,
                              style: const TextStyle(
                                color: AppColors.kGold,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _sheetAction(
                key: const ValueKey('sheet-open-share'),
                icon: Icons.share_rounded,
                label: s.trackShare,
                onTap: () => unawaited(_handleShareTrip()),
              ),
              const SizedBox(width: 10),
              _withChatUnread((unread) => _sheetAction(
                    key: const ValueKey('sheet-open-contact'),
                    icon: Icons.perm_phone_msg_rounded,
                    label: s.trackContact,
                    badge: unread,
                    onTap: () => unawaited(_showContactDriver()),
                  )),
              const SizedBox(width: 10),
              _sheetAction(
                key: const ValueKey('sheet-open-support'),
                icon: Icons.support_agent_rounded,
                label: s.trackSupport,
                onTap: () => _setState(() => _supportPage = 1),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _sheetStep(
            lead: VerifiedAvatar(
              photoUrl: _driverPhotoUrl,
              radius: 22,
              fallbackName: widget.driverName,
              uid: widget.driverId,
              role: 'driver',
              isVerified: true,
            ),
            title: nh.shortName(widget.driverName),
            sub: '★ ${widget.driverRating.toStringAsFixed(1)} · ${s.trackYourDriver}',
            trailing: _sheetCarColumn(),
            line: true,
          ),
          _sheetStep(
            lead: _sheetGoldDisc(Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Colors.black),
            )),
            title: s.trackPickup,
            sub: widget.pickupLabel,
            done: onTrip,
            line: true,
          ),
          if (hasStop)
            _sheetStep(
              lead: _sheetGoldDisc(const RiderStopPin()),
              title: s.trackStop,
              sub: stopLabel,
              line: true,
            ),
          _sheetStep(
            lead: _sheetGoldDisc(Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(2),
              ),
            )),
            title: s.trackDestination,
            sub: dropLabel,
            line: false,
          ),
          if (_phase != _TrackPhase.completed) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              height: 1,
              color: Colors.white.withValues(alpha: 0.10),
            ),
            GestureDetector(
              key: const ValueKey('sheet-cancel'),
              behavior: HitTestBehavior.opaque,
              onTap: _showCancelDialog,
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFF6B6B).withValues(alpha: 0.16),
                    ),
                    child: const Icon(Icons.block_rounded,
                        color: Color(0xFFFF6B6B)),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    s.cancelRide,
                    style: const TextStyle(
                      color: Color(0xFFFF8A8A),
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
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

  /// "Receipt": what this trip costs, line by line, adding up to the total.
  Future<void> _openReceipt() async {
    final id = widget.tripId;
    if (id == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ReceiptSheet(tripId: id),
    );
  }

  /// Call the driver DIRECTLY on his registered number (user spec
  /// 2026-09-13): the rider's dialer opens with it — no Twilio bridge, no
  /// number masking on the rider side. The masked callback flow stays on
  /// the driver's own call button.
  Future<void> _handleCallDriver() async {
    final name = nh.shortName(widget.driverName);
    final phone = (widget.driverPhone ?? '').trim();
    if (phone.isEmpty) {
      _messenger?.showSnackBar(
        SnackBar(
          content: Text('${S.of(context).phoneNotAvailable} - $name'),
          // Uses global snackBarTheme
        ),
      );
      return;
    }
    HapticService.selectionClick();
    await launchUrl(
      Uri.parse('tel:$phone'),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Share a Google Maps deep-link to the driver's current GPS location.
  /// Falls back to the trip tracking link if driver position is not yet known.
  void _handleShareDriverLocation() {
    final lat = _animPos.latitude;
    final lng = _animPos.longitude;
    final name = nh.shortName(widget.driverName);

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

  /// The support / route-change pages live inside the trip sheet's glass
  /// now (2026-11-03): no shell of their own.
  BoxDecoration get _panelShell => const BoxDecoration();

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
      final Map<String, dynamic> res;
      if (isStop) {
        res = await ApiService.addTripStop(
          tripId: tripId,
          lat: det.lat,
          lng: det.lng,
          label: det.address,
          extraCents: cents,
        );
      } else {
        // From the price as it stands NOW — the booked one plus any earlier
        // change — not from the booked price alone (a second change used to
        // drop the first for trips the server does not reprice).
        final newFare = ((_fareOverride ?? widget.price) + cents / 100.0)
            .clamp(3.0, 500.0)
            .toDouble();
        res = await ApiService.changeTripDestination(
          tripId: tripId,
          lat: det.lat,
          lng: det.lng,
          label: det.address,
          newFare: newFare,
        );
      }
      // The server's price is the price: quoted trips are fully repriced
      // there and our estimate is ignored.
      final serverFare = res['fare'];
      if (!mounted) return;
      HapticService.mediumImpact();
      _setState(() {
        _rcCommitting = false;
        _supportPage = 0;
        // The sheet's price follows the change right away.
        if (serverFare is num && serverFare > 0) {
          _fareOverride = serverFare.toDouble();
        }
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
      _committedDropoffLabel = det.address;
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

  void _showCancelConfirmDialog({String? reason, bool inTrip = false}) {
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
              // Every string goes through S.of (2026-10-29): the title and the
              // "No" button were hardcoded in Spanish while the body followed
              // the device locale, so English phones saw a mixed dialog.
              Text(
                S.of(context).cancelTripConfirm,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                inTrip
                    ? S.of(context).riderCancelInTripBody
                    : S.of(context).cancelAfterAssignBody(
                        freeMinutes: kRiderCancelFreeMinutes,
                        fee: kRiderCancelFeeUsd,
                      ),
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
                    _cancelTripInstantly(reason: reason);
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
                    S.of(context).noContinueTrip,
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
}

/// Chat input pill on the rider tracking driver-info card.
/// - Idle: dark "Type a message..." chip with subtle gold border.
/// - Unread > 0: turns gold, shows "X new message(s) from driver" with
///   a shimmer sweep that loops every 1.8s to draw the eye, plus a
///   small unread counter on the right.

/// The trip's "Receipt" (owner 2026-11-03): every line of the price, adding
/// up to the total — base fare, distance, time, booking fee, and stop, wait,
/// airport, scheduled, discount, tip when they apply; taxes only when one is
/// charged (none is today). Reads GET /trips/{id}/fare-breakdown: its
/// `items` list when the server sends it, the older flat fields otherwise.
class _ReceiptSheet extends StatefulWidget {
  const _ReceiptSheet({required this.tripId});

  final int tripId;

  @override
  State<_ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends State<_ReceiptSheet> {
  Map<String, dynamic>? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ApiService.getFareBreakdown(widget.tripId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _failed = false;
      });
    } catch (e) {
      debugPrint('[Receipt] load failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  static String _money(double v) =>
      '${v < 0 ? '-' : ''}\$${v.abs().toStringAsFixed(2)}';

  /// (label, detail, amount) rows, in order.
  List<(String, String?, double)> _rows(bool es) {
    final d = _data!;
    final items = d['items'];
    if (items is List && items.isNotEmpty) {
      return [
        for (final it in items.whereType<Map>())
          (
            '${(es ? it['label_es'] : it['label_en']) ?? it['key'] ?? ''}',
            it['detail'] == null ? null : '${it['detail']}',
            _num(it['amount']),
          ),
      ];
    }
    // Older server: the flat fields.
    final rows = <(String, String?, double)>[
      (es ? 'Tarifa base' : 'Base fare', null, _num(d['base_fare'])),
      (es ? 'Distancia' : 'Distance', '${_num(d['distance_miles'])} mi',
          _num(d['mileage_charge'])),
      (es ? 'Tiempo' : 'Time', '${_num(d['duration_minutes']).round()} min',
          _num(d['time_charge'])),
    ];
    void add(String es1, String en1, String key) {
      final v = _num(d[key]);
      if (v != 0) rows.add((es ? es1 : en1, null, v));
    }
    add('Tarifa dinámica', 'Surge', 'surge_extra');
    add('Espera', 'Wait time', 'wait_time_charge');
    add('Reserva programada', 'Scheduled ride', 'scheduled_surcharge');
    add('Cargo de aeropuerto', 'Airport fee', 'airport_fee');
    add('Meet & greet', 'Meet & greet', 'meet_greet_fee');
    add('Propina', 'Tip', 'tip_amount');
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final es = Localizations.localeOf(context).languageCode == 'es';
    final bottom = MediaQuery.of(context).padding.bottom;
    Widget line(String label, String? detail, String amount,
        {bool strong = false, Color color = Colors.white}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: label),
                  if (detail != null && detail.isNotEmpty)
                    TextSpan(
                      text: ' · $detail',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ]),
                style: TextStyle(
                  color: color,
                  fontSize: strong ? 20 : 15,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              amount,
              style: TextStyle(
                color: color,
                fontSize: strong ? 20 : 15,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    Widget hr() => Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          height: 1,
          color: Colors.white.withValues(alpha: 0.10),
        );

    final data = _data;
    Widget content;
    if (data == null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: _failed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.receiptUnavailable,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75)),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() => _failed = false);
                        _load();
                      },
                      child: Text(s.retry,
                          style: const TextStyle(color: AppColors.kGold)),
                    ),
                  ],
                )
              : const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: AppColors.kGold),
                ),
        ),
      );
    } else {
      final rows = _rows(es);
      final taxes = (data['taxes'] is List) ? data['taxes'] as List : const [];
      final total = _num(data['total']);
      final subtotal = data['subtotal'] != null && taxes.isNotEmpty
          ? _num(data['subtotal'])
          : null;
      final payment = '${data['payment_method'] ?? data['payment_method_display'] ?? ''}'.trim();
      final number = '${data['receipt_number'] ?? ''}';
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (number.isNotEmpty)
            Text(
              number,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
            ),
          const SizedBox(height: 10),
          for (final r in rows)
            line(r.$1, r.$2, _ReceiptSheetState._money(r.$3)),
          if (subtotal != null) ...[
            hr(),
            line(s.receiptSubtotal, null, _money(subtotal)),
            for (final t in taxes.whereType<Map>())
              line(
                '${(es ? t['label_es'] : t['label_en']) ?? s.receiptTaxes}',
                t['detail'] == null ? null : '${t['detail']}',
                _money(_num(t['amount'])),
              ),
          ],
          hr(),
          line(s.receiptTotal, null, _money(total),
              strong: true, color: AppColors.kGold),
          if (payment.isNotEmpty && data['is_final'] == true) ...[
            const SizedBox(height: 6),
            Text(
              s.receiptPaidWith(payment),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
            ),
          ],
        ],
      );
    }

    return GlassSurface(
      blur: kGlassSheetBlurOpen,
      tint: glassSheetOpenTint,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 10, 22, bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.trackReceipt,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.maybeOf(context)?.pop(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
            Flexible(child: SingleChildScrollView(child: content)),
          ],
        ),
      ),
    );
  }
}
