import 'dart:async';

import '../../map/map_surface_coordinator.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../map/web_map_view.dart';
import '../../config/app_theme.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/map_controller_cache.dart';
import '../../services/masked_call_service.dart';
import 'driver_trip_accept_screen.dart';

/// Full-screen countdown + details for an upcoming scheduled ride.
/// Shown when driver is "locked" (<=30 min before pickup).
class ScheduledRideDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  final double minutesUntil;

  const ScheduledRideDetailsScreen({
    super.key,
    required this.trip,
    required this.minutesUntil,
  });

  @override
  State<ScheduledRideDetailsScreen> createState() =>
      _ScheduledRideDetailsScreenState();
}

class _ScheduledRideDetailsScreenState extends State<ScheduledRideDetailsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// It mounts a full-screen Mapbox background, and every other screen that
  /// does is registered — an unregistered one leaves whatever it was opened
  /// from holding a second live surface, which is a native crash on iOS.
  static const String _mapSurfaceOwner = 'ScheduledRideDetails';

  /// The backdrop waits until the surface is actually free.
  bool _mapMounted = false;

  static const _gold = Color(0xFFE8C547);
  static const _darkBg = Color(0xFF0A0E21);
  static const _cardBg = Color(0xFF1A1A2E);

  late int _secondsRemaining;
  Timer? _countdownTimer;
  bool _starting = false;
  bool _cancelling = false;
  bool _autoStarted = false;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _secondsRemaining = (widget.minutesUntil * 60).round().clamp(0, 999999);
    // If already <= 15 min, auto-redirect immediately
    if (_secondsRemaining <= 900) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _autoStartRide();
      });
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _secondsRemaining = (_secondsRemaining - 1).clamp(0, 999999);
      });
      // Auto-redirect when countdown hits 15 minutes
      if (_secondsRemaining <= 900 && !_autoStarted && !_starting) {
        _autoStartRide();
      }
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    unawaited(_acquireMapSurface());
  }

  /// Claim the one live Mapbox surface before mounting the backdrop.
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _countdownTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshTripStatus();
    }
  }

  /// Re-fetch trip status from backend when app resumes.
  Future<void> _refreshTripStatus() async {
    try {
      final data = await ApiService.getActiveScheduledTrip();
      if (!mounted) return;
      final hasTrip = data['has_scheduled_trip'] == true;
      if (!hasTrip) {
        // Trip was cancelled or completed while away
        Navigator.of(context).pop('refreshed');
        return;
      }
      final trip = data['trip'] as Map<String, dynamic>?;
      if (trip == null) return;
      final status = (trip['status'] ?? '').toString();
      // If trip already started (driver_en_route or beyond), navigate to trip screen
      final activeStatuses = {'driver_en_route', 'en_route_to_pickup', 'arrived',
          'driver_arrived', 'in_trip', 'in_progress'};
      if (activeStatuses.contains(status) && !_starting) {
        _navigateToTripScreen();
        return;
      }
      // Update countdown from fresh server data
      final minutesUntil = (data['minutes_until'] as num?)?.toDouble();
      if (minutesUntil != null) {
        setState(() {
          _secondsRemaining = (minutesUntil * 60).round().clamp(0, 999999);
        });
      }
    } catch (e) {
      debugPrint('[ScheduledRide] Refresh failed: $e');
    }
  }

  int get _tripId => widget.trip['id'] as int;

  /// Auto-start triggered by 15-min countdown or immediate if already <= 15 min.
  Future<void> _autoStartRide() async {
    if (_autoStarted) return;
    _autoStarted = true;
    await _startRideAndNavigate();
  }

  /// Start the ride via API, then navigate to the trip accept screen.
  /// Retries once on failure before showing an error.
  Future<void> _startRideAndNavigate() async {
    setState(() => _starting = true);
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await ApiService.startScheduledTrip(_tripId);
        if (!mounted) return;
        HapticService.mediumImpact();
        _navigateToTripScreen();
        return;
      } catch (e) {
        if (!mounted) return;
        if (attempt < 2) {
          debugPrint('[ScheduledRide] Start attempt $attempt failed: $e — retrying…');
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          continue;
        }
        _autoStarted = false; // allow retry
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).connectionError),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _starting = false);
  }

  /// Navigate to DriverTripAcceptScreen with all trip data.
  void _navigateToTripScreen() {
    final trip = widget.trip;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    if (pickupLat == null || pickupLng == null ||
        dropoffLat == null || dropoffLng == null) {
      Navigator.of(context).pop('started');
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    // Use pickup as fallback for driver position
    final driverPos = pickup;
    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);
    final riderName = trip['rider_name']?.toString() ?? '';
    final riderId = int.tryParse((trip['rider_id'] ?? '').toString());

    // Replace this screen with the trip screen
    Navigator.of(context).pushReplacement(
      slideFromRightRoute(
        DriverTripAcceptScreen(
          tripId: _tripId,
          riderName: riderName,
          riderPhotoUrl: _normalizePhotoUrl(trip['rider_photo_url']?.toString() ?? ''),
          riderRating: (trip['rider_rating'] as num?)?.toDouble() ?? 0,
          riderIsNew: trip['rider_is_new'] == true,
          riderId: riderId,
          pickupLatLng: pickup,
          dropoffLatLng: dropoff,
          pickupAddress: trip['pickup_address']?.toString() ?? '',
          dropoffAddress: trip['dropoff_address']?.toString() ?? '',
          fare: (trip['fare'] as num?)?.toDouble() ?? 0,
          vehicleType: trip['vehicle_type']?.toString() ?? 'Comfort',
          driverPos: driverPos,
          distToPickupKm: distKm,
          etaMinutes: etaMinutes,
          riderPhone: trip['rider_phone']?.toString() ?? '',
          tripAlreadyStarted: true,
        ),
      ),
    );
  }

  Future<void> _startRide() async {
    await _startRideAndNavigate();
  }

  static String _normalizePhotoUrl(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sa = math.sin(dLat / 2);
    final sb = math.sin(dLng / 2);
    final aa = sa * sa +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sb * sb;
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }

  Future<void> _cancelRide() async {
    final s = S.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ls = S.of(ctx);
        return AlertDialog(
          backgroundColor: _cardBg,
          title: Text(ls.cancelRideTitle, style: const TextStyle(color: Colors.white)),
          content: Text(
            ls.cancelRideBody,
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ls.no, style: const TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ls.cancel, style: const TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;

    setState(() => _cancelling = true);
    try {
      await ApiService.cancelScheduledTrip(_tripId);
      if (!mounted) return;
      Navigator.of(context).pop('cancelled');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${S.of(context).error}: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  static String _formatMinutesAsTime(int totalMinutes) {
    if (totalMinutes <= 0) return '0 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String get _countdownText {
    final h = _secondsRemaining ~/ 3600;
    final m = (_secondsRemaining % 3600) ~/ 60;
    final s = _secondsRemaining % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = S.of(context);
    final trip = widget.trip;
    final pickup = trip['pickup_address'] ?? '';
    final dropoff = trip['dropoff_address'] ?? '';
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final riderName = trip['rider_name'] ?? '';
    final riderPhoto = trip['rider_photo_url']?.toString() ?? '';
    final vehicleType = trip['vehicle_type'] ?? 'standard';
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final scheduledAt = trip['scheduled_at'] != null
        ? DateTime.tryParse(trip['scheduled_at'])
        : null;
    final dateStr = scheduledAt != null
        ? DateFormat('EEEE d MMMM, h:mm a').format(scheduledAt.toLocal())
        : '';

    final canStart = _secondsRemaining <= 900; // Can start 15 min early

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // ── Live map background ──
          if (_mapMounted && pickupLat != null && pickupLng != null)
            Positioned.fill(
              child: IgnorePointer(
                // The native MapWidget has no web implementation — GL JS
                // takes over in the browser.
                child: kIsWeb
                    ? WebMapView(
                        key: const ValueKey('scheduled_details_map_web'),
                        initialLng: pickupLng,
                        initialLat: pickupLat,
                        initialZoom: 13.0,
                        styleUri: MapboxConfig.styleDark,
                        onControllerCreated: (c) => c.applyNavyGoldTheme(),
                      )
                    : mapbox.MapWidget(
                  styleUri: MapboxConfig.styleDark,
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(
                      coordinates: mapbox.Position(pickupLng, pickupLat),
                    ),
                    zoom: 13.0,
                    pitch: 0.0,
                  ),
                  onMapCreated: (ctrl) async {
                    // Cache controller for reuse across driver screens
                    MapControllerCache.instance.cache(ctrl);
                    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                  },
                  onStyleLoadedListener: (_) {},
                ),
              ),
            ),
          // ── Semi-transparent dark tint (map visible behind) ──
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: Container(
                color: const Color(0xFF0A0E21).withValues(alpha: 0.75),
              ),
            ),
          ),
          // ── Content ──
          SafeArea(
        child: Column(
          children: [
            // Top bar: SCHEDULED RIDE badge + X close button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.event, color: _gold, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          S.of(context).scheduledRideLabel,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // X close button
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white70, size: 20),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Countdown circle
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) {
                final scale = 1.0 + _pulseCtrl.value * 0.03;
                return Transform.scale(scale: scale, child: child);
              },
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _gold.withValues(alpha: 0.2),
                      _gold.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                  border: Border.all(color: _gold.withValues(alpha: 0.4), width: 3),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _secondsRemaining <= 0 ? loc.nowLabel.toUpperCase() : _countdownText,
                      style: TextStyle(
                        color: _secondsRemaining <= 0 ? Colors.green : _gold,
                        fontSize: _secondsRemaining <= 0 ? 32 : 36,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_secondsRemaining > 0)
                      Text(
                        loc.forPickup,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              dateStr,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),

            const SizedBox(height: 24),

            // Trip details card
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _cardBg.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _gold.withValues(alpha: 0.15)),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                      // Pickup
                      _addressRow(
                        icon: Icons.circle,
                        color: Colors.green,
                        label: S.of(context).pickupUpperLabel,
                        address: pickup,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: Container(width: 2, height: 20, color: Colors.white12),
                      ),
                      // Dropoff
                      _addressRow(
                        icon: Icons.circle,
                        color: Colors.red,
                        label: S.of(context).dropoffUpperLabel,
                        address: dropoff,
                      ),

                      // ── Fare below addresses ──
                      const SizedBox(height: 20),
                      Center(
                        child: Column(
                          children: [
                            Text(
                              '\$${fare.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '+ Tips',
                              style: TextStyle(
                                color: _gold.withValues(alpha: 0.5),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── Rider info row ──
                      if (riderName.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: _gold.withValues(alpha: 0.2),
                                radius: 18,
                                backgroundImage: riderPhoto.isNotEmpty
                                    ? CachedNetworkImageProvider(riderPhoto)
                                    : null,
                                child: riderPhoto.isEmpty
                                    ? Text(
                                        riderName.isNotEmpty ? riderName[0].toUpperCase() : '?',
                                        style: const TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 14),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      riderName,
                                      style: const TextStyle(
                                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      vehicleType.toUpperCase(),
                                      style: const TextStyle(color: _gold, fontSize: 10, fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                  icon: const Icon(Icons.phone, color: Colors.green, size: 20),
                                  onPressed: () => MaskedCallService.callCounterparty(
                                    tripId: _tripId,
                                    role: 'driver',
                                  ),
                                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                  padding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                        ),
                      ],

                    ],
                  ),
                ),
              ),
                // No more offers banner pinned at bottom of card
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.orange.withValues(alpha: 0.7), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            loc.noNewRidesUntilComplete,
                            style: TextStyle(color: Colors.orange.withValues(alpha: 0.8), fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Bottom buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  // Cancel button — only show when > 1 hour remains
                  if (_secondsRemaining > 3600) ...[
                  Expanded(
                    flex: 1,
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _cancelling ? null : _cancelRide,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _cancelling
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red),
                              )
                            : Text(
                                loc.cancel.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.red, fontWeight: FontWeight.w700, fontSize: 13,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ],
                  // Start ride button
                  Expanded(
                    flex: _secondsRemaining > 3600 ? 2 : 1,
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: canStart && !_starting ? _startRide : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: canStart ? _gold : Colors.grey[700],
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _starting
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : Text(
                                canStart
                                    ? loc.startRideButton
                                    : '${loc.availableInLabel} ${_formatMinutesAsTime((_secondsRemaining ~/ 60) - 15)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: canStart ? 16 : 12,
                                ),
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
        ], // Stack children
      ), // Stack
    );
  }

  Widget _addressRow({
    required IconData icon,
    required Color color,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color.withValues(alpha:0.7),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                address,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
