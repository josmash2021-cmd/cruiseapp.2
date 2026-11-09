import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../config/page_transitions.dart';
import '../map/web_map_view.dart';
import '../models/lat_lng.dart';
import '../l10n/app_localizations.dart';
import '../services/place_ranking.dart' show withoutCountry;
import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/neu_style.dart';
import '../widgets/route_connector_line.dart';
import '../utils/mapbox_safe.dart';
import '../services/map_controller_cache.dart';
import 'home_screen.dart';
import 'schedule_hub_screen.dart';

/// "Viaje reservado" — shown after the rider books a reservation.
///
/// Lyft-style (owner pick A, 2026-11-08, drawing
/// https://claude.ai/artifact/ACDx65Q6BtkogLRCsdDaDi): the route on the map,
/// framed ABOVE a bottom card — the reservation time large, the estimated
/// arrival, pickup → drop-off on the app's rail, the car, price and payment,
/// "Esperando conductor", and "Listo" / "Ver mis reservas". It stays until
/// the rider taps (it used to leave for home on its own after 3.5 s, before
/// anyone had read it).
class RideBookingConfirmedScreen extends StatefulWidget {
  final DateTime scheduledAt;
  final String pickupAddress;
  final String dropoffAddress;
  final String vehicleType;
  final double fare;
  final bool isFree;
  final double? pickupLat;
  final double? pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
  final List<LatLng>? routePoints;

  /// The ride's minutes, for "Llegada aprox." (hidden without them).
  final int? routeMinutes;

  /// The category's car render (the booking sheet's).
  final String? carAsset;

  /// How it's paid ("Visa •••• 4242"); hidden when unknown.
  final String? paymentLabel;

  /// To the airport: the drop-off pin is the plane, not the flag.
  final bool dropoffIsAirport;

  const RideBookingConfirmedScreen({
    super.key,
    required this.scheduledAt,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.vehicleType,
    required this.fare,
    this.isFree = false,
    this.pickupLat,
    this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
    this.routePoints,
    this.routeMinutes,
    this.carAsset,
    this.paymentLabel,
    this.dropoffIsAirport = false,
  });

  @override
  State<RideBookingConfirmedScreen> createState() =>
      _RideBookingConfirmedScreenState();
}

/// "BHM · Birmingham-Shuttlesworth … — Delta Air Lines" → (place, airline);
/// "3659 Lorna Rd, Hoover, AL, USA" → ("3659 Lorna Rd", "Hoover, AL").
(String, String) splitBookedAddress(String address) {
  final a = address.trim();
  final dash = a.indexOf(' — ');
  if (dash > 0) return (a.substring(0, dash).trim(), a.substring(dash + 3).trim());
  final comma = a.indexOf(',');
  if (comma > 0) {
    return (
      a.substring(0, comma).trim(),
      withoutCountry(a.substring(comma + 1).trim()),
    );
  }
  return (a, '');
}

