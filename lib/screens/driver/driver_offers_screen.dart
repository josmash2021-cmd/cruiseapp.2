import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
  GoogleMapController? _map;
  LatLng _driverPos = const LatLng(25.7617, -80.1918);
  bool _loading = true;
  bool _accepting = false;

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

    _initLocation();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _ctrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
        _ctrl.driverLatLng = _driverPos;
        _ctrl.start(driverId: widget.driverId);
        if (mounted) setState(() => _loading = false);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          _ctrl.driverLatLng = _driverPos;
          _ctrl.start(driverId: widget.driverId);
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
        _ctrl.driverLatLng = _driverPos;
        _ctrl.start(driverId: widget.driverId);
        if (mounted) setState(() => _loading = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _driverPos = LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      // Use default Miami
    }
    _ctrl.driverLatLng = _driverPos;
    _ctrl.start(driverId: widget.driverId);
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
        origin: _driverPos,
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
          initialDriverPos: _driverPos,
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
    _ctrl.rejectOffer(offer.offerId);
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
            child: GoogleMap(
              style: Theme.of(context).brightness == Brightness.dark
                  ? MapStyles.darkIOS
                  : MapStyles.lightIOS,
              initialCameraPosition: CameraPosition(
                target: _driverPos,
                zoom: 14,
              ),
              onMapCreated: (c) => _map = c,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              liteModeEnabled: false,
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
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Fare header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '\$${offer.fareUsd.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    offer.vehicleType,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Addresses
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Dots/line indicator
                Column(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: _green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Container(width: 2, height: 28, color: Colors.white24),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                // Addresses text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        offer.pickupAddress,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        offer.dropoffAddress,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
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
          // Stats row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                _statBadge(
                  Icons.near_me_rounded,
                  '${offer.distanceToPickupKm.toStringAsFixed(1)} km',
                ),
                const SizedBox(width: 10),
                _statBadge(
                  Icons.access_time_rounded,
                  '${offer.estimatedMinutes} min',
                ),
                const SizedBox(width: 10),
                _statBadge(Icons.person_outline_rounded, offer.riderName),
              ],
            ),
          ),
          // Action buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(
              children: [
                // Reject
                Expanded(
                  flex: 2,
                  child: OutlinedButton(
                    onPressed: () => _onReject(offer),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white60,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      S.of(context).skipOffer,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Accept
                Expanded(
                  flex: 3,
                  child: ElevatedButton(
                    onPressed: () => _onAccept(offer),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(
                      S.of(context).acceptOffer,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
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
