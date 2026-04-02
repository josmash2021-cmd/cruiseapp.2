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

    // Show confirmed animation briefly, then transition
    await Future.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final firstName = widget.driverName.split(' ').first;
    final pad = MediaQuery.of(context).padding;
    final isConfirmed = _pressed || _driverStarted;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOutAnim),
        child: Scaffold(
          backgroundColor: _bg,
          body: SizedBox.expand(
            child: Stack(
              children: [
                // ── Subtle gradient overlay ──
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

                // ── Main content ──
                Positioned.fill(
                  child: SafeArea(
                    child: Column(
                      children: [
                        SizedBox(height: pad.top + 20),

                        // ── Top title ──
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 400),
                          child: isConfirmed
                              ? Text(
                                  _driverStarted
                                      ? 'Tu conductor ha confirmado\nque ya estás en el carro'
                                      : '¡Viaje confirmado!',
                                  key: ValueKey('title_${_driverStarted ? 'driver' : 'rider'}_confirmed'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    height: 1.3,
                                  ),
                                )
                              : const Text(
                                  'Tu conductor ha llegado',
                                  key: ValueKey('title_arrived'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                        ),
                        if (!isConfirmed) ...[
                          const SizedBox(height: 6),
                          Text(
                            '$firstName está esperando',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.40),
                              fontSize: 14,
                            ),
                          ),
                        ],

                        const Spacer(),

                        // ── Large gold ring CTA ──
                        GestureDetector(
                          onTap: isConfirmed ? null : _onConfirmPressed,
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_pulseCtrl, _rotateCtrl]),
                            builder: (context, child) {
                              return AnimatedScale(
                                scale: _pressed ? 0.92 : (isConfirmed ? 1.0 : _pulseAnim.value),
                                duration: const Duration(milliseconds: 500),
                                curve: Curves.easeOutCubic,
                                child: SizedBox(
                                  width: 200,
                                  height: 200,
                                  child: CustomPaint(
                                    painter: _GoldenRingPainter(
                                      rotation: _rotateCtrl.value * 2 * math.pi,
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 180,
                                        height: 180,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isConfirmed
                                              ? _gold.withValues(alpha: 0.12)
                                              : _bg,
                                          border: Border.all(
                                            color: isConfirmed
                                                ? _gold.withValues(alpha: 0.5)
                                                : _gold.withValues(alpha: 0.15),
                                            width: isConfirmed ? 2.0 : 1.0,
                                          ),
                                        ),
                                        child: AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 400),
                                          switchInCurve: Curves.easeOutBack,
                                          child: isConfirmed
                                              ? Column(
                                                  key: const ValueKey('confirmed_content'),
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(
                                                      Icons.check_circle_rounded,
                                                      color: _gold,
                                                      size: 52,
                                                    ),
                                                    const SizedBox(height: 10),
                                                    Text(
                                                      _driverStarted
                                                          ? 'Tu viaje\nconfirmado'
                                                          : 'Tu viaje\nconfirmado',
                                                      textAlign: TextAlign.center,
                                                      style: const TextStyle(
                                                        color: _gold,
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w700,
                                                        height: 1.3,
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : Column(
                                                  key: const ValueKey('cta_content'),
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    const Icon(
                                                      Icons.check_rounded,
                                                      color: Colors.white,
                                                      size: 40,
                                                    ),
                                                    const SizedBox(height: 12),
                                                    Text(
                                                      'Presiona para\ncomenzar tu viaje\nhacia tu destino',
                                                      textAlign: TextAlign.center,
                                                      style: TextStyle(
                                                        color: Colors.white.withValues(alpha: 0.60),
                                                        fontSize: 13,
                                                        fontWeight: FontWeight.w500,
                                                        height: 1.4,
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
                            },
                          ),
                        ),

                        const Spacer(),

                        // ── Driver info card (always visible) ──
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
                                // Driver avatar (always shows photo)
                                VerifiedAvatar(
                                  photoUrl: widget.driverPhotoUrl,
                                  uid: widget.driverId,
                                  fallbackName: widget.driverName,
                                  radius: 24,
                                  role: 'driver',
                                  isVerified: true,
                                ),
                                const SizedBox(width: 12),
                                // Name + vehicle
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
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.star_rounded,
                                            size: 14,
                                            color: _gold,
                                          ),
                                          const SizedBox(width: 3),
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
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // ── Bottom hint ──
                        if (!isConfirmed) ...[
                          const SizedBox(height: 14),
                          Text(
                            'El viaje comenzará automáticamente\nsi no confirmas',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _gold.withValues(alpha: 0.55),
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
