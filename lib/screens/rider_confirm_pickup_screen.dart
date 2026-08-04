import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/page_transitions.dart';
import '../models/lat_lng.dart';
import '../services/haptic_service.dart';
import 'chat_screen.dart';

import '../widgets/verified_avatar.dart';
import '../widgets/neu_style.dart';
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
    this.onCancelled,
    this.tripId,
    this.driverPhotoUrl,
    this.driverId,
    this.driverRating,
    this.vehiclePlate,
    this.rideTier,
    this.isAirportTrip = false,
    this.driverPosOf,
    this.driverPhone,
  });

  /// For the Call round button (Find-My style bottom row).
  final String? driverPhone;

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

  /// Live driver position, read on every rider GPS fix — feeds the compass
  /// arrow, the animated distance readout and the proximity auto-detect.
  /// Null (or a 0,0 reading) keeps the screen in follow-the-arrow copy with
  /// no distance shown.
  final LatLng Function()? driverPosOf;

  /// Called when the rider presses the confirm button OR when the driver
  /// starts the trip from their side.
  final VoidCallback onConfirmed;

  /// Called when the trip is cancelled (e.g., auto-cancel due to wait timeout).
  final VoidCallback? onCancelled;

  @override
  State<RiderConfirmPickupScreen> createState() =>
      _RiderConfirmPickupScreenState();
}

