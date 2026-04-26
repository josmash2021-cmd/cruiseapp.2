import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/verified_avatar.dart';
import '../l10n/app_localizations.dart';

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
    this.rideTier,
    this.isAirportTrip = false,
  });

  final String driverName;
  final String vehicleDesc;
  final String? firestoreTripId;
  final int? tripId;
  final String? driverPhotoUrl;
  final String? driverId;
  final double? driverRating;
  final String? vehiclePlate;
  /// Optional: 'standard' | 'premium' | 'vip'. If null we infer from vehicleDesc.
  final String? rideTier;
  /// Airport rides get a longer free wait window (10 min) regardless of tier.
  final bool isAirportTrip;

  /// Called when the rider presses the confirm button OR when the driver
  /// starts the trip from their side.
  final VoidCallback onConfirmed;

  @override
  State<RiderConfirmPickupScreen> createState() =>
      _RiderConfirmPickupScreenState();
}

class _RiderConfirmPickupScreenState extends State<RiderConfirmPickupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF000000);

  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  late final AnimationController _rotateCtrl;

  late final AnimationController _fadeInCtrl;
  late final Animation<double> _fadeInAnim;

  late final AnimationController _fadeOutCtrl;
  late final Animation<double> _fadeOutAnim;

  // Ripple wave animations (3 staggered rings)
  late final AnimationController _ripple1Ctrl;
  late final AnimationController _ripple2Ctrl;
  late final AnimationController _ripple3Ctrl;

  // Hand tap animation
  late final AnimationController _handCtrl;
  late final Animation<double> _handScale;
  late final Animation<double> _handOpacity;

  bool _pressed = false;
  bool _driverStarted = false; // true when driver slides "Start Trip"
  StreamSubscription? _tripSub;

  // ── Wait time fee tracking (Uber/Lyft style) ──
  // Per-tier policy. Airport overrides tier with a longer 10 min free window.
  // Free wait counts DOWN (green); after it expires we count UP and accrue
  // a per-minute charge that will be added to the final fare. Auto-cancel
  // is enforced by the backend / dispatch — this UI only displays state.
  late final int _freeWaitSec;
  late final double _waitFeePerMin;
  late final int _autoCancelSec;
  Timer? _waitTimer;
  // Seconds elapsed since the driver arrived. Drives both the count-down
  // (while < _freeWaitSec) and the count-up (while >= _freeWaitSec).
  int _waitElapsedSec = 0;

  @override
  void initState() {
    super.initState();

    // ── Wait time policy per tier (Uber/Lyft inspired) ──
    final tier = (widget.rideTier ?? _inferTierFromVehicleDesc(widget.vehicleDesc));
    if (widget.isAirportTrip) {
      _freeWaitSec = 10 * 60;
      _waitFeePerMin = 0.40;
      _autoCancelSec = 20 * 60;
    } else {
      switch (tier) {
        case 'vip':
          _freeWaitSec = 5 * 60;
          _waitFeePerMin = 1.00;
          _autoCancelSec = 15 * 60;
          break;
        case 'premium':
          _freeWaitSec = 3 * 60;
          _waitFeePerMin = 0.60;
          _autoCancelSec = 10 * 60;
          break;
        default: // standard
          _freeWaitSec = 2 * 60;
          _waitFeePerMin = 0.40;
          _autoCancelSec = 5 * 60;
      }
    }
    // 1 Hz tick — cheap, drives both phases of the timer.
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _pressed || _driverStarted) return;
      setState(() => _waitElapsedSec++);
    });

    // Content fade-in
    _fadeInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeInAnim = CurvedAnimation(parent: _fadeInCtrl, curve: Curves.easeOut);
    _fadeInCtrl.forward();

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
      duration: const Duration(milliseconds: 600),
    );
    _fadeOutAnim =
        CurvedAnimation(parent: _fadeOutCtrl, curve: Curves.easeInOut);

    // Ripple waves — 3 staggered expanding rings
    _ripple1Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _ripple2Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _ripple3Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    // Stagger ripple 2 and 3
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && !_pressed && !_driverStarted) _ripple2Ctrl.repeat();
    });
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && !_pressed && !_driverStarted) _ripple3Ctrl.repeat();
    });

    // Hand tap animation — realistic press-down gesture
    _handCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
    // Finger presses down then lifts with a natural bounce
    _handScale = TweenSequence<double>([
      // Hover / approach
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.96).chain(CurveTween(curve: Curves.easeIn)), weight: 12),
      // Press down firmly
      TweenSequenceItem(tween: Tween(begin: 0.96, end: 0.78).chain(CurveTween(curve: Curves.easeInQuart)), weight: 14),
      // Hold pressed
      TweenSequenceItem(tween: ConstantTween(0.78), weight: 8),
      // Lift off with bounce
      TweenSequenceItem(tween: Tween(begin: 0.78, end: 1.04).chain(CurveTween(curve: Curves.easeOutBack)), weight: 18),
      // Settle
      TweenSequenceItem(tween: Tween(begin: 1.04, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 8),
      // Pause before next tap
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
    ]).animate(_handCtrl);
    _handOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 0.95), weight: 12),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 14),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 8),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.85), weight: 18),
      TweenSequenceItem(tween: Tween(begin: 0.85, end: 0.6), weight: 8),
      TweenSequenceItem(tween: ConstantTween(0.6), weight: 40),
    ]).animate(_handCtrl);

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
      final hasStartedTs = data['startedAt'] != null || data['started_at'] != null || data['rideStartedAt'] != null;

      if (status == 'in_trip' ||
          status == 'in_progress' ||
          status == 'rider_onboard' ||
          status == 'trip_started' ||
          hasStartedTs) {
        _onDriverStartedTrip();
      }
    });
  }

  /// Called when the driver starts the ride from their side.
  /// Auto-presses the button and shows "Viaje confirmado".
  Future<void> _onDriverStartedTrip() async {
    if (_driverStarted || _pressed) return;
    _driverStarted = true;
    HapticFeedback.mediumImpact();
    // Stop hint animations like manual press does
    _handCtrl.stop();
    _ripple1Ctrl.stop();
    _ripple2Ctrl.stop();
    _ripple3Ctrl.stop();
    setState(() {});

    // Let the rider read "¡Viaje confirmado!"
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  /// Visual badge shown under the gold confirm circle. Counts down the
  /// free wait time in green, then switches to a red count-up + accrued
  /// fee once the rider passes the per-tier threshold. Pure UI — no
  /// charge happens client-side; the backend will compute the final
  /// wait fee once the trip ends (Opción B en roadmap).
  Widget _buildWaitTimerBadge() {
    final isFreePhase = _waitElapsedSec < _freeWaitSec;
    final freeRemaining = (_freeWaitSec - _waitElapsedSec).clamp(0, _freeWaitSec);
    final extraSec = (_waitElapsedSec - _freeWaitSec).clamp(0, 99 * 60);
    // Charge by the minute, started + rounded up so the rider sees the
    // first $X.XX appear the moment the free window closes.
    final extraMin = (extraSec / 60).ceil();
    final extraFee = (extraMin * _waitFeePerMin);

    String fmt(int totalSec) {
      final m = (totalSec ~/ 60).toString();
      final s = (totalSec % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    if (isFreePhase) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1A12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF22C55E).withValues(alpha: 0.40),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.schedule_rounded,
                color: Color(0xFF22C55E), size: 18),
            const SizedBox(width: 8),
            Text(
              'Free wait time',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              fmt(freeRemaining),
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Color(0xFF22C55E),
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      );
    }

    // Extra fee phase — count UP, accrued $ visible, gentle pulse.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1.0),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOut,
      builder: (_, t, child) => Opacity(
        opacity: 0.85 + 0.15 * (1 - (t - 0.925).abs() * 13).clamp(0.0, 1.0),
        child: child,
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A0E0E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFEF4444).withValues(alpha: 0.55),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFEF4444).withValues(alpha: 0.18),
              blurRadius: 14,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_rounded,
                    color: Color(0xFFEF4444), size: 16),
                const SizedBox(width: 6),
                Text(
                  'Extra wait fee active',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '+${fmt(extraSec)}',
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFFEF4444),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFEF4444),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '+\$${extraFee.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFFEF4444),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Best-effort tier inference from the vehicle description string.
  /// Caller should pass `rideTier` explicitly when possible — this is a
  /// fallback so the timer always picks a sensible policy.
  String _inferTierFromVehicleDesc(String desc) {
    final d = desc.toLowerCase();
    if (d.contains('suburban') || d.contains('escalade') || d.contains('vip') ||
        d.contains('black')) return 'vip';
    if (d.contains('camry') || d.contains('accord') || d.contains('premium')) {
      return 'premium';
    }
    return 'standard';
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _tripSub?.cancel();
    _pulseCtrl.dispose();
    _rotateCtrl.dispose();
    _fadeInCtrl.dispose();
    _fadeOutCtrl.dispose();
    _ripple1Ctrl.dispose();
    _ripple2Ctrl.dispose();
    _ripple3Ctrl.dispose();
    _handCtrl.dispose();
    super.dispose();
  }

  Future<void> _onConfirmPressed() async {
    if (_pressed || _driverStarted) return;
    _pressed = true;
    HapticFeedback.heavyImpact();
    // Stop hint animations
    _handCtrl.stop();
    _ripple1Ctrl.stop();
    _ripple2Ctrl.stop();
    _ripple3Ctrl.stop();
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
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  /// Builds a single expanding + fading golden ripple ring.
  Widget _buildRippleRing(double progress) {
    final size = 200 + (80 * progress); // expands from 200 to 280
    final opacity = (1.0 - progress).clamp(0.0, 0.35); // fades out as it expands
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: _gold.withValues(alpha: opacity),
          width: 2.0 - (progress * 1.2), // thins as it expands
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final firstName = widget.driverName.split(' ').first;
    final pad = MediaQuery.of(context).padding;
    final isConfirmed = _pressed || _driverStarted;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: _fadeInAnim,
        child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOutAnim),
        child: Scaffold(
          backgroundColor: _bg,
          body: SizedBox.expand(
            child: Stack(
              children: [
                // ── Pure black background (no gradient) ──
                const Positioned.fill(
                  child: ColoredBox(color: Colors.black),
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
                                  S.of(context).tripConfirmedExclaim,
                                  key: const ValueKey('title_confirmed'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    height: 1.3,
                                  ),
                                )
                              : Text(
                                  S.of(context).yourDriverHasArrived,
                                  key: const ValueKey('title_arrived'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                        ),
                        AnimatedOpacity(
                          opacity: isConfirmed ? 0.0 : 1.0,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOut,
                          child: AnimatedSlide(
                            offset: isConfirmed ? const Offset(0, -0.3) : Offset.zero,
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOut,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 6),
                                Text(
                                  S.of(context).driverIsWaiting(firstName),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.40),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const Spacer(),

                        // ── Large gold ring CTA with ripple waves + hand hint ──
                        SizedBox(
                          width: 280,
                          height: 280,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Ripple waves — fade out smoothly on confirm
                              AnimatedOpacity(
                                opacity: isConfirmed ? 0.0 : 1.0,
                                duration: const Duration(milliseconds: 500),
                                curve: Curves.easeOut,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    AnimatedBuilder(
                                      animation: _ripple1Ctrl,
                                      builder: (_, __) => _buildRippleRing(_ripple1Ctrl.value),
                                    ),
                                    AnimatedBuilder(
                                      animation: _ripple2Ctrl,
                                      builder: (_, __) => _buildRippleRing(_ripple2Ctrl.value),
                                    ),
                                    AnimatedBuilder(
                                      animation: _ripple3Ctrl,
                                      builder: (_, __) => _buildRippleRing(_ripple3Ctrl.value),
                                    ),
                                  ],
                                ),
                              ),
                              // The button
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
                                                            S.of(context).yourTripConfirmed,
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
                                                            S.of(context).pressWhenWithDriver,
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
                              // ── Hand tap hint — fades out on confirm ──
                              Positioned(
                                  bottom: 6,
                                  right: 24,
                                  child: AnimatedBuilder(
                                    animation: _handCtrl,
                                    builder: (_, __) {
                                      final pressProgress = (1.0 - _handScale.value).clamp(0.0, 1.0);
                                      final yOffset = pressProgress * 10.0; // moves down when pressing
                                      final tiltAngle = pressProgress * 0.08; // slight wrist tilt on press
                                      return Transform.translate(
                                        offset: Offset(0, yOffset),
                                        child: Transform.rotate(
                                          angle: -tiltAngle,
                                          alignment: Alignment.bottomCenter,
                                          child: AnimatedOpacity(
                                            opacity: isConfirmed ? 0.0 : _handOpacity.value,
                                            duration: const Duration(milliseconds: 350),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                // The hand
                                                Transform.scale(
                                                  scale: _handScale.value,
                                                  alignment: Alignment.bottomCenter,
                                                  child: const Text(
                                                    '👆',
                                                    style: TextStyle(fontSize: 34),
                                                  ),
                                                ),
                                                // Press shadow — grows when finger is down
                                                Container(
                                                  width: 16 + (pressProgress * 10),
                                                  height: 4 + (pressProgress * 2),
                                                  decoration: BoxDecoration(
                                                    borderRadius: BorderRadius.circular(10),
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: _gold.withValues(alpha: 0.15 + pressProgress * 0.25),
                                                        blurRadius: 6 + (pressProgress * 4),
                                                        spreadRadius: pressProgress * 2,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 18),

                        // ── Wait time fee badge (Uber/Lyft style) ──
                        // Hidden once the rider confirms or the driver
                        // starts the trip. Green count-down for free
                        // wait time, red count-up + per-min fee after.
                        if (!_pressed && !_driverStarted)
                          _buildWaitTimerBadge(),

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
                                // Name + vehicle + rating
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
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.directions_car_rounded,
                                            size: 13,
                                            color: Colors.white.withValues(alpha: 0.35),
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              widget.vehicleDesc,
                                              style: TextStyle(
                                                color: Colors.white.withValues(alpha: 0.55),
                                                fontSize: 13,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          if (widget.driverRating != null) ...[
                                            Icon(Icons.star_rounded, size: 13, color: _gold),
                                            const SizedBox(width: 3),
                                            Text(
                                              widget.driverRating!.toStringAsFixed(1),
                                              style: TextStyle(
                                                color: Colors.white.withValues(alpha: 0.55),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                // License plate pill (right side)
                                if (widget.vehiclePlate != null && widget.vehiclePlate!.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _gold.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: _gold.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Text(
                                      widget.vehiclePlate!,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.8,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),

                        // ── Bottom hint — fades out on confirm ──
                        AnimatedOpacity(
                          opacity: isConfirmed ? 0.0 : 1.0,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOut,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 14),
                              Text(
                                isConfirmed ? '' : S.of(context).rideAutoStartWarning,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _gold.withValues(alpha: 0.55),
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),

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
        Color(0xFFE8C547),
        Color(0xFFFBE47A),
        Color(0xFFE8C547),
        Color(0xFFB08C35),
        Color(0xFFE8C547),
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
