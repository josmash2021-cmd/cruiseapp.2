import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../../models/lat_lng.dart';
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../../config/map_styles.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/ride_offer.dart';
import '../../navigation/offers_controller.dart';
import '../../navigation/route_service.dart';
import '../../pages/driver_navigation_page.dart';
import '../../widgets/gold_location_dot.dart';

/// Instacart-style driver offers screen.
///
/// Shows a list of available ride offers. No countdown timers.
/// Driver can ACCEPT or REJECT each offer.
/// After ACCEPT → navigates to [DriverNavigationPage].
class DriverOffersScreen extends StatefulWidget {
  const DriverOffersScreen({super.key, this.driverId});

  final int? driverId;

  @override
  State<DriverOffersScreen> createState() => _DriverOffersScreenState();
}

class _DriverOffersScreenState extends State<DriverOffersScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _dark = Color(0xFF111116);
  static const _card = Color(0xFF1C1C24);
  static const _green = Color(0xFF34A853);
  static const _red = Color(0xFFEA4335);

  final OffersController _ctrl = OffersController();
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotation? _driverAnnot;
  LatLng? _driverPos;
  bool _loading = true;
  bool _accepting = false;
  final GoldLocationDot _goldDot = GoldLocationDot();

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _goldDot.build(() { if (mounted) setState(() {}); });
    _initLocation();
  }

  @override
  void dispose() {
    _goldDot.dispose();
    _pulseCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onMapCreated(mapbox.MapboxMap controller) async {
    _map = controller;
    _pointAnnotMgr = await controller.annotations.createPointAnnotationManager();
    _updateDriverAnnotation();
    await MapTheme.applyNavyGold(controller);
  }

  Future<void> _updateDriverAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null || _driverPos == null) return;
    final bytes = _goldDot.currentBytes;
    if (bytes == null) return;
    if (_driverAnnot != null) {
      try { await mgr.delete(_driverAnnot!); } catch (_) {}
    }
    _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_driverPos!.longitude, _driverPos!.latitude)),
      image: bytes,
      iconSize: 0.5,
    ));
  }

  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          if (mounted) setState(() => _loading = false);
          return;
        }
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationRequiredForDriver),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        if (mounted) setState(() => _loading = false);
        return;
      }
      // Try last known for instant display
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null && mounted) {
          setState(() => _driverPos = LatLng(lastKnown.latitude, lastKnown.longitude));
        }
      } catch (_) {}
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (mounted) setState(() => _driverPos = LatLng(pos.latitude, pos.longitude));
    } catch (_) {}
    if (_driverPos != null) {
      _ctrl.driverLatLng = _driverPos!;
      _ctrl.start(driverId: widget.driverId);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _onAccept(RideOffer offer) async {
    if (_accepting) return;
    setState(() => _accepting = true);
    HapticFeedback.heavyImpact();

    final accepted = await _ctrl.acceptOffer(offer.offerId);
    if (accepted == null || !mounted) {
      setState(() => _accepting = false);
      return;
    }

    // Fetch route
    List<LatLng>? routePts;
    try {
      final route = await RouteService.fetchNavRoute(
        origin: _driverPos!,
        destination: accepted.pickupLatLng,
      );
      routePts = route?.overviewPolyline;
    } catch (_) {}

    if (!mounted) return;

    // Navigate to driver navigation
    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        DriverNavigationPage(
          pickupLatLng: accepted.pickupLatLng,
          dropoffLatLng: accepted.dropoffLatLng,
          tripId: accepted.offerId,
          initialDriverPos: _driverPos!,
          routePoints: routePts,
          riderName: accepted.riderName,
          riderPhotoUrl: accepted.riderPhotoUrl,
          riderRating: accepted.riderRating,
          pickupLabel: accepted.pickupAddress.isNotEmpty
              ? accepted.pickupAddress
              : offer.pickupAddress,
          dropoffLabel: accepted.dropoffAddress.isNotEmpty
              ? accepted.dropoffAddress
              : offer.dropoffAddress,
        ),
      ),
    );
  }

  void _onReject(RideOffer offer) {
    HapticFeedback.mediumImpact();
    _showRejectReasonDialog(offer);
  }

  void _showRejectReasonDialog(RideOffer offer) {
    final reasons = [
      'Too far away',
      'Traffic/construction',
      'Personal break',
      'Vehicle issue',
      'Other',
    ];
    
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Why are you declining?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This helps us improve dispatching',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 20),
                ...reasons.map((reason) => ListTile(
                  title: Text(reason, style: const TextStyle(color: Colors.white)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                  onTap: () {
                    Navigator.pop(ctx);
                    _ctrl.rejectOffer(offer.offerId, reason: reason);
                  },
                )),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _goOffline() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      backgroundColor: _dark,
      body: Stack(
        children: [
          // ── Background map ──
          Positioned.fill(
            child: _driverPos == null
                ? Container(
                    color: const Color(0xFF07080D),
                    child: const Center(
                      child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
                    ),
                  )
                : RepaintBoundary(
                    child: mapbox.MapWidget(
                    styleUri: MapboxConfig.styleDark,
                    cameraOptions: mapbox.CameraOptions(
                      center: mapbox.Point(coordinates: mapbox.Position(_driverPos!.longitude, _driverPos!.latitude)),
                      zoom: 14.0,
                    ),
                    onMapCreated: _onMapCreated,
                    onStyleLoadedListener: (_) async {
                      if (_map != null) await MapTheme.applyNavyGold(_map!);
                    },
                  ),
                  ),
          ),

          // ── Gradient overlay for readability ──
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.black.withValues(alpha: 0.1),
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.92),
                  ],
                  stops: const [0.0, 0.3, 0.6, 1.0],
                ),
              ),
            ),
          ),

          // ── Top bar ──
          Positioned(
            top: pad.top + 8,
            left: 16,
            right: 16,
            child: Row(
              children: [
                GestureDetector(
                  onTap: _goOffline,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _card.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.arrow_back_ios_rounded,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          S.of(context).goOfflineBtn,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                // Status indicator
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, __) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _green.withValues(
                        alpha: 0.15 + _pulseAnim.value * 0.1,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _green.withValues(alpha: _pulseAnim.value * 0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _green,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _green.withValues(
                                  alpha: _pulseAnim.value * 0.5,
                                ),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          S.of(context).onlineStatus,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Offers list ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _loading
                ? _loadingIndicator()
                : ValueListenableBuilder<List<RideOffer>>(
                    valueListenable: _ctrl.offersNotifier,
                    builder: (_, offers, __) {
                      if (offers.isEmpty) return _emptyState();
                      return _offersList(offers, pad.bottom);
                    },
                  ),
          ),

          // ── Accepting overlay ──
          if (_accepting)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: _gold),
                      const SizedBox(height: 16),
                      Text(
                        S.of(context).acceptingRide,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _loadingIndicator() {
    return Container(
      height: 200,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: _gold),
          const SizedBox(height: 12),
          Text(
            S.of(context).findingRidesNearYou,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      height: 200,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Icon(
              Icons.local_taxi_rounded,
              size: 48,
              color: _gold.withValues(alpha: 0.4 + _pulseAnim.value * 0.3),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            S.of(context).lookingForRides,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            S.of(context).newOffersWillAppear,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _offersList(List<RideOffer> offers, double bottomPad) {
    return Container(
      decoration: const BoxDecoration(
        color: _dark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  S.of(context).availableRides,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${offers.length}',
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Offer cards
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: ListView.builder(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: bottomPad + 16,
              ),
              shrinkWrap: true,
              itemCount: offers.length,
              itemBuilder: (_, i) => _offerCard(offers[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _offerCard(RideOffer offer) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF2A2A35),
            const Color(0xFF1E1E28),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _gold.withValues(alpha: 0.3),
          width: 1.5,
        ),
        boxShadow: [
          // Main shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
          // Gold glow
          BoxShadow(
            color: _gold.withValues(alpha: 0.15),
            blurRadius: 30,
            offset: const Offset(0, 4),
            spreadRadius: 2,
          ),
          // Facebook-style 3D depth shadow
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with fare - UberX style
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _gold.withValues(alpha: 0.15),
                        _gold.withValues(alpha: 0.05),
                      ],
                    ),
                    border: Border(
                      bottom: BorderSide(
                        color: _gold.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      // Vehicle icon badge
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _gold.withValues(alpha: 0.3),
                              _gold.withValues(alpha: 0.1),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.4),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.local_taxi_rounded,
                          color: _gold,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              offer.vehicleType,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '\$${offer.fareUsd.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Exclusive badge like UberX
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _gold.withValues(alpha: 0.25),
                              _gold.withValues(alpha: 0.1),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.4),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              color: _gold,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Exclusivo',
                              style: TextStyle(
                                color: _gold,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Addresses section
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Route indicator
                      Column(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: _green,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _green.withValues(alpha: 0.4),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 2,
                            height: 32,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  _green.withValues(alpha: 0.6),
                                  _red.withValues(alpha: 0.6),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: _red,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _red.withValues(alpha: 0.4),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      // Addresses
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _addressRow(
                              offer.pickupAddress,
                              '${offer.distanceToPickupKm.toStringAsFixed(1)} mi',
                              isPickup: true,
                            ),
                            const SizedBox(height: 20),
                            _addressRow(
                              offer.dropoffAddress,
                              '${offer.estimatedMinutes} min',
                              isPickup: false,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Stats badges row
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(
                    children: [
                      _glassBadge(
                        Icons.person_outline_rounded,
                        offer.riderName,
                      ),
                      const SizedBox(width: 8),
                      _glassBadge(
                        Icons.star_rounded,
                        '4.9',
                      ),
                    ],
                  ),
                ),
                // Action buttons with 3D style
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    children: [
                      // Decline button
                      Expanded(
                        flex: 1,
                        child: GestureDetector(
                          onTap: () => _onReject(offer),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(alpha: 0.1),
                                  Colors.white.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                'Rechazar',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Accept button
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: () => _onAccept(offer),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  _gold,
                                  const Color(0xFFD4B03A),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: _gold.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                'Aceptar',
                                style: TextStyle(
                                  color: Colors.black.withValues(alpha: 0.9),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
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
        ),
      ),
    );
  }

  Widget _addressRow(String address, String meta, {required bool isPickup}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            address,
            style: TextStyle(
              color: isPickup ? Colors.white : Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              fontWeight: isPickup ? FontWeight.w600 : FontWeight.w500,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isPickup ? _green.withValues(alpha: 0.15) : _gold.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isPickup ? _green.withValues(alpha: 0.3) : _gold.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Text(
            meta,
            style: TextStyle(
              color: isPickup ? _green : _gold,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _glassBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: _gold.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statBadge(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white54),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
