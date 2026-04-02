import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/verified_avatar.dart';

/// Full-screen confirmation shown to the rider when the driver arrives.
/// The rider presses the big gold button to confirm they are with the driver,
/// then the app fades into the active trip tracking screen.
///
/// If the driver starts the trip first, this screen auto-dismisses with a
/// confirmation message: "Tu driver confirmó que ya estás en el auto".
class RiderConfirmPickupScreen extends StatefulWidget {
  const RiderConfirmPickupScreen({
    super.key,
    required this.driverName,
    required this.vehicleDesc,
    required this.firestoreTripId,
    required this.onConfirmed,
    this.tripId,
    this.driverPhotoUrl,
    this.driverId,
    this.driverRating,
    this.vehiclePlate,
  });

  final String driverName;
  final String vehicleDesc;
  final String? firestoreTripId;
  final int? tripId;
  final String? driverPhotoUrl;
  final String? driverId;
  final double? driverRating;
  final String? vehiclePlate;

  /// Called when the rider presses the confirm button OR when the driver
  /// starts the trip from their side.
  final VoidCallback onConfirmed;

  @override
  State<RiderConfirmPickupScreen> createState() =>
      _RiderConfirmPickupScreenState();
}

class _RiderConfirmPickupScreenState extends State<RiderConfirmPickupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);
  static const _bg = Color(0xFF0d0d1a);

  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  late final AnimationController _rotateCtrl;

  late final AnimationController _fadeOutCtrl;
  late final Animation<double> _fadeOutAnim;

  bool _pressed = false;
  bool _driverStarted = false; // true when driver slides "Start Trip"
  StreamSubscription? _tripSub;

  @override
  void initState() {
    super.initState();

    // Pulse: scale ring 1.0 → 1.06 → 1.0
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Rotating golden glow
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();

    // Fade out on confirm
    _fadeOutCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeOutAnim =
        CurvedAnimation(parent: _fadeOutCtrl, curve: Curves.easeInOut);

    // Listen for driver starting the trip
    _listenForTripStart();
  }

  /// Listen to Firestore for the trip status changing to in_progress/in_trip.
  /// This handles the case where the rider doesn't press the button and the
  /// driver slides "Start Trip" on their end.
  void _listenForTripStart() {
    final fsId = widget.tripId != null
        ? 'sql_${widget.tripId}'
        : widget.firestoreTripId;
    if (fsId == null || fsId.isEmpty) return;

    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(fsId)
        .snapshots()
        .listen((snap) {
      if (!mounted || _pressed || _driverStarted) return;
      final data = snap.data();
      if (data == null) return;

      final status = (data['status'] ?? '').toString().toLowerCase().trim();
      final hasStartedTs = data['startedAt'] != null || data['started_at'] != null;

      if (status == 'in_trip' ||
          status == 'in_progress' ||
          status == 'rider_onboard' ||
          status == 'trip_started' ||
          hasStartedTs) {
        _onDriverStartedTrip();
      }
    });
  }

  /// Called when the driver starts the trip from their side.
  Future<void> _onDriverStartedTrip() async {
    if (_driverStarted || _pressed) return;
    _driverStarted = true;
    HapticFeedback.mediumImpact();
    setState(() {});

    // Show the confirmation message briefly, then dismiss
    await Future.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  @override
  void dispose() {
    _tripSub?.cancel();
    _pulseCtrl.dispose();
    _rotateCtrl.dispose();
    _fadeOutCtrl.dispose();
    super.dispose();
  }

  Future<void> _onConfirmPressed() async {
    if (_pressed || _driverStarted) return;
    _pressed = true;
    HapticFeedback.heavyImpact();
    setState(() {});

    // Write confirmation to Firestore
    final fsId = widget.tripId != null ? 'sql_${widget.tripId}' : widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance.collection('trips').doc(fsId).update({
          'rider_confirmed_pickup': true,
          'confirmed_at': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }

    // Fade out then call callback
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final firstName = widget.driverName.split(' ').first;
    final pad = MediaQuery.of(context).padding;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOutAnim),
        child: Scaffold(
          backgroundColor: _bg,
          body: SizedBox.expand(
            child: Stack(
              children: [
                // ── Subtle gradient overlay (like Photo 2 without map) ──
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFF111122),
                          Color(0xFF0d0d1a),
                          Color(0xFF0d0d1a),
                        ],
                        stops: [0.0, 0.4, 1.0],
                      ),
                    ),
                  ),
                ),

                // ── Centered content (icon + text + card + button) ──
                Positioned.fill(
                  child: SafeArea(
                    child: Column(
                      children: [
                        const Spacer(flex: 3),

                        // ── Gold ring icon ──
                        GestureDetector(
                          onTap: _driverStarted ? null : _onConfirmPressed,
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_pulseCtrl, _rotateCtrl]),
                            builder: (context, child) {
                              final isActive = _pressed || _driverStarted;
                              return Transform.scale(
                                scale: isActive ? 1.0 : _pulseAnim.value,
                                child: SizedBox(
                                  width: 72,
                                  height: 72,
                                  child: CustomPaint(
                                    painter: _GoldenRingPainter(
                                      rotation: _rotateCtrl.value * 2 * math.pi,
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 60,
                                        height: 60,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _bg,
                                          border: Border.all(
                                            color: _gold.withValues(alpha: 0.25),
                                            width: 1,
                                          ),
                                        ),
                                        child: AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 300),
                                          child: _driverStarted
                                              ? Icon(
                                                  Icons.directions_car_rounded,
                                                  key: const ValueKey('car'),
                                                  color: _gold,
                                                  size: 24,
                                                )
                                              : Icon(
                                                  Icons.check_rounded,
                                                  key: const ValueKey('check'),
                                                  color: _pressed ? _gold : Colors.white,
                                                  size: 28,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 18),

                        // ── Title ──
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _driverStarted
                              ? const Text(
                                  'Tu conductor ha confirmado\nque ya estás en el carro',
                                  key: ValueKey('confirmed'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _gold,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    height: 1.3,
                                  ),
                                )
                              : const Text(
                                  'Tu conductor ha llegado',
                                  key: ValueKey('arrived'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _gold,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    height: 1.3,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 8),

                        // ── Subtitle ──
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _driverStarted
                              ? Text(
                                  'El viaje ha comenzado',
                                  key: const ValueKey('sub_started'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.45),
                                    fontSize: 15,
                                  ),
                                )
                              : Text(
                                  '$firstName está esperando',
                                  key: const ValueKey('sub_waiting'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.45),
                                    fontSize: 15,
                                  ),
                                ),
                        ),

                        const Spacer(flex: 3),

                        // ── Driver info card ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF14142a),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _gold.withValues(alpha: 0.18),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                // Driver avatar
                                VerifiedAvatar(
                                  photoUrl: widget.driverPhotoUrl,
                                  uid: widget.driverId,
                                  fallbackName: widget.driverName,
                                  radius: 24,
                                  role: 'driver',
                                  isVerified: true,
                                ),
                                const SizedBox(width: 12),
                                // Name + rating
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.driverName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        widget.vehicleDesc,
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.45),
                                          fontSize: 13,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // ── Confirm button ──
                        if (!_driverStarted && !_pressed) ...[
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: GestureDetector(
                              onTap: _onConfirmPressed,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFE8C547),
                                      Color(0xFFD4AF37),
                                      Color(0xFFC49B30),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _gold.withValues(alpha: 0.25),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.location_on_rounded,
                                      size: 16,
                                      color: Colors.black.withValues(alpha: 0.7),
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      'Presiona cuando estés con el driver',
                                      style: TextStyle(
                                        color: Colors.black87,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],

                        // ── Bottom hint ──
                        if (!_driverStarted) ...[
                          const SizedBox(height: 14),
                          Text(
                            'El viaje comenzará automáticamente\nsi no confirmas',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _gold.withValues(alpha: 0.2),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],

                        SizedBox(height: pad.bottom + 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom painter for the animated rotating golden gradient ring.
class _GoldenRingPainter extends CustomPainter {
  _GoldenRingPainter({required this.rotation});
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.width / 2 - 2;

    final gradient = SweepGradient(
      startAngle: rotation,
      endAngle: rotation + 2 * math.pi,
      colors: const [
        Color(0xFFD4AF37),
        Color(0xFFFBE47A),
        Color(0xFFD4AF37),
        Color(0xFF8B6914),
        Color(0xFFD4AF37),
      ],
      stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
    );

    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;

    canvas.drawCircle(center, radius, paint);

    // Glow effect
    final glowPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    canvas.drawCircle(center, radius, glowPaint);
  }

  @override
  bool shouldRepaint(_GoldenRingPainter old) => old.rotation != rotation;
}
