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
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
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
              // Plate + vehicle
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: Responsive.w(10), vertical: Responsive.h(4)),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.vehiclePlate.isNotEmpty
                          ? widget.vehiclePlate.toUpperCase()
                          : '---',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: Responsive.sp(13),
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  if (vehicleLabel.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      vehicleLabel,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: Responsive.sp(10)),
                    ),
                  ],
                ],
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
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(horizontal: Responsive.w(14), vertical: Responsive.h(10)),
                        decoration: BoxDecoration(
                          color: const Color(0xFF262626),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: AppColors.kGold.withValues(alpha: 0.7), width: 1.2),
                        ),
                        child: Text(
                          S.of(context).typeMessage,
                          style: TextStyle(color: Colors.white30, fontSize: Responsive.sp(13)),
                        ),
                      ),
                      if (widget.tripId != null)
                        Positioned(
                          right: -4, top: -4,
                          child: StreamBuilder<int>(
                            stream: ChatService().unreadCountStream(
                              rideId: widget.tripId.toString(),
                              readerRole: 'rider',
                            ),
                            builder: (context, snap) {
                              final count = snap.data ?? 0;
                              if (count == 0) return const SizedBox.shrink();
                              return TweenAnimationBuilder<double>(
                                key: ValueKey(count),
                                tween: Tween(begin: 0.0, end: 1.0),
                                duration: const Duration(milliseconds: 400),
                                curve: Curves.elasticOut,
                                builder: (context, scale, child) =>
                                    Transform.scale(scale: scale, child: child),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEF4444),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                                  child: Text(
                                    count > 9 ? '9+' : '$count',
                                    style: const TextStyle(
                                      color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: Responsive.w(40), height: Responsive.w(40),
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.kGold.withValues(alpha: 0.7), width: 1.2),
        ),
        child: Icon(icon, color: Colors.white60, size: Responsive.sp(18)),
      ),
    );
  }

  /// Call the driver — launches native phone dialer directly.
  void _handleCallDriver() {
    final phone = widget.driverPhone;
    final name = nh.displayName(widget.driverName, widget.rideName);
    if (phone == null || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${S.of(context).phoneNotAvailable} - $name'),
          // Uses global snackBarTheme
        ),
      );
      return;
    }

    launchUrl(
      Uri.parse('tel:$phone'),
      mode: LaunchMode.externalApplication,
    );
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
    return GestureDetector(
      onTap: () => _setState(() => _showMoreMenu = !_showMoreMenu),
      child: Container(
        width: Responsive.w(40), height: Responsive.w(40),
        decoration: BoxDecoration(
          color: _showMoreMenu ? const Color(0xFF333333) : const Color(0xFF262626),
          shape: BoxShape.circle,
          border: Border.all(color: _showMoreMenu ? AppColors.kGold.withValues(alpha: 0.8) : AppColors.kGold.withValues(alpha: 0.7), width: 1.2),
        ),
        child: Icon(Icons.more_horiz_rounded, color: _showMoreMenu ? AppColors.kGold : Colors.white60, size: Responsive.sp(18)),
      ),
    );
  }

  /// Elegant dropdown menu positioned below the driver card
  Widget _buildMoreMenuOverlay(double topPad) {
    final top = topPad + 10 + _topCardHeight + 8;
    return Positioned(
      top: top,
      right: 16,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, -8 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        ),
        child: Container(
          width: 220,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.kGold.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
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
                'Si cancelas ahora puede aplicar una tarifa de cancelación.',
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
                    _startCancelFlow();
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
    return Positioned(
      top: topPad + 10,
      left: Responsive.w(16),
      child: GestureDetector(
        onTap: _navigateToHome,
        child: Container(
          width: Responsive.w(40), height: Responsive.w(40),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.9),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
              ),
            ],
          ),
          child: Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: Responsive.sp(18)),
        ),
      ),
    );
  }
}
