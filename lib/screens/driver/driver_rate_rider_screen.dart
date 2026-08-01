import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../map/map_surface_coordinator.dart';
import '../../services/haptic_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../widgets/verified_avatar.dart';
import 'driver_online_screen.dart';
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

  /// Identifies this screen to [MapSurfaceCoordinator].
  static const String _mapSurfaceOwner = 'DriverRateRider';

  /// The backdrop map waits its turn. This screen is pushed straight off
  /// the trip screen, which is still holding a live surface — mounting
  /// unconditionally, as this did, put two up at the end of every ride.
  /// It is a blurred decorative backdrop, so arriving a few frames late
  /// costs nothing visible.
  bool _mapMounted = false;


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
    unawaited(_acquireMapSurface());
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
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

    // Fade the content out and tear the map down at the same time — the map
    // is behind a 5-pixel blur and a 45% scrim, so its removal is invisible
    // and there is no reason to pay for it twice.
    final fade = _fadeCtrl.reverse();

    // The surface is gone before the next screen is pushed, and we wait for
    // it to really be gone.
    //
    // DriverOnlineScreen mounts a Mapbox surface of its own roughly half a
    // second after the push, and two live surfaces close the app on iOS.
    // Releasing in dispose() did not prevent that: release() only clears the
    // coordinator's bookkeeping, it does not wait for the PlatformView to be
    // torn down — so the incoming screen was told the surface was free while
    // ours was still attached. Every other screen in this flow drops its map
    // before navigating (see DriverHomeScreen._suspendMap); this one was the
    // exception, and it is the last screen of every ride.
    if (_mapMounted) {
      setState(() => _mapMounted = false);
      await surfaceRemoved();
    }
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);

    await fade;
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, anim, __) => DriverOnlineScreen(
          initialPos: (widget.dropoffLat != null && widget.dropoffLng != null)
              ? LatLng(widget.dropoffLat!, widget.dropoffLng!)
              : null,
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
          // ── Blurred dark Mapbox map background ──
          if (_mapMounted)
          Positioned.fill(
            child: IgnorePointer(
              child: mapbox.MapWidget(
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates: mapbox.Position(
                      widget.dropoffLng ?? -80.1918,
                      widget.dropoffLat ?? 25.7617,
                    ),
                  ),
                  zoom: 14.0,
                  pitch: 0,
                ),
                onMapCreated: (ctrl) async {
                  await MapTheme.applyNavyGold(ctrl);
                  await ctrl.gestures.updateSettings(
                    mapbox.GesturesSettings(
                      scrollEnabled: false,
                      rotateEnabled: false,
                      pitchEnabled: false,
                      doubleTapToZoomInEnabled: false,
                      doubleTouchToZoomOutEnabled: false,
                      quickZoomEnabled: false,
                      pinchToZoomEnabled: false,
                    ),
                  );
                  await ctrl.compass.updateSettings(
                    mapbox.CompassSettings(enabled: false),
                  );
                  await ctrl.scaleBar.updateSettings(
                    mapbox.ScaleBarSettings(enabled: false),
                  );
                },
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