class _RiderConfirmPickupScreenState extends State<RiderConfirmPickupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  // Neumorphic base, not pure black: on #000000 the soft shadows that make
  // the style read simply do not show (see neu_style.dart).
  static const _bg = neuBase;

  late final AnimationController _pulseCtrl;

  late final AnimationController _rotateCtrl;

  late final AnimationController _fadeInCtrl;
  late final Animation<double> _fadeInAnim;

  late final AnimationController _fadeOutCtrl;
  late final Animation<double> _fadeOutAnim;

  // Ripple wave animations (3 staggered rings)
  late final AnimationController _ripple1Ctrl;
  late final AnimationController _ripple2Ctrl;
  late final AnimationController _ripple3Ctrl;

  // Hand tap animation (retired — controller kept for stop paths)
  late final AnimationController _handCtrl;

  // One slow clock for the Find-My particle ring + the animated clock hand.
  late final AnimationController _particleCtrl;

  bool _pressed = false;
  bool _driverStarted = false; // true when driver slides "Start Trip"
  StreamSubscription? _tripSub;

  // ── Proximity auto-detect + compass arrow ──
  // The circle is no longer a button to press: the phone watches its own
  // GPS against the driver's live position, points an arrow at them, and
  // the moment the rider is within ~2.5 m for two consecutive fixes it
  // flips green ("Driver detected") and confirms by itself.
  StreamSubscription<Position>? _riderGpsSub;
  StreamSubscription<CompassEvent>? _compassSub;

  /// Straight-line meters to the driver; negative until both fixes exist.
  double _distanceM = -1;

  /// Bearing rider→driver, degrees clockwise from true north.
  double _bearingToDriver = 0;

  /// Device compass heading (degrees). 0 when the device has no
  /// magnetometer — the arrow then points north-referenced.
  double _heading = 0;

  bool _driverDetected = false;
  int _closeFixes = 0;
  static const double _kDetectMeters = 2.5;

  /// Screen-space angle (radians) the particle crescent is CURRENTLY
  /// facing. Eased toward the arrow's live direction a little every frame
  /// (shortest arc), so the dust swings with the needle instead of
  /// snapping — mutated inside the ring's per-frame builder, no setState.
  double _crescentAngle = -math.pi / 2;

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
    //
    // rideTier arrives as whatever the caller had on hand: a picker
    // display name ('SUV XL', 'VIP', 'BLACK'), a backend vehicle_type
    // ('black', 'suv_xl') on resume paths, or a legacy tier key. Left
    // raw, the switch below matched only exact 'vip'/'premium' and every
    // Black/SUV XL trip fell to the standard 2-min/$0.40 policy while
    // the backend charged the 5-min/$1.00 one (trips.py
    // _WAIT_POLICY_BY_TYPE). Normalize onto the backend's groups first.
    final tier = _normalizeWaitTier(
        widget.rideTier ?? '', widget.vehicleDesc);
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

    // Pulse: scale ring 1.0 → 1.06 → 1.0. NOT started — the disc it drove
    // was replaced by the Find-My particle ring; kept constructed so every
    // stop()/dispose() path stays valid.
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    // Rotating golden glow — same: constructed, not started.
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    // The Find-My particle ring + the little clock hand both breathe off
    // this one slow clock: 12 s per cycle, repeating — drift, twinkle and
    // needle sweep all derive from its value, one ticker for everything.
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    // Fade out on confirm
    _fadeOutCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeOutAnim =
        CurvedAnimation(parent: _fadeOutCtrl, curve: Curves.easeInOut);

    // Ripple waves — retired with the pressable disc; constructed only so
    // the stop()/dispose() paths stay valid.
    _ripple1Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _ripple2Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _ripple3Ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    // Hand tap animation — retired: nothing is pressable any more.
    _handCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    // Listen for driver starting the trip
    _listenForTripStart();

    // Proximity + compass — the smart replacement for the press.
    _startProximityWatch();
  }

  /// Watch the rider's own GPS against the driver's live position: keep the
  /// arrow pointed, the distance readout fresh, and auto-confirm the moment
  /// two consecutive fixes land within [_kDetectMeters].
  void _startProximityWatch() {
    if (kIsWeb) return; // browser GPS is too coarse to point or detect with
    if (widget.driverPosOf == null) return;

    // Compass heading (magnetometer). Some devices have none — events just
    // never arrive and the arrow stays north-referenced.
    try {
      _compassSub = FlutterCompass.events?.listen((event) {
        final h = event.heading;
        if (h == null || !mounted) return;
        if ((h - _heading).abs() > 1.5) setState(() => _heading = h);
      });
    } catch (_) {}

    _riderGpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      if (!mounted || _pressed || _driverStarted) return;
      final driver = widget.driverPosOf!();
      if (driver.latitude == 0 && driver.longitude == 0) return;

      final meters = Geolocator.distanceBetween(
          pos.latitude, pos.longitude, driver.latitude, driver.longitude);
      final bearing = Geolocator.bearingBetween(
          pos.latitude, pos.longitude, driver.latitude, driver.longitude);

      setState(() {
        _distanceM = meters;
        _bearingToDriver = (bearing + 360) % 360;
      });

      // Detection: two consecutive fixes inside the ring, so a single GPS
      // spike through the threshold cannot trigger it — instant in practice
      // (fixes arrive ~1/s) without being gullible.
      if (meters <= _kDetectMeters) {
        _closeFixes++;
        if (_closeFixes >= 2 && !_driverDetected) {
          _driverDetected = true;
          HapticService.heavyImpact();
          setState(() {});
          // A beat of green "Driver detected", then the same confirm the
          // button used to do.
          Future.delayed(const Duration(milliseconds: 700), () {
            if (mounted && !_pressed && !_driverStarted) _onConfirmPressed();
          });
        }
      } else {
        _closeFixes = 0;
      }
    }, onError: (Object e) {
      debugPrint('[ConfirmPickup] rider GPS stream error: $e');
    });
  }

  /// Listen to Firestore for the trip status changing to in_progress/in_trip
  /// or cancelled. Handles driver starting trip OR trip auto-cancel due to wait timeout.
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

      // Trip started by the driver — and ONLY that. A startedAt-style
      // timestamp used to count as a start too, and any sync that lands one
      // early (a resumed doc, a backfill) showed "Trip confirmed!" for a
      // Start Trip the driver never pressed. The status is the one signal
      // that means Start Trip: it is written by the driver's own button and
      // by nothing else.
      if (status == 'in_trip' ||
          status == 'in_progress' ||
          status == 'rider_onboard' ||
          status == 'trip_started') {
        _onDriverStartedTrip();
        return;
      }

      // Trip cancelled (e.g., auto-cancel due to wait timeout)
      if (status == 'cancelled' || status == 'canceled') {
        _onTripCancelled(data);
      }
    }, onError: (Object e) {
      // This screen has a REST poll behind it, so a rejected snapshot
      // costs latency rather than correctness. Untreated it was an
      // unhandled error on the rider's most important screen.
      debugPrint('[ConfirmPickup] trip snapshot rejected: $e');
    });
  }

  /// Called when the trip is cancelled while waiting at pickup.
  /// Shows appropriate message and navigates back.
  void _onTripCancelled(Map<String, dynamic> data) {
    final cancelReason = (data['cancel_reason'] ??
            data['cancelReason'] ??
            data['cancellation_reason'] ??
            '')
        .toString()
        .toLowerCase();

    final isWaitTimeout = cancelReason.contains('wait_timeout') ||
        cancelReason.contains('no_show');

    // Stop animations
    _waitTimer?.cancel();
    _handCtrl.stop();
    _ripple1Ctrl.stop();
    _ripple2Ctrl.stop();
    _ripple3Ctrl.stop();

    if (!mounted) return;

    // Show appropriate message based on cancel reason
    final message = isWaitTimeout
        ? 'Viaje cancelado: no te presentaste al pickup a tiempo.\nTrip cancelled: you did not arrive at pickup on time.'
        : 'Viaje cancelado.\nTrip cancelled.';

    // Show toast/snackbar before navigating
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isWaitTimeout ? const Color(0xFFEF4444) : Colors.black87,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );

    // Delay to let user read the message, then call onCancelled or pop
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (widget.onCancelled != null) {
        widget.onCancelled!();
      } else {
        Navigator.of(context).pop();
      }
    });
  }

  /// Called when the driver starts the ride from their side.
  /// Auto-presses the button and shows "Viaje confirmado".
  Future<void> _onDriverStartedTrip() async {
    if (_driverStarted || _pressed) return;
    _driverStarted = true;
    HapticService.mediumImpact();
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
      // Boxless, GOLD (was green — user spec 2026-08-04), with a real
      // sweeping hand on the clock icon. Sits under the big distance in
      // the Find-My bottom block.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AnimatedClockIcon(listenable: _particleCtrl, size: 14),
          const SizedBox(width: 7),
          Text(
            S.of(context).freeWaitTime,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            fmt(freeRemaining),
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: _gold,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ],
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
      // Boxless like the free phase — the red type and the pulse carry the
      // urgency on their own.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
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
  ///
  /// NOTE: 'black' is deliberately NOT a vip matcher any more. It is a
  /// COLOR word — "Black Ford Fusion" is a standard-tier car, and matching
  /// on it put the BLACK-tier Suburban render on a standard trip's card
  /// (the mismatch in the user's screenshot, 2026-08-04).
  /// Collapse a tier string of ANY provenance onto the backend's wait
  /// policy groups: 'vip' = 5 min free/$1.00 per min (vip, black, suv_xl,
  /// suburban), 'premium' = 3 min/$0.60, everything else 'standard' =
  /// 2 min/$0.40 — mirrors trips.py _WAIT_POLICY_BY_TYPE. 'black' is only
  /// matched in the tier string, never in the vehicle description, where
  /// it is usually the car's COLOR.
  String _normalizeWaitTier(String raw, String desc) {
    final t = raw.toLowerCase().replaceAll('_', ' ').trim();
    bool hasAny(String s, List<String> words) => words.any(s.contains);
    if (hasAny(t, ['vip', 'black', 'suv', 'suburban', 'escalade'])) {
      return 'vip';
    }
    if (hasAny(t, ['premium', 'traverse'])) return 'premium';
    if (t.isNotEmpty &&
        hasAny(t, ['standard', 'compact', 'sedan', 'comfort', 'fusion'])) {
      return 'standard';
    }
    // Tier string decided nothing — fall back to the vehicle model text.
    final inferred = _inferTierFromVehicleDesc(desc);
    return inferred == 'compact' ? 'standard' : inferred;
  }

  String _inferTierFromVehicleDesc(String desc) {
    final d = desc.toLowerCase();
    if (d.contains('suburban') || d.contains('escalade') || d.contains('vip')) {
      return 'vip';
    }
    if (d.contains('traverse') || d.contains('accord') || d.contains('premium')) {
      return 'premium';
    }
    if (d.contains('camry') || d.contains('rav4') || d.contains('compact') ||
        d.contains('sedan')) {
      return 'compact';
    }
    return 'standard';
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _tripSub?.cancel();
    _riderGpsSub?.cancel();
    _compassSub?.cancel();
    _particleCtrl.dispose();
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
    HapticService.heavyImpact();
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

  /// Find-My style round action button (chat / call).
  Widget _roundAction({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: neuBox(radius: 26),
        child: Icon(icon, color: _gold, size: 22),
      ),
    );
  }

  void _openChat() {
    HapticService.lightImpact();
    final nav = Navigator.of(context);
    nav.push(
      chatOpenRoute(
        ChatScreen(
          recipientName: widget.driverName,
          recipientPhotoUrl: widget.driverPhotoUrl,
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
  }

  Future<void> _callDriver() async {
    HapticService.lightImpact();
    final phone = widget.driverPhone;
    if (phone == null || phone.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$phone'));
    } catch (e) {
      debugPrint('[ConfirmPickup] call failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
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
                // ── Flat neumorphic base (no gradient) ──
                const Positioned.fill(
                  child: ColoredBox(color: _bg),
                ),

                // ── Main content ──
                Positioned.fill(
                  child: SafeArea(
                    child: Column(
                      children: [
                        SizedBox(height: pad.top + 8),

                        // ── Find-My style header: eyebrow + avatar + name ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isConfirmed
                                    ? S.of(context).tripConfirmedExclaim
                                    : S.of(context).finding,
                                style: TextStyle(
                                  color: isConfirmed
                                      ? _gold
                                      : Colors.white.withValues(alpha: 0.45),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2.0,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  VerifiedAvatar(
                                    photoUrl: widget.driverPhotoUrl,
                                    uid: widget.driverId,
                                    fallbackName: widget.driverName,
                                    radius: 21,
                                    role: 'driver',
                                    isVerified: true,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.driverName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'Poppins',
                                            color: Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.4,
                                          ),
                                        ),
                                        Text(
                                          widget.vehiclePlate != null &&
                                                  widget
                                                      .vehiclePlate!.isNotEmpty
                                              ? '${widget.vehicleDesc}  ·  ${widget.vehiclePlate}'
                                              : widget.vehicleDesc,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.40),
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Distance — right side, at the name's
                                  // level (user spec 2026-08-04). Tweens
                                  // between readings; ft in EN, m in ES.
                                  if (!isConfirmed && _distanceM >= 0)
                                    TweenAnimationBuilder<double>(
                                      tween: Tween(end: _distanceM),
                                      duration:
                                          const Duration(milliseconds: 600),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, m, _) {
                                        final es = S.of(context).isSpanish;
                                        final v = es ? m : m * 3.28084;
                                        final unit = es ? 'm' : 'ft';
                                        return Text(
                                          '${v.round()} $unit',
                                          style: TextStyle(
                                            fontFamily: 'Poppins',
                                            color: _driverDetected
                                                ? const Color(0xFF22C55E)
                                                : Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.6,
                                          ),
                                        );
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const Spacer(),

                        // ── The particle ring with the compass arrow ──
                        // Not a button: nothing here responds to touch. The
                        // system detects the driver by proximity on its own.
                        SizedBox(
                          width: 320,
                          height: 320,
                          child: AnimatedBuilder(
                            animation: _particleCtrl,
                            builder: (context, child) {
                              // Ease the crescent toward the arrow's live
                              // direction — shortest arc, a fraction per
                              // frame: the dust SWINGS with the needle.
                              // Screen space: 0° bearing (north) = up.
                              final target =
                                  (_bearingToDriver - _heading) *
                                          math.pi / 180.0 -
                                      math.pi / 2;
                              var d = (target - _crescentAngle) %
                                  (2 * math.pi);
                              if (d > math.pi) d -= 2 * math.pi;
                              if (d < -math.pi) d += 2 * math.pi;
                              _crescentAngle += d * 0.09;
                              return CustomPaint(
                                painter: _ParticleRingPainter(
                                  t: _particleCtrl.value,
                                  // Confirmed/detected: full even ring, no
                                  // crescent — there is nowhere to point.
                                  focus: (isConfirmed || _driverDetected)
                                      ? null
                                      : _crescentAngle,
                                  color: isConfirmed
                                      ? _gold
                                      : _driverDetected
                                          ? const Color(0xFF22C55E)
                                          : Colors.white,
                                ),
                                child: child,
                              );
                            },
                            child: Center(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 400),
                                switchInCurve: Curves.easeOutBack,
                                child: isConfirmed
                                    ? Column(
                                        key: const ValueKey('c_ok'),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                              Icons.check_circle_rounded,
                                              color: _gold, size: 60),
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
                                    : _driverDetected
                                        ? Column(
                                            key: const ValueKey('c_det'),
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                  Icons
                                                      .person_pin_circle_rounded,
                                                  color: Color(0xFF22C55E),
                                                  size: 60),
                                              const SizedBox(height: 8),
                                              Text(
                                                S.of(context).driverDetected,
                                                style: const TextStyle(
                                                  color: Color(0xFF22C55E),
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ],
                                          )
                                        : AnimatedRotation(
                                            key: const ValueKey('c_arrow'),
                                            // Compass needle: bearing to the
                                            // driver minus device heading,
                                            // short-arc sweep — silky.
                                            turns: (_bearingToDriver -
                                                    _heading) /
                                                360.0,
                                            duration: const Duration(
                                                milliseconds: 250),
                                            curve: Curves.easeOutCubic,
                                            child: const Icon(
                                              Icons.arrow_upward_rounded,
                                              color: Colors.white,
                                              size: 104,
                                            ),
                                          ),
                              ),
                            ),
                          ),
                        ),

                        const Spacer(),

                        // ── Bottom block, Find-My layout: wait line,
                        // auto-start hint, chat/call buttons. (The distance
                        // moved up beside the driver's name.) ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!_pressed && !_driverStarted) ...[
                                _buildWaitTimerBadge(),
                                const SizedBox(height: 3),
                                Text(
                                  S
                                      .of(context)
                                      .rideAutoStartWarning
                                      .replaceAll('\n', ' '),
                                  style: TextStyle(
                                    color: _gold.withValues(alpha: 0.45),
                                    fontSize: 11.5,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 18),
                              Row(
                                children: [
                                  _roundAction(
                                    icon: Icons.chat_bubble_rounded,
                                    onTap: _openChat,
                                  ),
                                  const Spacer(),
                                  _roundAction(
                                    icon: Icons.call_rounded,
                                    onTap: _callDriver,
                                  ),
                                ],
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

/// The Find-My particle ring: ~640 dots scattered in a gaussian band
/// around a circle, each drifting slowly along it and twinkling — silky
/// because everything derives from one slow 12 s clock, nothing jumps.
class _ParticleRingPainter extends CustomPainter {
  const _ParticleRingPainter({
    required this.t,
    required this.color,
    this.focus,
  });

  /// 0..1 phase of the shared 12 s controller.
  final double t;
  final Color color;

  /// Screen-space angle (radians) the crescent faces — the arrow's
  /// direction. The dust concentrates in a soft lobe around it (dense and
  /// bright toward the driver, sparse behind) and swings with it. Null
  /// draws the full even ring (detected / confirmed states).
  final double? focus;

  static const int _count = 640;

  // Deterministic per-particle pseudo-randoms — stable across frames.
  double _h(int i, double salt) =>
      (math.sin(i * 12.9898 + salt * 78.233) * 43758.5453).abs() % 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final baseR = size.width * 0.36;
    final paintDot = Paint();
    final phase = t * 2 * math.pi;

    for (var i = 0; i < _count; i++) {
      final h1 = _h(i, 1), h2 = _h(i, 2), h3 = _h(i, 3), h4 = _h(i, 4);
      // Angle: NO net rotation — full orbits read as "the ring is
      // spinning". Each particle only SWAYS around its home spot, 3°–8°
      // at its own slow tempo (a full sway takes 6–12 s), so neighbours
      // slide gently past one another while the ring itself stays put.
      // Every frequency is an integer multiple of the 12 s cycle: the
      // wrap is seamless.
      final s1 = 2 + (h4 * 2).floor(); // 2..3 sways per cycle (4–6 s each)
      final sway = 0.07 + 0.09 * h1; // 4°..9° of local swing
      final ang = h1 * 2 * math.pi +
          math.sin(phase * s1 + h4 * 6.283) * sway;
      // Radius: gaussian-ish band plus a moderate two-frequency weave —
      // particles thread in and out between each other, milling about
      // rather than holding formation.
      final band = ((h2 + h3) - 1.0) * 26.0;
      final w1 = 2 + (h2 * 2).floor(); // 2..3 cycles per loop
      final w2 = 3 + (h3 * 3).floor(); // 3..5 cycles per loop
      final weave = math.sin(phase * w1 + h2 * 6.283) * 3.5 +
          math.sin(phase * w2 + h4 * 6.283) * 2.5;
      final r = baseR + band + weave;
      // Twinkle: moderate opacity swell, never fully off.
      final twf = 2 + (h3 * 3).floor(); // 2..4
      final tw = 0.18 + 0.65 *
          (0.5 + 0.5 * math.sin(phase * twf + h4 * 6.283));
      var sizePx = 0.7 + 1.9 * h3 * h3;
      var alpha = tw * (0.35 + 0.65 * h2);
      // Crescent: a smooth cosine lobe centered on the arrow's direction.
      // Dots near it keep full presence; the far side fades to a faint
      // trace (never fully off — the ring still reads as a ring).
      final f = focus;
      if (f != null) {
        final lobe = 0.5 + 0.5 * math.cos(ang - f);
        final w = lobe * lobe; // sharpen: dense front, sparse back
        alpha *= 0.08 + 0.92 * w;
        sizePx *= 0.6 + 0.5 * w;
      }
      paintDot.color = color.withValues(alpha: alpha.clamp(0.0, 1.0));
      canvas.drawCircle(
        c + Offset(math.cos(ang) * r, math.sin(ang) * r),
        sizePx,
        paintDot,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticleRingPainter old) =>
      old.t != t || old.color != color || old.focus != focus;
}

/// Tiny clock with a sweeping hand — the animated icon on the wait line.
class _AnimatedClockIcon extends StatelessWidget {
  const _AnimatedClockIcon({required this.listenable, this.size = 14});

  final Animation<double> listenable;
  final double size;
  static const Color color = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: listenable,
      builder: (_, __) => CustomPaint(
        size: Size.square(size),
        painter: _ClockPainter(
          // 6 sweeps per 12 s cycle = one full turn every 2 s.
          handTurns: listenable.value * 6,
          color: color,
        ),
      ),
    );
  }
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter({required this.handTurns, required this.color});

  final double handTurns;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 0.8;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, ring);
    // Sweeping "minute" hand.
    final a = handTurns * 2 * math.pi - math.pi / 2;
    canvas.drawLine(
      c,
      c + Offset(math.cos(a), math.sin(a)) * (r - 1.6),
      ring,
    );
    // Short fixed hour hand for the clock silhouette.
    canvas.drawLine(
      c,
      c + const Offset(0, -1) * (r * 0.45),
      ring,
    );
  }

  @override
  bool shouldRepaint(_ClockPainter old) =>
      old.handTurns != handTurns || old.color != color;
}


