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
      // Raised neumorphic card (shared system — see neu_style.dart).
      decoration: neuBox(radius: 24),
      padding: EdgeInsets.all(Responsive.w(14)),
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
                    final nav = Navigator.of(context);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${S.of(context).phoneNotAvailable} - $name'),
          // Uses global snackBarTheme
        ),
      );
      return;
    }

    final ok = await MaskedCallService.callCounterparty(tripId: tripId, role: 'rider');
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
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
      onTap: () => _setState(() => _showMoreMenu = !_showMoreMenu),
      child: Container(
        width: d, height: d,
        // Open state pops OUT of the well (pressed: false) so the button
        // visibly holds the menu it opened.
        decoration: neuBox(
          radius: d / 2,
          pressed: !_showMoreMenu,
          borderColor: AppColors.kGold
              .withValues(alpha: _showMoreMenu ? 0.8 : 0.35),
        ),
        // Support agent, not three dots: this is where the rider reaches
        // help, and an ellipsis promises nothing.
        child: Icon(Icons.support_agent_rounded,
            color: AppColors.kGold, size: Responsive.sp(18)),
      ),
    );
  }

  /// Menu that opens UPWARD from the driver card, which now lives at the
  /// bottom of the screen. It used to drop down from the top card.
  Widget _buildMoreMenuOverlay(double bottomPad) {
    final bottom = bottomPad + 16 + _bottomCardHeight + 8;
    return Positioned(
      bottom: bottom,
      right: 16,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        // Rises into place (+8 → 0) instead of dropping, matching the
        // direction it now opens from.
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        ),
        child: Container(
          width: 220,
          decoration: neuBox(
            radius: 16,
            borderColor: AppColors.kGold.withValues(alpha: 0.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMenuItem(
                icon: Icons.report_problem_outlined,
                label: S.of(context).problemWithTrip,
                color: AppColors.kGold,
                onTap: () {
                  _setState(() => _showMoreMenu = false);
                  _openSupportChat();
                },
              ),
              _menuDivider(),
              _buildMenuItem(
                icon: Icons.edit_location_alt_outlined,
                label: S.of(context).changeDestination,
                color: AppColors.kGold,
                onTap: () {
                  _setState(() => _showMoreMenu = false);
                  _requestDestinationChange();
                },
              ),
              _menuDivider(),
              // Red, and last of the urgent group: 911 is not a thing to
              // hit by accident while reaching for support.
              _buildMenuItem(
                icon: Icons.emergency_outlined,
                label: S.of(context).call911,
                color: const Color(0xFFEF4444),
                onTap: () {
                  _setState(() => _showMoreMenu = false);
                  _callEmergency();
                },
              ),
              _menuDivider(),
              _buildMenuItem(
                icon: Icons.headset_mic_outlined,
                label: S.of(context).contactSupport,
                color: AppColors.kGold,
                onTap: () {
                  _setState(() => _showMoreMenu = false);
                  _openSupportChat();
                },
              ),
            ],
          ),
        ),
      ),
    );
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
                    _requestCancelViaSupport();
                  },
                  child: Text(S.of(context).sendCancellationRequest, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
    Navigator.of(context).push(
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
