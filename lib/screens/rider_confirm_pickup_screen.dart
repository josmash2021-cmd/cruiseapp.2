import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  });

  final String driverName;
  final String vehicleDesc;
  final String? firestoreTripId;
  final int? tripId;

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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOutAnim),
        child: Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 48),

                  // ── Title ──
                  Text(
                    _driverStarted
                        ? 'Tu driver confirmó que\nya estás en el auto'
                        : 'Tu conductor ha llegado',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ── Driver name + vehicle ──
                  Text(
                    '$firstName · ${widget.vehicleDesc}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 15,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  // ── Center: big circular button ──
                  const Spacer(),
                  GestureDetector(
                    onTap: _driverStarted ? null : _onConfirmPressed,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_pulseCtrl, _rotateCtrl]),
                      builder: (context, child) {
                        final isActive = _pressed || _driverStarted;
                        return Transform.scale(
                          scale: isActive ? 1.08 : _pulseAnim.value,
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
                                            size: 56,
                                          )
                                        : Icon(
                                            Icons.check_rounded,
                                            key: const ValueKey('check'),
                                            color: _pressed
                                                ? _gold
                                                : Colors.white,
                                            size: 64,
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
                  const SizedBox(height: 28),

                  // ── Instruction text ──
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: _driverStarted
                        ? Text(
                            'El viaje ha comenzado',
                            key: const ValueKey('started'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : Text(
                            'Presiona cuando estés\ncon el driver',
                            key: const ValueKey('waiting'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                  ),
                  const Spacer(),

                  // ── Bottom hint ──
                  if (!_driverStarted)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'El viaje comenzará automáticamente\nsi no confirmas',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  const SizedBox(height: 36),
                ],
              ),
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
