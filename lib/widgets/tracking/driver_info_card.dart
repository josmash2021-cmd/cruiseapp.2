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
          color: const Color(0xFFD4AF37), fontSize: Responsive.sp(18), fontWeight: FontWeight.w700,
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
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
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
                  color: Color(0xFFD4AF37),
                ),
              ),
              SizedBox(width: Responsive.w(8)),
              Flexible(
                child: Text(
                  statusLabel,
                  style: TextStyle(color: const Color(0xFFD4AF37), fontSize: Responsive.sp(11), fontWeight: FontWeight.w600, letterSpacing: 0.6),
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
                photoUrl: widget.driverPhotoUrl,
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
                        Icon(Icons.star_rounded, color: const Color(0xFFD4AF37), size: Responsive.sp(14)),
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
                  onTap: () => Navigator.of(context).push(
                    slideFromRightRoute(
                      ChatScreen(
                        recipientName: widget.driverName.split(' ').first,
                        avatarInitial: widget.driverName.isNotEmpty
                            ? widget.driverName[0].toUpperCase()
                            : 'D',
                        tripId: widget.tripId,
                        currentRole: 'rider',
                      ),
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(horizontal: Responsive.w(14), vertical: Responsive.h(10)),
                        decoration: BoxDecoration(
                          color: const Color(0xFF262626),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                        ),
                        child: Text(
                          S.of(context).typeMessage,
                          style: TextStyle(color: Colors.white30, fontSize: Responsive.sp(13)),
                        ),
                      ),
                      if (widget.tripId != null)
                        StreamBuilder<int>(
                          stream: ChatService().unreadCountStream(
                            rideId: widget.tripId.toString(),
                            readerRole: 'rider',
                          ),
                          builder: (context, snap) {
                            final count = snap.data ?? 0;
                            if (count == 0) return const SizedBox.shrink();
                            return Positioned(
                              right: -4, top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
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
                    ],
                  ),
                ),
              ),
              SizedBox(width: Responsive.w(8)),
              _buildCardIconBtn(icon: Icons.phone_rounded, onTap: _handleCallDriver),
              SizedBox(width: Responsive.w(8)),
              _buildCardIconBtn(
                icon: Icons.share_rounded,
                onTap: _handleShareDriverLocation,
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
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
          content: Text('Phone number not available for $name'),
          backgroundColor: const Color(0xFF1A1A1A),
          behavior: SnackBarBehavior.floating,
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
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      color: const Color(0xFF1a1a2e),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFc8a951), width: 1),
      ),
      onSelected: (value) {
        if (value == 'cancel') {
          _showCancelConfirmDialog();
        } else if (value == 'support') {
          _openSupportChat();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: 'cancel',
          child: Row(
            children: const [
              Icon(Icons.cancel_outlined, color: Color(0xFFef4444), size: 20),
              SizedBox(width: 12),
              Text('Cancelar viaje',
                style: TextStyle(color: Color(0xFFef4444), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'support',
          child: Row(
            children: const [
              Icon(Icons.headset_mic_outlined, color: Color(0xFFc8a951), size: 20),
              SizedBox(width: 12),
              Text('Contactar soporte',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
      child: Container(
        width: Responsive.w(40), height: Responsive.w(40),
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Icon(Icons.more_horiz_rounded, color: Colors.white60, size: Responsive.sp(18)),
      ),
    );
  }

  void _showCancelConfirmDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFc8a951), width: 1),
        ),
        title: const Text(
          '¿Cancelar viaje?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        content: const Text(
          'Si cancelas ahora puede aplicar '
          'una tarifa de cancelación.',
          style: TextStyle(color: Colors.grey, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No, continuar',
              style: TextStyle(color: Color(0xFFc8a951))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFef4444),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              LocalDataService.clearActiveRide();
              if (widget.tripId != null) {
                try {
                  await ApiService.cancelTrip(widget.tripId!);
                } catch (_) {}
              }
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) => const HomeScreen(),
                  transitionsBuilder: (_, a, __, child) =>
                      FadeTransition(opacity: a, child: child),
                  transitionDuration: const Duration(milliseconds: 400),
                ),
                (_) => false,
              );
            },
            child: const Text('Sí, cancelar',
              style: TextStyle(color: Colors.white)),
          ),
        ],
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
