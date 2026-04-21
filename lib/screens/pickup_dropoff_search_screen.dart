import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../config/api_keys.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import 'map_picker_screen.dart';
import 'ride_request_screen.dart';

// ═══════════════════════════════════════════════════════════════════
//  Design tokens (match Shopify "vipRide__locPicker")
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
// .vipRide__locPicker { background: rgba(10,17,40,.75); backdrop-filter: blur(28px) }
// The widget is always opaque on phone (no content behind the route), so
// we render the effective solid color #0A1128 — the same navy the web
// shows once the blur settles on the dark page body.
const _bg = Color(0xFF0A1128);
const _cardBg = Color(0xFF1A1D24);

// ═══════════════════════════════════════════════════════════════════
//  PickupDropoffSearchScreen — locpicker port
// ═══════════════════════════════════════════════════════════════════

class PickupDropoffSearchScreen extends StatefulWidget {
  final String initialPickupText;
  final double? initialPickupLat;
  final double? initialPickupLng;

  const PickupDropoffSearchScreen({
    super.key,
    this.initialPickupText = 'Current location',
    this.initialPickupLat,
    this.initialPickupLng,
  });

  @override
  State<PickupDropoffSearchScreen> createState() =>
      _PickupDropoffSearchScreenState();
}

class _PickupDropoffSearchScreenState extends State<PickupDropoffSearchScreen>
    with SingleTickerProviderStateMixin {
  final _placesService = PlacesService(ApiKeys.webServices);

  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();

  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;
  Timer? _debounce;
  List<FavoritePlace> _favorites = [];
  List<String> _recents = [];

  // Camera state captured from the last map-picker confirm — lets
  // RideRequestScreen boot at the exact same view and eliminates the
  // perceived "two-map" handoff flash.
  double? _handoffLat;
  double? _handoffLng;
  double? _handoffZoom;
  double? _handoffBearing;
  double? _handoffPitch;
  bool _handoffCover = false;

  bool _editingPickup = false;
  bool _editingDropoff = true;

  PlaceDetails? _pickupDetails;
  PlaceDetails? _dropoffDetails;
  String _pickupLabel = '';
  String _dropoffLabel = '';

  double? _resolvedLat;
  double? _resolvedLng;

  // Swap button rotation
  late final AnimationController _swapCtl;

  @override
  void initState() {
    super.initState();
    _swapCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    _pickupCtrl.text = widget.initialPickupText;
    _pickupLabel = widget.initialPickupText;

    if (widget.initialPickupLat != null && widget.initialPickupLng != null) {
      _resolvedLat = widget.initialPickupLat;
      _resolvedLng = widget.initialPickupLng;
      _pickupDetails = PlaceDetails(
        address: widget.initialPickupText,
        lat: widget.initialPickupLat!,
        lng: widget.initialPickupLng!,
      );
      _resolveAddressFromCoords(widget.initialPickupLat!, widget.initialPickupLng!);
    } else {
      _resolveGpsPickup();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dropoffFocus.requestFocus();
    });
    _loadFavorites();
  }

  Future<void> _resolveGpsPickup() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      _resolvedLat = pos.latitude;
      _resolvedLng = pos.longitude;
      final address = await _placesService
          .reverseGeocode(lat: pos.latitude, lng: pos.longitude)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (address != null && address.isNotEmpty) {
        setState(() {
          _pickupDetails = PlaceDetails(
            address: address,
            lat: pos.latitude,
            lng: pos.longitude,
          );
          _pickupLabel = address;
          _pickupCtrl.text = address;
        });
      } else {
        _pickupDetails = PlaceDetails(
          address: widget.initialPickupText,
          lat: pos.latitude,
          lng: pos.longitude,
        );
      }
    } catch (_) {
      // GPS unavailable — keep placeholder text
    }
  }

  Future<void> _resolveAddressFromCoords(double lat, double lng) async {
    try {
      final address = await _placesService
          .reverseGeocode(lat: lat, lng: lng)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (address != null && address.isNotEmpty) {
        setState(() {
          _pickupDetails = PlaceDetails(address: address, lat: lat, lng: lng);
          _pickupLabel = address;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadFavorites() async {
    final favs = await LocalDataService.getFavorites();
    final recents = await LocalDataService.getRecentSearches();
    if (mounted) {
      setState(() {
        _favorites = favs;
        _recents = recents;
      });
    }
  }

  FavoritePlace? _findFavoriteByKey(String key) {
    for (final f in _favorites) {
      if (f.label.toLowerCase() == key.toLowerCase()) return f;
    }
    return null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _swapCtl.dispose();
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    super.dispose();
  }

  // ── Input handling ──

  void _onTextChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _search(text.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final results = await _placesService.autocomplete(
        query,
        latitude: _resolvedLat ?? widget.initialPickupLat,
        longitude: _resolvedLng ?? widget.initialPickupLng,
      );
      if (mounted) {
        setState(() {
          _suggestions = results;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onSuggestionTap(PlaceSuggestion suggestion) async {
    final details = await _placesService.details(suggestion.placeId);
    if (details == null || !mounted) return;

    if (_editingDropoff) {
      setState(() {
        _dropoffDetails = details;
        _dropoffLabel = suggestion.description;
        _dropoffCtrl.text = suggestion.description;
        _suggestions = [];
      });
      if (_pickupDetails != null) {
        _returnResults();
      } else {
        setState(() {
          _editingPickup = true;
          _editingDropoff = false;
        });
        _pickupFocus.requestFocus();
      }
    } else {
      setState(() {
        _pickupDetails = details;
        _pickupLabel = suggestion.description;
        _pickupCtrl.text = suggestion.description;
        _suggestions = [];
      });
      if (_dropoffDetails != null) {
        _returnResults();
      } else {
        setState(() {
          _editingPickup = false;
          _editingDropoff = true;
        });
        _dropoffFocus.requestFocus();
      }
    }
    // Record recent
    if (suggestion.description.isNotEmpty) {
      await LocalDataService.addRecentSearch(suggestion.description);
      if (mounted) _loadFavorites();
    }
  }

  Future<void> _onFieldSubmitted(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;

    setState(() => _loading = true);

    try {
      final results = await _placesService.autocomplete(
        query,
        latitude: _resolvedLat ?? widget.initialPickupLat,
        longitude: _resolvedLng ?? widget.initialPickupLng,
      );
      if (results.isNotEmpty && mounted) {
        await _onSuggestionTap(results.first);
        return;
      }

      final exact = await _placesService.geocodeAddress(
        query,
        latitude: _resolvedLat ?? widget.initialPickupLat,
        longitude: _resolvedLng ?? widget.initialPickupLng,
      );
      if (exact != null && mounted) {
        final exactSuggestion = PlaceSuggestion(
          description: exact.address.isEmpty ? query : exact.address,
          placeId: 'exact:${exact.lat},${exact.lng}',
          lat: exact.lat,
          lng: exact.lng,
        );
        await _onSuggestionTap(exactSuggestion);
        return;
      }
    } catch (_) {}

    if (mounted) setState(() => _loading = false);
  }

  void _swapFields() {
    HapticFeedback.selectionClick();
    _swapCtl.forward(from: 0);

    final tmpDetails = _pickupDetails;
    final tmpLabel = _pickupLabel;
    final tmpText = _pickupCtrl.text;

    setState(() {
      _pickupDetails = _dropoffDetails;
      _pickupLabel = _dropoffLabel;
      _pickupCtrl.text = _dropoffCtrl.text;

      _dropoffDetails = tmpDetails;
      _dropoffLabel = tmpLabel;
      _dropoffCtrl.text = tmpText;
    });

    if (_pickupDetails != null && _dropoffDetails != null) {
      _returnResults();
    }
  }

  Future<void> _openMapPicker() async {
    HapticFeedback.lightImpact();
    final lat = _resolvedLat ?? widget.initialPickupLat;
    final lng = _resolvedLng ?? widget.initialPickupLng;

    // ── Single-canvas map picker (matches the Shopify widget) ──
    // Instead of pushing a separate MapPickerScreen that creates its
    // own Mapbox instance and then pushReplacement'ing back, we
    // pushReplacement straight into RideRequestScreen's pickingLocation
    // phase. The same Mapbox canvas then drives picker → confirm →
    // route preview with zero teleports.
    setState(() => _handoffCover = true);
    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        RideRequestScreen(
          initialPickupDetails: _pickupDetails,
          initialDropoffDetails: _dropoffDetails,
          initialPickupLabel: _pickupLabel,
          initialDropoffLabel: _dropoffLabel,
          handoffLat: lat,
          handoffLng: lng,
          pickerMode: true,
          pickerIsPickup: _editingPickup,
        ),
      ),
    );
    return;
    // Unreachable (kept for reference / fallback path — auto-stripped).
    // ignore: dead_code
    final raw = await Navigator.of(context).push<Map<String, dynamic>>(
      slideUpFadeRoute(
        MapPickerScreen(
          initialLat: lat,
          initialLng: lng,
          isPickup: _editingPickup,
        ),
      ),
    );
    if (raw == null || !mounted) return;

    final result = PlaceDetails(
      address: (raw['address'] as String?) ?? '',
      lat: (raw['lat'] as num?)?.toDouble() ?? 0,
      lng: (raw['lng'] as num?)?.toDouble() ?? 0,
    );
    if (result.address.isEmpty) return;

    _handoffLat = result.lat;
    _handoffLng = result.lng;
    _handoffZoom = (raw['zoom'] as num?)?.toDouble();
    _handoffBearing = (raw['bearing'] as num?)?.toDouble();
    _handoffPitch = (raw['pitch'] as num?)?.toDouble();

    if (_editingDropoff) {
      setState(() {
        _dropoffDetails = result;
        _dropoffLabel = result.address;
        _dropoffCtrl.text = result.address;
      });
      if (_pickupDetails != null) _returnResults();
    } else {
      setState(() {
        _pickupDetails = result;
        _pickupLabel = result.address;
        _pickupCtrl.text = result.address;
      });
      if (_dropoffDetails != null) _returnResults();
    }
  }

  Future<void> _onSavedPlaceTap(String key) async {
    HapticFeedback.selectionClick();
    final fav = _findFavoriteByKey(key);
    if (fav == null || fav.address.isEmpty) {
      // Not saved yet — open map picker so the user can pick & save later
      await _openMapPicker();
      return;
    }
    final addr = fav.address;
    final lat = fav.lat ?? 0;
    final lng = fav.lng ?? 0;
    if (_editingDropoff) {
      setState(() {
        _dropoffDetails = PlaceDetails(address: addr, lat: lat, lng: lng);
        _dropoffLabel = addr;
        _dropoffCtrl.text = addr;
      });
      if (_pickupDetails != null) _returnResults();
    } else {
      setState(() {
        _pickupDetails = PlaceDetails(address: addr, lat: lat, lng: lng);
        _pickupLabel = addr;
        _pickupCtrl.text = addr;
      });
      if (_dropoffDetails != null) _returnResults();
    }
  }

  Future<void> _onRecentTap(String recent) async {
    HapticFeedback.selectionClick();
    if (_editingDropoff) {
      _dropoffCtrl.text = recent;
      _onTextChanged(recent);
      _dropoffFocus.requestFocus();
    } else {
      _pickupCtrl.text = recent;
      _onTextChanged(recent);
      _pickupFocus.requestFocus();
    }
  }

  Future<void> _returnResults() async {
    if (_dropoffDetails == null) {
      Navigator.of(context).pop();
      return;
    }

    PlaceDetails? effectivePickup = _pickupDetails;
    if (effectivePickup == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 3));
        effectivePickup = PlaceDetails(
          address:
              _pickupLabel.isNotEmpty ? _pickupLabel : 'Current location',
          lat: pos.latitude,
          lng: pos.longitude,
        );
      } catch (_) {
        if (widget.initialPickupLat != null &&
            widget.initialPickupLng != null) {
          effectivePickup = PlaceDetails(
            address:
                _pickupLabel.isNotEmpty ? _pickupLabel : 'Current location',
            lat: widget.initialPickupLat!,
            lng: widget.initialPickupLng!,
          );
        }
      }
    }

    final dropoff = _dropoffDetails!;
    final dropLabel =
        _dropoffLabel.isNotEmpty ? _dropoffLabel : dropoff.address;

    RouteResult? preloaded;
    if (effectivePickup != null) {
      try {
        preloaded = await DirectionsService(ApiKeys.webServices)
            .getRoute(
              origin: LatLng(effectivePickup.lat, effectivePickup.lng),
              destination: LatLng(dropoff.lat, dropoff.lng),
            )
            .timeout(const Duration(milliseconds: 200));
      } catch (_) {}
    }

    if (!mounted) return;

    // Hide the search chrome with a pure black layer so the user never
    // sees the list/cards peek through while the ride-request screen
    // fades in. The RideRequestScreen's own background is black too, so
    // the visible sequence becomes: map-picker (with pin) → black fade
    // → ride-request map (positioned at the same camera state).
    setState(() => _handoffCover = true);

    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        RideRequestScreen(
          initialPickupDetails: effectivePickup,
          initialDropoffDetails: dropoff,
          initialPickupLabel: _pickupLabel,
          initialDropoffLabel: dropLabel,
          initialDropoffAddress: dropLabel,
          preloadedRoute: preloaded,
          handoffLat: _handoffLat,
          handoffLng: _handoffLng,
          handoffZoom: _handoffZoom,
          handoffBearing: _handoffBearing,
          handoffPitch: _handoffPitch,
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════
  //  Build
  // ═════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                child: Column(
                  children: [
                    // ── Top row: back + fields + swap ──
                    _buildTopRow(),

                const SizedBox(height: 16),

                // ── Body: suggestions OR shortcuts (cross-fade) ──
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: const Cubic(0, 0, 0.2, 1),
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) {
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, -0.03),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      );
                    },
                    child: (_suggestions.isNotEmpty || _loading)
                        ? KeyedSubtree(
                            key: const ValueKey('suggestions'),
                            child: _buildSuggestionsList(),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('shortcuts'),
                            child: _buildShortcuts(),
                          ),
                  ),
                ),
              ],
                ),
              ),
            ),
            // Handoff cover — black opaque layer that hides search content
            // the instant we start pushing RideRequestScreen, so the
            // transition reads as a clean fade between two map views.
            IgnorePointer(
              ignoring: !_handoffCover,
              child: AnimatedOpacity(
                opacity: _handoffCover ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 120),
                child: Container(color: _bg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRow() {
    // Frosted-glass panel: blurred translucent black with a faint gold
    // tint on the border so it feels premium, not generic.
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            // Layered fill so the blur has something to carry; mostly
            // black so the frost still reads as dark.
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _gold.withValues(alpha: 0.14),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Back button
          _CircleBtn(
            icon: Icons.arrow_back_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),

          // Fields + connector line
          Expanded(
            child: Stack(
              children: [
                // Vertical gold→white gradient connector. Positioned so
                // its horizontal center lines up with the marker centers
                // (marker is 14×14, its center is at x=7; the line is 2px
                // wide, so left:6 puts its own center at x=7). Vertically
                // it starts at the pickup-dot center and ends at the
                // dropoff-marker center — each field adds ~4px top/bottom
                // padding around a 14×14 marker inside a ~34px tall row,
                // and there is a 12px gap between them, so the visual
                // centers sit about 17px below the top and 17px above
                // the bottom of the stack.
                Positioned(
                  left: 6,
                  top: 17,
                  bottom: 17,
                  child: Container(
                    width: 2,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [_gold, Colors.white],
                      ),
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.45),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),

                Column(
                  children: [
                    _buildField(
                      dot: const _Dot(pickup: true),
                      label: S.of(context).currentLocation,
                      controller: _pickupCtrl,
                      focusNode: _pickupFocus,
                      onTap: () => setState(() {
                        _editingPickup = true;
                        _editingDropoff = false;
                        _suggestions = [];
                      }),
                      onChanged: _editingPickup ? _onTextChanged : null,
                      onSubmitted: _editingPickup ? _onFieldSubmitted : null,
                      active: _editingPickup,
                      placeholderHint: S.of(context).enterPickupAddress,
                    ),
                    const SizedBox(height: 12),
                    _buildField(
                      dot: const _Dot(pickup: false),
                      label: S.of(context).whereTo,
                      controller: _dropoffCtrl,
                      focusNode: _dropoffFocus,
                      onTap: () => setState(() {
                        _editingPickup = false;
                        _editingDropoff = true;
                        _suggestions = [];
                      }),
                      onChanged: _editingDropoff ? _onTextChanged : null,
                      onSubmitted:
                          _editingDropoff ? _onFieldSubmitted : null,
                      active: _editingDropoff,
                      placeholderHint: S.of(context).whereTo,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Swap button
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _SwapButton(controller: _swapCtl, onTap: _swapFields),
          ),
        ],
      ),
        ),
      ),
    );
  }

  Widget _buildField({
    required Widget dot,
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onTap,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
    required bool active,
    required String placeholderHint,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          // Focus tint — matches .vipRide__locPicker__field:focus-within on the web
          color: active
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            dot,
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                onTap: onTap,
                cursorColor: _gold,
                textInputAction: TextInputAction.search,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: active ? _gold : Colors.white,
                  fontSize: 15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: placeholderHint,
                  hintStyle: TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShortcuts() {
    final s = S.of(context);
    final recents = _recents;

    return ListView(
      padding: const EdgeInsets.only(top: 2, bottom: 24),
      physics: const BouncingScrollPhysics(),
      children: [
        // ── "Choose on map" premium shortcut ──
        _ShortcutCard(
          icon: Icons.map_rounded,
          title: s.chooseOnMap,
          subtitle: s.dropPinAtExactSpot,
          onTap: _openMapPicker,
        ),

        const SizedBox(height: 22),

        // ── SAVED PLACES ──
        _sectionLabel(s.savedPlaces),
        const SizedBox(height: 10),
        Row(
          children: [
            _SavedChip(
              icon: Icons.home_rounded,
              label: s.home,
              onTap: () => _onSavedPlaceTap('home'),
            ),
            const SizedBox(width: 8),
            _SavedChip(
              icon: Icons.work_rounded,
              label: s.work,
              onTap: () => _onSavedPlaceTap('work'),
            ),
            const SizedBox(width: 8),
            _SavedChip(
              icon: Icons.flight_takeoff_rounded,
              label: s.airportLabel,
              onTap: () => _onSavedPlaceTap('airport'),
            ),
          ],
        ),

        // ── RECENT ──
        if (recents.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionLabel(s.recentLabel),
          const SizedBox(height: 4),
          ...recents.take(6).map(
                (r) => _RecentRow(
                  address: r,
                  onTap: () => _onRecentTap(r),
                ),
              ),
        ],
      ],
    );
  }

  Widget _buildSuggestionsList() {
    if (_loading && _suggestions.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: _suggestions.length,
      physics: const BouncingScrollPhysics(),
      itemBuilder: (_, i) {
        final s = _suggestions[i];
        return _SuggestionRow(
          key: ValueKey('sug_${s.placeId}'),
          suggestion: s,
          staggerIndex: i,
          onTap: () => _onSuggestionTap(s),
        );
      },
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: _gold.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Building blocks
// ═══════════════════════════════════════════════════════════════════

class _Dot extends StatelessWidget {
  final bool pickup;
  const _Dot({required this.pickup});

  @override
  Widget build(BuildContext context) {
    // Both figures are 14×14 so their visual centers line up with the
    // vertical gold connector (its x position is tuned to 6px from the
    // left of the column, matching the 7px half-width of the marker).
    if (pickup) {
      return Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _gold,
          boxShadow: [
            BoxShadow(
              color: _gold.withValues(alpha: 0.6),
              blurRadius: 10,
            ),
          ],
        ),
      );
    }
    // Drop-off: white rounded square, also 14×14 so the vertical line
    // lands exactly on its visual center.
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(3),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.30),
            blurRadius: 8,
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _SwapButton extends StatelessWidget {
  final AnimationController controller;
  final VoidCallback onTap;
  const _SwapButton({required this.controller, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          return Transform.rotate(
            angle: controller.value * 3.14159,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0x1FE8C547),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x4DE8C547)),
              ),
              child: const Icon(Icons.swap_vert_rounded,
                  color: _gold, size: 18),
            ),
          );
        },
      ),
    );
  }
}

