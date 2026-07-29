part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  DRIVER INFO CARD — driver details, avatar, plate
// ════════════════════════════════════════════════════════════

extension _RiderTrackingDriverInfoCard on _RiderTrackingScreenState {

  String get _vehicleAsset {
    final rn = widget.rideName.toLowerCase();
    final m = widget.vehicleModel.toLowerCase();
    if (rn.contains('vip') || rn.contains('suv') || rn.contains('suburban') || m.contains('suburban')) {
      return 'assets/images/car_suv.png';
    }
    if (rn.contains('sedan') || rn.contains('premium') || rn.contains('fusion') || m.contains('fusion')) {
      return 'assets/images/car_sedan.png';
    }
    return 'assets/images/car_economy.png';
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
                    // The car render itself. errorBuilder, not a bare
                    // Image.asset: a missing render must not take the whole
                    // card down mid-trip.
                    Image.asset(
                      _vehicleAsset,
                      height: Responsive.h(30),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.directions_car_rounded,
                        color: AppColors.kGold.withValues(alpha: 0.5),
                        size: Responsive.sp(22),
                      ),
                    ),
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
                    final userId = await ApiService.getCurrentUserId();
                    if (!mounted) return;
                    Navigator.of(context).push(
                      slideFromRightRoute(
                        ChatScreen(
                          recipientName: widget.driverName.split(' ').first,
                          avatarInitial: widget.driverName.isNotEmpty
                              ? widget.driverName[0].toUpperCase()
                              : 'D',
                          tripId: widget.tripId,
                          currentRole: 'rider',
                          currentUserId: userId?.toString(),
                        ),
                      ),
                    );
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
      Share.share(
        'I\'m on a Cruise ride! My driver $name is on the way.\n\n'
        '📍 Live location: $mapsUrl\n\n'
        'From: ${widget.pickupLabel}\n'
        'To: ${widget.dropoffLabel}\n\n'
        'Track my ride in real time!',
        subject: 'My Cruise ride — live tracking',
      );
    } else {
      // Fallback: share pickup/dropoff info
      Share.share(
        'I\'m on a Cruise ride with $name!\n\n'
        'From: ${widget.pickupLabel}\n'
        'To: ${widget.dropoffLabel}\n\n'
        'Powered by Cruise 🚗',
        subject: 'My Cruise ride',
      );
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
        child: Icon(Icons.more_horiz_rounded,
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

  Widget _buildBackButton(double topPad) {
    final d = Responsive.w(40);
    return Positioned(
      top: topPad + 10,
      left: Responsive.w(16),
      child: GestureDetector(
        onTap: _navigateToHome,
        child: Container(
          width: d, height: d,
          // Raised, so it reads as the one thing sitting on the map rather
          // than a hole punched into it.
          decoration: neuBox(radius: d / 2),
          child: Icon(Icons.arrow_back_ios_rounded,
              color: Colors.white, size: Responsive.sp(18)),
        ),
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
