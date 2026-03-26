import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/mapbox_config.dart';
import '../../config/page_transitions.dart';
import '../../models/lat_lng.dart';
import '../../widgets/verified_avatar.dart';
import 'driver_trip_accept_screen.dart';

/// Full-screen "Viaje Aceptado" confirmation shown after driver accepts a trip.
/// Shows rider info, gold progress bar, then auto-navigates to
/// [DriverTripAcceptScreen] after 3 seconds.
class TripAcceptedScreen extends StatefulWidget {
  const TripAcceptedScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    required this.riderInitials,
    required this.riderRating,
    required this.pickupAddress,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.dropoffAddress,
    required this.fare,
    required this.vehicleType,
    required this.driverPos,
    required this.distToPickupKm,
    required this.etaMinutes,
    this.riderPhotoUrl,
    this.riderVerified = false,
    this.riderPhone = '',
    this.routePoints,
  });

  final int tripId;
  final String riderName;
  final String riderInitials;
  final String? riderPhotoUrl;
  final bool riderVerified;
  final double riderRating;
  final String pickupAddress;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String dropoffAddress;
  final double fare;
  final String vehicleType;
  final LatLng driverPos;
  final double distToPickupKm;
  final int etaMinutes;
  final String riderPhone;
  final List<LatLng>? routePoints;

  @override
  State<TripAcceptedScreen> createState() => _TripAcceptedScreenState();
}

class _TripAcceptedScreenState extends State<TripAcceptedScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);
  static const _bg = Color(0xFF0A0A0A);
  static const _card = Color(0xFF1A1A1A);

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;
  Timer? _navTimer;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();

    // Auto-navigate to active trip screen after 3 seconds
    _navTimer = Timer(const Duration(seconds: 3), _goToTripScreen);
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _goToTripScreen() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      smoothFadeRoute(
        DriverTripAcceptScreen(
          tripId: widget.tripId,
          riderName: widget.riderName,
          riderPhotoUrl: widget.riderPhotoUrl ?? '',
          riderRating: widget.riderRating,
          pickupLatLng: widget.pickupLatLng,
          dropoffLatLng: widget.dropoffLatLng,
          pickupAddress: widget.pickupAddress,
          dropoffAddress: widget.dropoffAddress,
          fare: widget.fare,
          vehicleType: widget.vehicleType,
          driverPos: widget.driverPos,
          distToPickupKm: widget.distToPickupKm,
          etaMinutes: widget.etaMinutes,
          riderPhone: widget.riderPhone,
          routePoints: widget.routePoints,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    // Mapbox static map URL for blurred background
    final mapUrl = 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '${widget.pickupLatLng.longitude},${widget.pickupLatLng.latitude},14,0/600x800@2x'
        '?access_token=${MapboxConfig.accessToken}';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg,
        body: FadeTransition(
          opacity: _fadeAnim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Blurred static map background
              Image.network(
                mapUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: _bg),
              ),
              // Blur + dark overlay
              BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(color: Colors.black.withValues(alpha: 0.65)),
              ),
              // Content
              SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),

                // ── Gold check circle ──
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.elasticOut,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _gold.withValues(alpha: 0.15),
                      border: Border.all(color: _gold, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.3),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: _gold,
                      size: 36,
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── Title ──
                const Text(
                  'Viaje Aceptado',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 8),

                // ── Subtitle ──
                Text(
                  '${widget.riderName.split(' ').first} está esperando',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 16,
                  ),
                ),

                const SizedBox(height: 40),

                // ── Rider info card ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.2),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.08),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        // Rider avatar
                        VerifiedAvatar(
                          uid: widget.tripId.toString(),
                          fallbackName: widget.riderInitials,
                          photoUrl: widget.riderPhotoUrl,
                          isVerified: widget.riderVerified,
                          radius: 28,
                        ),
                        const SizedBox(width: 12),
                        // Rider info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.riderName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.star_rounded,
                                      color: _gold, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.riderRating.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    '${widget.etaMinutes} min · ${widget.distToPickupKm.toStringAsFixed(1)} km',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── Pickup address pill ──
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _gold.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_on_rounded,
                          color: _gold, size: 16),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.pickupAddress,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                const Spacer(flex: 3),

                // ── Gold progress bar (fills over 3 seconds) ──
                Padding(
                  padding: EdgeInsets.fromLTRB(32, 0, 32, 16 + bottomPad),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(seconds: 3),
                    curve: Curves.easeInOut,
                    builder: (_, value, __) => ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: value,
                        backgroundColor: Colors.white12,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(_gold),
                        minHeight: 3,
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
      ),
    );
  }
}