class _ShortcutCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ShortcutCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_ShortcutCard> createState() => _ShortcutCardState();
}

class _ShortcutCardState extends State<_ShortcutCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _pressed
                  ? [const Color(0x26E8C547), const Color(0x0DFFFFFF)]
                  : [const Color(0x14E8C547), const Color(0x05FFFFFF)],
            ),
            border: Border.all(
              color: _pressed
                  ? const Color(0x80E8C547)
                  : const Color(0x40E8C547),
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0x1FE8C547),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x4DE8C547)),
                ),
                child: Icon(widget.icon, color: _gold, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: Colors.white.withValues(alpha: 0.55),
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SavedChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_SavedChip> createState() => _SavedChipState();
}

class _SavedChipState extends State<_SavedChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _pressed
                ? const Color(0x1FE8C547)
                : Colors.white.withValues(alpha: 0.06),
            border: Border.all(
              color: _pressed
                  ? const Color(0x66E8C547)
                  : Colors.white.withValues(alpha: 0.08),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: _gold, size: 14),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  final String address;
  final VoidCallback onTap;
  const _RecentRow({required this.address, required this.onTap});

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: _pressed
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: Icon(
                Icons.schedule_rounded,
                color: Colors.white.withValues(alpha: 0.55),
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatefulWidget {
  final PlaceSuggestion suggestion;
  final int staggerIndex;
  final VoidCallback onTap;
  const _SuggestionRow({
    super.key,
    required this.suggestion,
    required this.staggerIndex,
    required this.onTap,
  });

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _entryCtl;

  @override
  void initState() {
    super.initState();
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    // Stagger: first 5 rows cascade at 45ms each; later rows show instantly.
    final delay = widget.staggerIndex < 5
        ? Duration(milliseconds: 30 + 45 * widget.staggerIndex)
        : Duration.zero;
    Future.delayed(delay, () {
      if (mounted) _entryCtl.forward();
    });
  }

  @override
  void dispose() {
    _entryCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desc = widget.suggestion.description;
    final comma = desc.indexOf(',');
    final primary = comma > 0 ? desc.substring(0, comma) : desc;
    final secondary = comma > 0 ? desc.substring(comma + 1).trim() : '';

    return AnimatedBuilder(
      animation: _entryCtl,
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_entryCtl.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - t)),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.only(
            // Press slides content 4px right (matches web's padding-left shift)
            left: _pressed ? 16 : 12,
            right: 12,
            top: 14,
            bottom: 14,
          ),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: _pressed
                ? const Color(0x23D4AF37)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            // Left-border gold accent on press (matches web border-left-color).
            border: Border(
              left: BorderSide(
                color: _pressed ? _gold : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x1FE8C547),
                ),
                child: const Icon(Icons.place_rounded, color: _gold, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      primary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (secondary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
