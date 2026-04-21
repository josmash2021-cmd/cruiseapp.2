import 'dart:async';

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
const _goldLight = Color(0xFFFBE47A);
const _bg = Color(0xFF0A0E1A);
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

    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        RideRequestScreen(
          initialPickupDetails: effectivePickup,
          initialDropoffDetails: dropoff,
          initialPickupLabel: _pickupLabel,
          initialDropoffLabel: dropLabel,
          initialDropoffAddress: dropLabel,
          preloadedRoute: preloaded,
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
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Column(
              children: [
                // ── Top row: back + fields + swap ──
                _buildTopRow(),

                const SizedBox(height: 16),

                // ── Body: suggestions OR shortcuts ──
                Expanded(
                  child: _suggestions.isNotEmpty || _loading
                      ? _buildSuggestionsList()
                      : _buildShortcuts(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
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
                // Vertical gold gradient connector
                Positioned(
                  left: 6,
                  top: 22,
                  bottom: 22,
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
          suggestion: s,
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
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pickup ? _gold : Colors.white.withValues(alpha: 0.35),
        boxShadow: pickup
            ? [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.6),
                  blurRadius: 10,
                ),
              ]
            : null,
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
  final VoidCallback onTap;
  const _SuggestionRow({required this.suggestion, required this.onTap});

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final desc = widget.suggestion.description;
    final comma = desc.indexOf(',');
    final primary = comma > 0 ? desc.substring(0, comma) : desc;
    final secondary = comma > 0 ? desc.substring(comma + 1).trim() : '';

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: _pressed
              ? const Color(0x14E8C547)
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
                color: const Color(0x1FE8C547),
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
    );
  }
}