class _RideBookingConfirmedScreenState extends State<RideBookingConfirmedScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  /// The card slides up and the check pops.
  late final AnimationController _enterCtrl;
  late final Animation<Offset> _sheetSlide;
  late final Animation<double> _checkScale;

  /// "Esperando conductor"'s dot breathes.
  late final AnimationController _pulseCtrl;

  final GlobalKey _sheetKey = GlobalKey();
  mapbox.MapboxMap? _mapCtrl;
  WebMapController? _webMap;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _sheetSlide = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0, 0.6, curve: Cubic(0.22, 1, 0.36, 1)),
    ));
    _checkScale = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.35, 0.9, curve: Curves.elasticOut),
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _enterCtrl.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!(MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
        _pulseCtrl.repeat(reverse: true);
      }
      _fitRoute();
    });
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  bool get _hasMapData => widget.pickupLat != null && widget.pickupLng != null;

  /// Every point the camera has to show: the route, or the two ends.
  List<LatLng> get _framePoints {
    final route = widget.routePoints;
    if (route != null && route.length >= 2) return route;
    return [
      if (widget.pickupLat != null && widget.pickupLng != null)
        LatLng(widget.pickupLat!, widget.pickupLng!),
      if (widget.dropoffLat != null && widget.dropoffLng != null)
        LatLng(widget.dropoffLat!, widget.dropoffLng!),
    ];
  }

  /// The card's height — the map frames the route in what is left above.
  double get _sheetHeight {
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    return (box != null && box.hasSize) ? box.size.height : 470;
  }

  /// The whole route above the card, flat and north-up.
  Future<void> _fitRoute() async {
    if (!mounted) return;
    final pts = _framePoints;
    if (pts.isEmpty) return;
    final top = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 56;
    final bottom = _sheetHeight + 36;
    final web = _webMap;
    if (web != null) {
      web.fitBounds(
        pts.map((p) => (lng: p.longitude, lat: p.latitude)).toList(),
        paddingTop: top,
        paddingBottom: bottom,
        paddingLeft: 48,
        paddingRight: 48,
        durationMs: 0,
        pitch: 0,
        bearing: 0,
      );
      return;
    }
    final map = _mapCtrl;
    if (map == null) return;
    double minLat = pts.first.latitude, maxLat = minLat;
    double minLng = pts.first.longitude, maxLng = minLng;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    try {
      final cam = await map.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
          mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
        ],
        mapbox.CameraOptions(bearing: 0, pitch: 0),
        mapbox.MbxEdgeInsets(top: top, bottom: bottom, left: 48, right: 48),
        null,
        null,
      );
      final zoom = cam.zoom;
      if (zoom == null || zoom.isNaN || !mounted || _mapCtrl != map) return;
      await map.setCamera(mapbox.CameraOptions(
        center: cam.center,
        zoom: zoom.clamp(3.0, 16.5),
        bearing: 0,
        pitch: 0,
      ));
    } catch (_) {}
  }

  void _goHome({bool openReservations = false}) {
    if (_leaving) return;
    _leaving = true;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    nav.pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
      (_) => false,
    );
    // "Ver mis reservas": the reservations ("Tus reservas") over home, so
    // back lands on home — not on this page.
    if (openReservations) {
      nav.push(slideUpFadeRoute(const ScheduleHubScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final media = MediaQuery.of(context);
    final midLat = (widget.pickupLat != null && widget.dropoffLat != null)
        ? (widget.pickupLat! + widget.dropoffLat!) / 2
        : widget.pickupLat ?? 0;
    final midLng = (widget.pickupLng != null && widget.dropoffLng != null)
        ? (widget.pickupLng! + widget.dropoffLng!) / 2
        : widget.pickupLng ?? 0;

    return PopScope(
      // Back = Listo: the booking is done, there is nothing behind to undo.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goHome();
      },
      child: Scaffold(
        backgroundColor: neuBase,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── The route ──
            if (_hasMapData)
              IgnorePointer(
                child: RepaintBoundary(
                  // The native MapWidget has no web implementation — GL JS
                  // takes over in the browser with the same route + pins.
                  child: kIsWeb
                      ? WebMapView(
                          key: const ValueKey('booking_confirmed_map_web'),
                          initialLng: midLng,
                          initialLat: midLat,
                          initialZoom: 12,
                          styleUri: MapboxConfig.styleDark,
                          onControllerCreated: _onWebMapCreated,
                        )
                      : mapbox.MapWidget(
                          textureView: true,
                          styleUri: MapboxConfig.styleDark,
                          cameraOptions: mapbox.CameraOptions(
                            center: mapbox.Point(
                              coordinates: mapbox.Position(midLng, midLat),
                            ),
                            zoom: 12,
                            pitch: 0.0,
                          ),
                          onMapCreated: _onMapCreated,
                        ),
                ),
              )
            else
              const ColoredBox(color: neuBase),

            // A soft shade under the status bar so its icons read on the map.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: media.padding.top + 60,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.45),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── The card ──
            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: _sheetSlide,
                child: _sheet(s, media),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheet(S s, MediaQueryData media) {
    final (pickTitle, pickSub) = splitBookedAddress(widget.pickupAddress);
    final (dropTitle, dropSub) = splitBookedAddress(widget.dropoffAddress);
    final minutes = widget.routeMinutes;
    final arrival = minutes != null && minutes > 0
        ? widget.scheduledAt.add(Duration(minutes: minutes))
        : null;
    final price = widget.isFree ? s.free : '\$${widget.fare.toStringAsFixed(2)}';

    return Container(
      key: _sheetKey,
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, 10, 20, media.padding.bottom + 10),
      decoration: BoxDecoration(
        color: neuBase,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ✓ Viaje reservado
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScaleTransition(
                scale: _checkScale,
                child: Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: const BoxDecoration(
                    color: _gold,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.black, size: 19),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.bookedTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.bookedSubtitle.replaceAll('\n', ' '),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // When — the time large, the arrival beside it.
          Container(
            key: const ValueKey('booked-when'),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: neuBox(radius: 16, pressed: true),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.bookedDay(widget.scheduledAt).toUpperCase(),
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                        ),
                      ),
                      Text(
                        s.bookedClock(widget.scheduledAt),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                if (arrival != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        s.bookedArrivalApprox,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        s.bookedClock(arrival),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Pickup → drop-off on the app's rail.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 20,
                  child: Column(
                    children: [
                      const SizedBox(height: 4),
                      _ring(pickup: true),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 2),
                          child: RouteConnectorLine(),
                        ),
                      ),
                      _ring(pickup: false),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _place(pickTitle, pickSub),
                      const SizedBox(height: 14),
                      _place(dropTitle, dropSub),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
          const SizedBox(height: 10),

          // The car, the payment, the price.
          Row(
            children: [
              if (widget.carAsset != null) ...[
                SizedBox(
                  width: 72,
                  height: 30,
                  child: Image.asset(
                    widget.carAsset!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.directions_car_rounded,
                        color: _gold,
                        size: 24),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.vehicleType,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((widget.paymentLabel ?? '').isNotEmpty)
                      Row(
                        children: [
                          Icon(Icons.credit_card_rounded,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.55)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.paymentLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Text(
                price,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Esperando conductor
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _gold.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: Tween<double>(begin: 1, end: 0.25)
                        .animate(_pulseCtrl),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                          color: _gold, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.bookedWaitingDriver,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            height: 52,
            child: ElevatedButton(
              key: const ValueKey('booked-done'),
              onPressed: _goHome,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(
                s.done,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('booked-see-reservations'),
            onPressed: () => _goHome(openReservations: true),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              s.bookedSeeReservations,
              style: const TextStyle(
                color: _gold,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ring({required bool pickup}) {
    final color = pickup ? _gold : Colors.white;
    return Container(
      width: 13,
      height: 13,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: color, width: 1.8)),
      ),
      alignment: Alignment.center,
      child: pickup
          ? Container(
              width: 5,
              height: 5,
              decoration:
                  const BoxDecoration(color: _gold, shape: BoxShape.circle),
            )
          : null,
    );
  }

  Widget _place(String title, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12.5,
            ),
          ),
      ],
    );
  }

  /// Web counterpart of [_onMapCreated]: same navy/gold, same gold route,
  /// same pickup/dropoff pins.
  void _onWebMapCreated(WebMapController c) {
    _webMap = c;
    c.applyNavyGoldTheme();
    final routePts = widget.routePoints;
    if (routePts != null && routePts.length >= 2) {
      c.setPolyline(
        'route',
        routePts.map((p) => (lng: p.longitude, lat: p.latitude)).toList(),
        color: '#FFD700',
        width: 5,
      );
    }
    if (widget.pickupLat != null && widget.pickupLng != null) {
      c.addMarker('pickup', widget.pickupLng!, widget.pickupLat!);
    }
    if (widget.dropoffLat != null && widget.dropoffLng != null) {
      c.addMarker('dropoff', widget.dropoffLng!, widget.dropoffLat!);
    }
    _fitRoute();
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    // Cache controller for reuse across rider screens
    MapControllerCache.instance.cache(ctrl);
    await MapTheme.applyNavyGold(ctrl);
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    unawaited(MapBrand.show(ctrl));
    unawaited(_fitRoute());

    // Route polyline
    final routePts = widget.routePoints;
    if (routePts != null && routePts.length >= 2) {
      final polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
      final routeGeo = safeLineString(routePts);
      if (routeGeo != null) {
        await polyMgr.create(mapbox.PolylineAnnotationOptions(
          geometry: routeGeo,
          lineColor: const Color(0xFFFFD700).toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      }
    }

    // Smart pins
    final pointMgr = await ctrl.annotations.createPointAnnotationManager();
    try {
      await ctrl.style.setStyleLayerProperty(
          pointMgr.id, 'icon-pitch-alignment', 'viewport');
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-allow-overlap', true);
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-ignore-placement', true);
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-anchor', 'bottom');
    } catch (_) {}

    if (widget.pickupLat != null && widget.pickupLng != null) {
      final pickupBytes = await renderCircularPinBytes(
          icon: CircularPinIcon.person, isPickup: true, radius: 44);
      final pickupPoint = safePoint(widget.pickupLng!, widget.pickupLat!);
      if (pickupPoint != null) {
        await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: pickupPoint,
          image: pickupBytes,
          iconSize: 0.65,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }

    if (widget.dropoffLat != null && widget.dropoffLng != null) {
      // The destination's pin: the plane for an airport, else the flag
      // (it was a house, whatever the destination).
      final dropoffBytes = await renderCircularPinBytes(
          icon: widget.dropoffIsAirport
              ? CircularPinIcon.airplane
              : CircularPinIcon.flag,
          isPickup: false,
          radius: 44);
      final dropoffPoint = safePoint(widget.dropoffLng!, widget.dropoffLat!);
      if (dropoffPoint != null) {
        await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: dropoffPoint,
          image: dropoffBytes,
          iconSize: 0.65,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }
  }
}
