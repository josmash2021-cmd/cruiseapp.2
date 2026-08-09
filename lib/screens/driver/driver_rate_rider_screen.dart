import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../config/page_transitions.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../state/chained_ride_store.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/static_route_preview.dart';
import 'driver_online_screen.dart';
import 'driver_trip_accept_screen.dart';
import '../../utils/responsive.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER RATE RIDER SCREEN — Post-trip feedback
//  Stars 1–5, quick tags, submit → back to online screen
// ═══════════════════════════════════════════════════════════════════════════

class DriverRateRiderScreen extends StatefulWidget {
  const DriverRateRiderScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.riderId,
    this.fare = 0,
    this.dropoffLat,
    this.dropoffLng,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final double fare;
  final double? dropoffLat;
  final double? dropoffLng;

  @override
  State<DriverRateRiderScreen> createState() => _DriverRateRiderScreenState();
}

class _DriverRateRiderScreenState extends State<DriverRateRiderScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4A843);
  static const _bg   = Color(0xFF0A0D1A);


  int _stars = 0;
  final Set<String> _selectedTags = {};
  bool _submitting = false;

  /// True once a departure from this screen has been started.
  ///
  /// Three separate things call [_goOnline] — Enviar, Omitir, and the back
  /// gesture — and none of them knew about the others. Two firing together
  /// pushes two DriverOnlineScreens, and each one claims a map surface on
  /// its own timer.
  bool _leaving = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  static const _tags = [
    'Puntual',
    'Amable',
    'Respetuoso',
    'Orden',
    'Buen trato',
    'Excelente rider',
  ];

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    // No map surface is claimed or released on this screen. The backdrop is
    // an image, so there is nothing here that another screen has to wait for.
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  String get _firstName => widget.riderName.split(' ').first;

  // ── Submit rating ────────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticService.mediumImpact();

    // Save to backend SQL database (primary source of truth)
    if (_stars > 0) {
      try {
        await ApiService.rateTrip(
          tripId: widget.tripId,
          stars: _stars,
          comment: _selectedTags.isNotEmpty ? _selectedTags.join(', ') : null,
        );
      } catch (e) {
        debugPrint('[DriverRateRider] Backend rating failed: $e');
      }
      // Also save to Firebase RTDB (for realtime analytics)
      try {
        await FirebaseDatabase.instance
            .ref('ratings/riders')
            .push()
            .set({
          'stars': _stars,
          'tags': _selectedTags.toList(),
          'tripId': widget.tripId,
          'timestamp': ServerValue.timestamp,
        });
      } catch (_) {}
      // Also save to Firestore trip document
      try {
        await FirebaseFirestore.instance
            .collection('trips')
            .doc('sql_${widget.tripId}')
            .update({
          'riderRating': _stars,
          'riderRatedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }

    if (!mounted) return;
    _goOnline();
  }

  Future<void> _goOnline() async {
    if (_leaving) return;
    _leaving = true;

    // Nothing to hand over any more.
    //
    // This used to drop a live Mapbox surface here and wait for the teardown
    // to be confirmed, because DriverOnlineScreen mounts one of its own
    // about half a second after the push and two live surfaces close the app
    // on iOS. The backdrop is an image now, so there is no surface, no
    // handoff, and no wait: the online screen's map is simply already there.
    await _fadeCtrl.reverse();
    if (!mounted) return;

    // A chained ride booked mid-trip starts NOW: straight into the next
    // pickup page, never through "Finding trips" (user spec 2026-08-09).
    if (ChainedRideStore.hasRide && await _startChainedTrip()) return;

    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, anim, __) => DriverOnlineScreen(
          initialPos: (widget.dropoffLat != null && widget.dropoffLng != null)
              ? LatLng(widget.dropoffLat!, widget.dropoffLng!)
              : null,
          // Coming back from a trip is a RESUME, not a go-online: the
          // driver never went offline, so the "Go" chime must not fire
          // again (it did, every trip end — sounded like a fresh Go tap).
          resuming: true,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (route) => false,
    );
  }

  /// The chained ride booked mid-trip, started straight into its pickup
  /// page. The offer payload already carries everything the page needs;
  /// getTrip is only a liveness check — dispatch may have reassigned or
  /// cancelled the ride while the rating screen was up, and starting a
  /// dead trip would strand the driver on a page that never advances.
  /// False → the caller falls back to the normal online screen.
  Future<bool> _startChainedTrip() async {
    final offer = ChainedRideStore.take();
    if (offer == null) return false;
    final tripId = (offer['trip_id'] as num?)?.toInt() ??
        (offer['id'] as num?)?.toInt();
    if (tripId == null) return false;
    try {
      final trip = await ApiService.getTrip(tripId);
      final status = trip['status']?.toString() ?? '';
      if (status.isEmpty || status == 'cancelled' || status == 'completed') {
        return false;
      }
    } catch (_) {
      return false;
    }
    if (!mounted) return true;

    double numOf(dynamic v) =>
        v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0;
    final pickupLat = numOf(offer['pickup_lat']);
    final pickupLng = numOf(offer['pickup_lng']);
    if (pickupLat == 0 && pickupLng == 0) return false;
    final dropLat = numOf(offer['dropoff_lat']);
    final dropLng = numOf(offer['dropoff_lng']);
    final pickup = LatLng(pickupLat, pickupLng);
    // Where the last trip ended is where this one starts from.
    final driverPos = (widget.dropoffLat != null && widget.dropoffLng != null)
        ? LatLng(widget.dropoffLat!, widget.dropoffLng!)
        : pickup;
    final distKm = _havKm(driverPos, pickup);
    final eta = (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, anim, __) => DriverTripAcceptScreen(
          tripId: tripId,
          riderName: (offer['rider_name'] as String?) ?? 'Rider',
          riderPhotoUrl: (offer['rider_photo_url'] as String?) ?? '',
          riderRating: (offer['rider_rating'] as num?)?.toDouble() ?? 0.0,
          riderIsNew: offer['rider_is_new'] == true,
          riderId: (offer['rider_id'] as num?)?.toInt(),
          pickupLatLng: pickup,
          dropoffLatLng: LatLng(dropLat, dropLng),
          pickupAddress: (offer['pickup_address'] as String?) ?? '',
          dropoffAddress: (offer['dropoff_address'] as String?) ?? '',
          fare: (offer['driver_earnings'] as num?)?.toDouble() ??
              (offer['fare'] as num?)?.toDouble() ??
              0.0,
          vehicleType: (offer['vehicle_type'] as String?) ?? '',
          driverPos: driverPos,
          distToPickupKm: distKm,
          etaMinutes: eta,
          riderPhone: (offer['rider_phone'] as String?) ?? '',
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (route) => false,
    );
    return true;
  }

  static double _havKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goOnline(); // Back button → go online instead of getting stuck
      },
      child: Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // ── Blurred dark map backdrop ──
          //
          // An image, not a live map. What sits here is covered by a
          // five-pixel blur and a 45% black scrim, at zoom 14 — an abstract
          // dark texture that nobody can read a street off. It was a native
          // Mapbox surface, and there is one of those in the whole app.
          //
          // Taking it here cost a full handoff at the end of every ride:
          // this screen is pushed with pushAndRemoveUntil, so it was pulling
          // the surface away from a trip screen on its way out and handing
          // it to the online screen a second and a half later. Two of the
          // three crashes in this flow lived in those two handoffs.
          //
          // No pins: a marker under that blur is a gold smudge that looks
          // like it was meant to say something.
          Positioned.fill(
            child: IgnorePointer(
              child: StaticRoutePreview(
                pickupLat: widget.dropoffLat ?? 25.7617,
                pickupLng: widget.dropoffLng ?? -80.1918,
                pins: false,
              ),
            ),
          ),
          // ── Soft blur + semi-transparent dark overlay ──
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Container(
                  color: _bg.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
          // ── Content ──
          FadeTransition(
            opacity: _fadeAnim,
            child: Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(24), top + 24, Responsive.w(24), bot + 24),
              child: Column(
                children: [
                  SizedBox(height: Responsive.h(20)),
                  _buildAvatar(),
                  SizedBox(height: Responsive.h(20)),
                  Text(
                    '¿Cómo fue tu viaje\nllevando a $_firstName?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: Responsive.sp(22),
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  SizedBox(height: Responsive.h(32)),
                  _buildStars(),
                  SizedBox(height: Responsive.h(28)),
                  if (_stars > 0) _buildTags(),
                  const Spacer(),
                  // Submit
                  SizedBox(
                    width: double.infinity,
                    height: Responsive.h(52),
                    child: ElevatedButton(
                      onPressed:
                          _stars > 0 && !_submitting && !_leaving ? _submit : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _stars > 0 ? _gold : _gold.withValues(alpha: 0.3),
                        disabledBackgroundColor: _gold.withValues(alpha: 0.3),
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 22, height: 22,
                              child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2.5))
                          : Text(
                              'Enviar',
                              style: TextStyle(
                                color: _stars > 0 ? Colors.black : Colors.white38,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Skip
                  TextButton(
                    onPressed: _submitting || _leaving ? null : _goOnline,
                    child: Text(
                      'Omitir',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }

  // ── Avatar ────────────────────────────────────────────────────────────────
  Widget _buildAvatar() {
    return VerifiedAvatar(
      photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
      radius: Responsive.w(44),
      fallbackName: widget.riderName,
      uid: widget.riderId?.toString(),
      role: 'rider',
      isVerified: true,
    );
  }

  Widget _initialsFill(String init) => Container(
    color: const Color(0xFF1A1F35),
    child: Center(
      child: Text(init,
        style: const TextStyle(
          color: _gold, fontSize: 32, fontWeight: FontWeight.w700)),
    ),
  );

  // ── Stars ─────────────────────────────────────────────────────────────────
  Widget _buildStars() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < _stars;
        return GestureDetector(
          onTap: () {
            HapticService.lightImpact();
            setState(() => _stars = i + 1);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 6),
            child: AnimatedScale(
              scale: filled ? 1.0 : 0.85,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              child: Icon(
                filled ? Icons.star_rounded : Icons.star_outline_rounded,
                color: filled ? _gold : Colors.white.withValues(alpha: 0.24),
                size: 48,
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Tags ──────────────────────────────────────────────────────────────────
  Widget _buildTags() {
    return AnimatedOpacity(
      opacity: _stars > 0 ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: _tags.map((tag) {
          final selected = _selectedTags.contains(tag);
          return GestureDetector(
            onTap: () {
              HapticService.selectionClick();
              setState(() {
                if (selected) {
                  _selectedTags.remove(tag);
                } else {
                  _selectedTags.add(tag);
                }
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? _gold.withValues(alpha: 0.20)
                    : const Color(0xFF1A1F35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? _gold : Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  color: selected ? _gold : Colors.white.withValues(alpha: 0.60),
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
