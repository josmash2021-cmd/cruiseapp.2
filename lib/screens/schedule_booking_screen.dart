import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../services/trip_firestore_service.dart';
import '../services/user_session.dart';
import 'airport_terminal_sheet.dart';
import 'payment_accounts_screen.dart';
import 'scheduled_rides_screen.dart';

class ScheduleBookingScreen extends StatefulWidget {
  final DateTime scheduledAt;

  const ScheduleBookingScreen({super.key, required this.scheduledAt});

  @override
  State<ScheduleBookingScreen> createState() => _ScheduleBookingScreenState();
}

class _ScheduleBookingScreenState extends State<ScheduleBookingScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _birminghamDefault = LatLng(33.5186, -86.8104);

  final _places = PlacesService(ApiKeys.webServices);
  final _directions = DirectionsService(ApiKeys.webServices);

  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();

  // Addresses
  String _pickupAddress = '';
  String _dropoffAddress = '';
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

  // Autocomplete
  List<PlaceSuggestion> _suggestions = [];
  bool _searchingPickup = false;
  Timer? _debounce;
  bool _showSuggestions = false;

  // Map
  GoogleMapController? _mapCtrl;
  Set<Polyline> _polylines = {};
  Set<Marker> _markers = {};
  bool _mapReady = false;

  // Route
  String _tripMiles = '';
  String _tripDuration = '';
  bool _routeLoaded = false;

  // Ride options
  int _selectedRide = 0;
  List<_RideOption> _rides = [];

  // Payment
  String _selectedPaymentMethod = 'google_pay';
  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;

  // Airport
  AirportSelection? _airportSelection;

  // State
  bool _isBooking = false;
  bool _isLoadingRoute = false;

  @override
  void initState() {
    super.initState();
    _loadPayments();
    _rides = _defaultRides();
    _pickupFocus.addListener(() => setState(() {}));
    _dropoffFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  List<_RideOption> _defaultRides() => [
    _RideOption(
      name: 'VIP',
      vehicle: 'Suburban',
      price: '\$--',
      eta: '--',
      promoted: true,
    ),
    _RideOption(name: 'Premium', vehicle: 'Camry', price: '\$--', eta: '--'),
    _RideOption(name: 'Comfort', vehicle: 'Fusion', price: '\$--', eta: '--'),
  ];

  Future<void> _loadPayments() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final last4 = await LocalDataService.getCreditCardLast4();
    final brand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      _linkedPaymentMethods = linked;
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
    });
  }

  // ── Autocomplete ────────────────────────────────────────────────────

  void _onPickupChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      final results = await _places.autocomplete(
        q,
        latitude: _pickupLatLng?.latitude ?? _birminghamDefault.latitude,
        longitude: _pickupLatLng?.longitude ?? _birminghamDefault.longitude,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searchingPickup = true;
        _showSuggestions = true;
      });
    });
  }

  void _onDropoffChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      final results = await _places.autocomplete(
        q,
        latitude: _pickupLatLng?.latitude ?? _birminghamDefault.latitude,
        longitude: _pickupLatLng?.longitude ?? _birminghamDefault.longitude,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searchingPickup = false;
        _showSuggestions = true;
      });
    });
  }

  Future<void> _onSelectSuggestion(PlaceSuggestion s) async {
    final details = await _places.geocodeAddress(s.description);
    if (!mounted) return;
    final latLng = details != null ? LatLng(details.lat, details.lng) : null;
    setState(() {
      _showSuggestions = false;
      _suggestions = [];
      if (_searchingPickup) {
        _pickupAddress = s.description;
        _pickupCtrl.text = s.description;
        _pickupLatLng = latLng;
        _pickupFocus.unfocus();
        if (_dropoffCtrl.text.trim().isEmpty) _dropoffFocus.requestFocus();
      } else {
        _dropoffAddress = s.description;
        _dropoffCtrl.text = s.description;
        _dropoffLatLng = latLng;
        _dropoffFocus.unfocus();
      }
    });
    _places.resetSession();
    _tryFetchRoute();
  }

  // ── Route ────────────────────────────────────────────────────────────

  Future<void> _tryFetchRoute() async {
    if (_pickupLatLng == null || _dropoffLatLng == null) return;
    setState(() {
      _isLoadingRoute = true;
      _routeLoaded = false;
    });
    try {
      final route = await _directions.getRoute(
        origin: _pickupLatLng!,
        destination: _dropoffLatLng!,
      );
      if (!mounted) return;
      if (route != null) {
        final miles = route.distanceMeters / 1609.34;
        final dur = route.durationText;
        setState(() {
          _tripMiles = '${miles.toStringAsFixed(1)} mi';
          _tripDuration = dur;
          _routeLoaded = true;
          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: route.points,
              color: _gold,
              width: 5,
            ),
          };
          _markers = {
            Marker(
              markerId: const MarkerId('pickup'),
              position: _pickupLatLng!,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueYellow,
              ),
              infoWindow: InfoWindow(title: S.of(context).pickupLabel),
            ),
            Marker(
              markerId: const MarkerId('dropoff'),
              position: _dropoffLatLng!,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueRed,
              ),
              infoWindow: InfoWindow(title: S.of(context).destinationLabel),
            ),
          };
          _updateRidePricing(dur);
        });
        _fitMap();
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingRoute = false);
  }

  void _updateRidePricing(String durationText) {
    final baseMin = _durationToMinutes(durationText);
    final vipMin = (baseMin * 0.85).ceil().clamp(1, 300);
    final premMin = baseMin;
    final comMin = (baseMin * 1.10).ceil().clamp(1, 300);
    final comMax = (baseMin * 1.45).ceil().clamp(comMin, 300);
    setState(() {
      _rides = [
        _RideOption(
          name: 'VIP',
          vehicle: 'Suburban',
          price: _price(vipMin, 2.2),
          eta: '$vipMin min',
          promoted: true,
        ),
        _RideOption(
          name: 'Premium',
          vehicle: 'Camry',
          price: _price(premMin, 1.35),
          eta: '$premMin min',
        ),
        _RideOption(
          name: 'Comfort',
          vehicle: 'Fusion',
          price: _price(comMax, 0.92),
          eta: '$comMin-$comMax min',
        ),
      ];
    });
  }

  int _durationToMinutes(String v) {
    final lower = v.toLowerCase();
    final h = RegExp(r'(\d+)\s*(h|hr|hrs|hour|hours)').firstMatch(lower);
    final m = RegExp(r'(\d+)\s*(m|min|mins|minute|minutes)').firstMatch(lower);
    var mins = 0;
    if (h != null) mins += (int.tryParse(h.group(1) ?? '') ?? 0) * 60;
    if (m != null) {
      mins += int.tryParse(m.group(1) ?? '') ?? 0;
    } else {
      final n = RegExp(r'(\d+)').firstMatch(lower);
      if (n != null) mins += int.tryParse(n.group(1) ?? '') ?? 0;
    }
    return mins.clamp(1, 300);
  }

  String _price(int minutes, double mult) {
    final v = (minutes / 60.0) * 120.0 * mult;
    return '\$${v.toStringAsFixed(2)}';
  }

  void _fitMap() {
    if (!_mapReady || _pickupLatLng == null || _dropoffLatLng == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        _pickupLatLng!.latitude < _dropoffLatLng!.latitude
            ? _pickupLatLng!.latitude
            : _dropoffLatLng!.latitude,
        _pickupLatLng!.longitude < _dropoffLatLng!.longitude
            ? _pickupLatLng!.longitude
            : _dropoffLatLng!.longitude,
      ),
      northeast: LatLng(
        _pickupLatLng!.latitude > _dropoffLatLng!.latitude
            ? _pickupLatLng!.latitude
            : _dropoffLatLng!.latitude,
        _pickupLatLng!.longitude > _dropoffLatLng!.longitude
            ? _pickupLatLng!.longitude
            : _dropoffLatLng!.longitude,
      ),
    );
    _mapCtrl?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 64));
  }

  // ── Booking ──────────────────────────────────────────────────────────

  Future<void> _book() async {
    if (_pickupLatLng == null || _dropoffLatLng == null) {
      _showErr(S.of(context).enterBothAddresses);
      return;
    }
    if (_pickupAddress.isEmpty || _dropoffAddress.isEmpty) {
      _showErr(S.of(context).enterBothAddresses);
      return;
    }
    if (!_linkedPaymentMethods.contains(_selectedPaymentMethod)) {
      _showErr(S.of(context).pleaseAddPaymentFirst);
      return;
    }

    setState(() => _isBooking = true);

    try {
      final riderId = await ApiService.getCurrentUserId();
      if (riderId == null) throw Exception('Not logged in');

      final fareStr = _rides[_selectedRide].price
          .replaceAll('\$', '')
          .replaceAll(',', '');
      final fare = double.tryParse(fareStr) ?? 0;
      final isAirport = _airportSelection != null;
      final notes = _airportSelection?.flightNumber != null
          ? 'Flight: ${_airportSelection!.flightNumber}'
          : null;

      final tripData = await ApiService.createTrip(
        riderId: riderId,
        pickupAddress: _pickupAddress,
        dropoffAddress: _dropoffAddress,
        pickupLat: _pickupLatLng!.latitude,
        pickupLng: _pickupLatLng!.longitude,
        dropoffLat: _dropoffLatLng!.latitude,
        dropoffLng: _dropoffLatLng!.longitude,
        fare: fare,
        vehicleType: _rides[_selectedRide].name,
        scheduledAt: widget.scheduledAt,
        isAirport: isAirport,
        airportCode: _airportSelection?.airport.code,
        terminal: _airportSelection?.terminal,
        pickupZone: _airportSelection?.pickupZone,
        notes: notes,
      );

      final tripId = tripData['id'] as int?;

      // 1-hour notification
      if (tripId != null) {
        try {
          await NotificationService.scheduleRideReminder(
            tripId: tripId,
            rideTime: widget.scheduledAt,
            pickup: _pickupAddress,
            dropoff: _dropoffAddress,
          );
        } catch (_) {}
      }

      // Mirror to Firestore for dispatch admin
      try {
        final session = await UserSession.getUser();
        final milesStr = _tripMiles.replaceAll(RegExp(r'[^\d.]'), '');
        final km = (double.tryParse(milesStr) ?? 0.0) * 1.60934;
        final durStr = _tripDuration.replaceAll(RegExp(r'[^\d]'), '');
        final durMin = int.tryParse(durStr) ?? 0;
        final name =
            '${session?['firstName'] ?? ''} ${session?['lastName'] ?? ''}'
                .trim();
        await TripFirestoreService.submitRideRequest(
          passengerName: name.isEmpty ? 'Passenger' : name,
          passengerPhone: session?['phone'] ?? '',
          pickupAddress: _pickupAddress,
          dropoffAddress: _dropoffAddress,
          pickupLat: _pickupLatLng!.latitude,
          pickupLng: _pickupLatLng!.longitude,
          dropoffLat: _dropoffLatLng!.latitude,
          dropoffLng: _dropoffLatLng!.longitude,
          fare: fare,
          distanceKm: km,
          durationMin: durMin,
          vehicleType: _rides[_selectedRide].name,
          paymentMethod: _selectedPaymentMethod,
          scheduledAt: widget.scheduledAt,
          isAirportTrip: isAirport,
        );
      } catch (_) {}

      await LocalDataService.addNotification(
        title: S.of(context).rideScheduled,
        message: S
            .of(context)
            .rideScheduledMsg(
              DateFormat('MMM d \'at\' h:mm a').format(widget.scheduledAt),
            ),
        type: 'ride',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _gold,
          content: Text(
            S
                .of(context)
                .scheduledForDate(
                  DateFormat('MMM d · h:mm a').format(widget.scheduledAt),
                ),
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // Pop all the way back and go to scheduled rides
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ScheduledRidesScreen()));
    } catch (e) {
      if (mounted) _showErr(S.of(context).failedToBook('$e'));
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  void _showErr(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFFF5252),
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Payment ──────────────────────────────────────────────────────────

  void _showPaymentSelector() {
    final creditLabel = (_savedCardBrand != null && _savedCardLast4 != null)
        ? '${_savedCardBrand![0].toUpperCase()}${_savedCardBrand!.substring(1)} •••• $_savedCardLast4'
        : S.of(context).creditOrDebitCard;
    final methods = [
      ('google_pay', 'Google Pay'),
      ('credit_card', creditLabel),
      ('paypal', 'PayPal'),
    ];
    final c = AppColors.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        decoration: BoxDecoration(
          color: c.mapPanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  S.of(context).paymentMethodLabel,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ...methods.map((m) {
                final (id, label) = m;
                final selected = id == _selectedPaymentMethod;
                final linked = _linkedPaymentMethods.contains(id);
                return GestureDetector(
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => _selectedPaymentMethod = id);
                    if (!linked) {
                      Future.delayed(const Duration(milliseconds: 200), () {
                        if (!mounted) return;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PaymentAccountsScreen(),
                          ),
                        ).then((_) => _loadPayments());
                      });
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? _gold.withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      border: selected
                          ? Border.all(
                              color: _gold.withValues(alpha: 0.4),
                              width: 1.2,
                            )
                          : null,
                    ),
                    child: Row(
                      children: [
                        _payLogo(id, 36),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                linked
                                    ? S.of(context).readyLabel
                                    : S.of(context).tapToSetUp,
                                style: TextStyle(
                                  color: linked
                                      ? const Color(0xFF4CAF50)
                                      : c.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          const Icon(
                            Icons.check_circle_rounded,
                            color: _gold,
                            size: 22,
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _payLogo(String id, double size) {
    if (id == 'google_pay') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300, width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Image.asset('assets/images/google_g.png', fit: BoxFit.contain),
        ),
      );
    }
    if (id == 'paypal') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300, width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Image.asset(
            'assets/images/paypal_logo.png',
            fit: BoxFit.contain,
          ),
        ),
      );
    }
    // credit card
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.credit_card_rounded, color: _gold, size: 20),
    );
  }

  String get _payLabel {
    if (_selectedPaymentMethod == 'google_pay') return 'Google Pay';
    if (_selectedPaymentMethod == 'paypal') return 'PayPal';
    if (_savedCardLast4 != null && _savedCardBrand != null) {
      final b = _savedCardBrand!;
      return '${b[0].toUpperCase()}${b.substring(1)} •••• $_savedCardLast4';
    }
    return S.of(context).creditCardLabel2;
  }

  // ── Airport ──────────────────────────────────────────────────────────

  Future<void> _showAirportSheet() async {
    if (_airportSelection != null) {
      setState(() => _airportSelection = null);
      return;
    }
    final c = AppColors.of(context);
    final result = await showModalBottomSheet<AirportSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AirportTerminalSheet(isDark: c.isDark),
    );
    if (!mounted || result == null) return;
    setState(() {
      _airportSelection = result;
      _dropoffAddress = result.airport.name;
      _dropoffCtrl.text = result.airport.name;
    });
    final details = await _places.geocodeAddress(result.airport.name);
    if (!mounted) return;
    if (details != null) {
      setState(() => _dropoffLatLng = LatLng(details.lat, details.lng));
      _tryFetchRoute();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final schedLabel = DateFormat(
      "EEE, MMM d 'at' h:mm a",
    ).format(widget.scheduledAt);

    return Scaffold(
      backgroundColor: c.bg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Column(
            children: [
              // ── Header ──
              Container(
                color: c.bg,
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 16,
                  right: 16,
                  bottom: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.of(context).scheduleARide,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.calendar_today_rounded,
                                    color: _gold,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      schedLabel,
                                      style: const TextStyle(
                                        color: _gold,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // ── Address inputs ──
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1D24),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        children: [
                          _addressField(
                            ctrl: _pickupCtrl,
                            focus: _pickupFocus,
                            hint: S.of(context).pickupLocation,
                            icon: Icons.radio_button_checked,
                            iconColor: _gold,
                            onChanged: _onPickupChanged,
                            onClear: () {
                              _pickupCtrl.clear();
                              setState(() {
                                _pickupAddress = '';
                                _pickupLatLng = null;
                                _routeLoaded = false;
                                _polylines = {};
                                _markers = {};
                              });
                            },
                          ),
                          Divider(
                            height: 1,
                            color: _gold.withValues(alpha: 0.2),
                          ),
                          _addressField(
                            ctrl: _dropoffCtrl,
                            focus: _dropoffFocus,
                            hint: S.of(context).whereTo,
                            icon: Icons.location_on_rounded,
                            iconColor: const Color(0xFFFF5252),
                            onChanged: _onDropoffChanged,
                            onClear: () {
                              _dropoffCtrl.clear();
                              setState(() {
                                _dropoffAddress = '';
                                _dropoffLatLng = null;
                                _routeLoaded = false;
                                _polylines = {};
                                _markers = {};
                                _airportSelection = null;
                              });
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Airport badge
                    GestureDetector(
                      onTap: _showAirportSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: _airportSelection != null
                              ? const Color(0xFF4285F4).withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: _airportSelection != null
                                ? const Color(0xFF4285F4).withValues(alpha: 0.5)
                                : Colors.white24,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _airportSelection != null
                                  ? Icons.flight_rounded
                                  : Icons.flight_outlined,
                              color: _airportSelection != null
                                  ? const Color(0xFF4285F4)
                                  : Colors.white54,
                              size: 15,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _airportSelection != null
                                  ? S
                                        .of(context)
                                        .airportCodeTapToRemove(
                                          _airportSelection!.airport.code,
                                        )
                                  : S.of(context).airportRide,
                              style: TextStyle(
                                color: _airportSelection != null
                                    ? const Color(0xFF4285F4)
                                    : Colors.white54,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Map ──
              Expanded(
                child: Stack(
                  children: [
                    GoogleMap(
                      style: MapStyles.dark,
                      initialCameraPosition: CameraPosition(
                        target: _birminghamDefault,
                        zoom: 12,
                      ),
                      onMapCreated: (ctrl) {
                        _mapCtrl = ctrl;
                        setState(() => _mapReady = true);
                        if (_pickupLatLng != null && _dropoffLatLng != null) {
                          _fitMap();
                        }
                      },
                      polylines: _polylines,
                      markers: _markers,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                    ),
                    if (_isLoadingRoute)
                      const Center(
                        child: CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 2.5,
                        ),
                      ),
                    if (!_routeLoaded && !_isLoadingRoute)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            S.of(context).enterAddressesToSeeRoute,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── Bottom panel ──
              Container(
                decoration: BoxDecoration(
                  color: c.mapPanel,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  border: Border.all(color: c.border),
                ),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    14,
                    16,
                    MediaQuery.of(context).padding.bottom + 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: c.iconMuted,
                            borderRadius: BorderRadius.circular(40),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      if (_routeLoaded) ...[
                        Text(
                          '$_tripMiles · $_tripDuration',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Ride options
                      ..._rides.asMap().entries.map((e) {
                        final i = e.key;
                        final ride = e.value;
                        final selected = i == _selectedRide;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedRide = i),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? _gold.withValues(alpha: 0.08)
                                  : c.border,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: selected
                                    ? _gold.withValues(alpha: 0.5)
                                    : c.border,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 50,
                                  height: 36,
                                  child: Image.asset(
                                    'assets/images/${ride.vehicle.toLowerCase()}.png',
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.directions_car_rounded,
                                      color: _gold,
                                      size: 28,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            ride.name,
                                            style: TextStyle(
                                              color: c.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          if (ride.promoted) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: _gold.withValues(
                                                  alpha: 0.15,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                S.of(context).bestLabel,
                                                style: const TextStyle(
                                                  color: _gold,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        ride.vehicle,
                                        style: TextStyle(
                                          color: c.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      ride.price,
                                      style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      ride.eta,
                                      style: TextStyle(
                                        color: c.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                if (selected) ...[
                                  const SizedBox(width: 10),
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: _gold,
                                    size: 20,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      }),

                      const SizedBox(height: 4),

                      // Payment method selector
                      GestureDetector(
                        onTap: _showPaymentSelector,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: c.border,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _gold.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              _payLogo(_selectedPaymentMethod, 34),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _payLabel,
                                      style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      _linkedPaymentMethods.contains(
                                            _selectedPaymentMethod,
                                          )
                                          ? S.of(context).tapToChange
                                          : S.of(context).notAddedTapToSetUp,
                                      style: TextStyle(
                                        color:
                                            _linkedPaymentMethods.contains(
                                              _selectedPaymentMethod,
                                            )
                                            ? c.textSecondary
                                            : Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: c.textSecondary,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Book button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: _isBooking ? null : _book,
                          child: _isBooking
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.black,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.calendar_month_rounded,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        '${S.of(context).bookScheduledRide} · ${_rides[_selectedRide].price}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
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
              ),
            ],
          ),

          // Suggestions overlay
          if (_showSuggestions && _suggestions.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 110,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    color: c.mapPanel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: c.border),
                      itemBuilder: (_, i) {
                        final s = _suggestions[i];
                        return InkWell(
                          onTap: () => _onSelectSuggestion(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  color: c.textSecondary,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    s.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _addressField({
    required TextEditingController ctrl,
    required FocusNode focus,
    required String hint,
    required IconData icon,
    required Color iconColor,
    required ValueChanged<String> onChanged,
    required VoidCallback onClear,
  }) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              style: TextStyle(color: c.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: c.textSecondary, fontSize: 15),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: onChanged,
              onTap: () => setState(() => _showSuggestions = true),
            ),
          ),
          if (ctrl.text.isNotEmpty)
            GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                color: c.textSecondary,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}

class _RideOption {
  final String name;
  final String vehicle;
  final String price;
  final String eta;
  final bool promoted;

  const _RideOption({
    required this.name,
    required this.vehicle,
    required this.price,
    required this.eta,
    this.promoted = false,
  });
}
