import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../l10n/app_localizations.dart';

import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import 'map_picker_screen.dart';

/// Uber-like pickup / dropoff search screen.
///
/// Returns a `Map<String, dynamic>` with keys:
///  - `pickup`: [PlaceDetails]
///  - `dropoff`: [PlaceDetails]
///  - `pickupLabel`: [String]
///  - `dropoffLabel`: [String]
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

class _PickupDropoffSearchScreenState extends State<PickupDropoffSearchScreen> {
  final _placesService = PlacesService(ApiKeys.webServices);

  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();

  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;
  Timer? _debounce;

  // Which field is active
  bool _editingPickup = false;
  bool _editingDropoff = true;

  PlaceDetails? _pickupDetails;
  PlaceDetails? _dropoffDetails;
  String _pickupLabel = '';
  String _dropoffLabel = '';

  @override
  void initState() {
    super.initState();
    _pickupCtrl.text = widget.initialPickupText;
    _pickupLabel = widget.initialPickupText;

    if (widget.initialPickupLat != null && widget.initialPickupLng != null) {
      _pickupDetails = PlaceDetails(
        address: widget.initialPickupText,
        lat: widget.initialPickupLat!,
        lng: widget.initialPickupLng!,
      );
    }

    // Auto-focus dropoff
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dropoffFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _search(text.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final results = await _placesService.autocomplete(
        query,
        latitude: widget.initialPickupLat,
        longitude: widget.initialPickupLng,
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

      // If pickup is also set, return results
      if (_pickupDetails != null) {
        _returnResults();
      } else {
        // Switch to pickup field
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

      // If dropoff is also set, return results
      if (_dropoffDetails != null) {
        _returnResults();
      } else {
        // Switch to dropoff field
        setState(() {
          _editingPickup = false;
          _editingDropoff = true;
        });
        _dropoffFocus.requestFocus();
      }
    }
  }

  void _returnResults() {
    Navigator.of(context).pop({
      'pickup': _pickupDetails,
      'dropoff': _dropoffDetails,
      'pickupLabel': _pickupLabel,
      'dropoffLabel': _dropoffLabel,
    });
  }

  /// Called when user presses Enter/Done without selecting a suggestion.
  /// Auto-searches and picks the best matching result.
  Future<void> _onFieldSubmitted(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;

    setState(() => _loading = true);

    try {
      // First try autocomplete to get the best match
      final results = await _placesService.autocomplete(
        query,
        latitude: widget.initialPickupLat,
        longitude: widget.initialPickupLng,
      );

      if (results.isNotEmpty && mounted) {
        // Auto-select the first (best) result
        await _onSuggestionTap(results.first);
        return;
      }

      // Fallback: direct geocode if autocomplete returned nothing
      final exact = await _placesService.geocodeAddress(
        query,
        latitude: widget.initialPickupLat,
        longitude: widget.initialPickupLng,
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = c.isDark;
    final topPad = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: c.bg,
        body: Column(
          children: [
            // ── Header with fields ──
            Container(
              padding: EdgeInsets.only(
                top: topPad + 8,
                left: 16,
                right: 16,
                bottom: 16,
              ),
              decoration: BoxDecoration(
                color: c.panel,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Back + fields row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Back button
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 40,
                          height: 40,
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.surface,
                          ),
                          child: Icon(
                            Icons.arrow_back,
                            size: 20,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Dots column
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                            Container(
                              width: 1.5,
                              height: 28,
                              color: c.textTertiary,
                            ),
                            Icon(Icons.square, size: 8, color: c.gold),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Text fields
                      Expanded(
                        child: Column(
                          children: [
                            _searchField(
                              controller: _pickupCtrl,
                              focusNode: _pickupFocus,
                              hint: S.of(context).pickupLocation,
                              c: c,
                              textInputAction: TextInputAction.next,
                              onTap: () {
                                setState(() {
                                  _editingPickup = true;
                                  _editingDropoff = false;
                                });
                              },
                              onChanged: _onTextChanged,
                              onSubmitted: (value) {
                                if (value.trim().isNotEmpty) {
                                  _onFieldSubmitted(value);
                                } else {
                                  _dropoffFocus.requestFocus();
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                            _searchField(
                              controller: _dropoffCtrl,
                              focusNode: _dropoffFocus,
                              hint: S.of(context).whereTo,
                              c: c,
                              textInputAction: TextInputAction.done,
                              onTap: () {
                                setState(() {
                                  _editingPickup = false;
                                  _editingDropoff = true;
                                });
                              },
                              onChanged: _onTextChanged,
                              onSubmitted: _onFieldSubmitted,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Loading bar ──
            if (_loading)
              LinearProgressIndicator(
                backgroundColor: c.border,
                valueColor: AlwaysStoppedAnimation(c.gold),
                minHeight: 2,
              ),

            // ── Suggestions list ──
            Expanded(
              child: _suggestions.isEmpty
                  ? _buildRecentPlaces(c)
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: _suggestions.length,
                      itemBuilder: (context, idx) {
                        final s = _suggestions[idx];
                        return _buildSuggestionTile(c, s);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required AppColors c,
    required VoidCallback onTap,
    required ValueChanged<String> onChanged,
    ValueChanged<String>? onSubmitted,
    TextInputAction textInputAction = TextInputAction.done,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border, width: 1),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onTap: onTap,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textInputAction: textInputAction,
          style: TextStyle(
            fontSize: 15,
            color: c.textPrimary,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 15,
              color: c.textTertiary,
              fontWeight: FontWeight.w400,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: InputBorder.none,
            suffixIcon: controller.text.isNotEmpty
                ? GestureDetector(
                    onTap: () {
                      controller.clear();
                      setState(() => _suggestions = []);
                    },
                    child: Icon(Icons.close, size: 18, color: c.textTertiary),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionTile(AppColors c, PlaceSuggestion s) {
    return InkWell(
      onTap: () => _onSuggestionTap(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border, width: 1)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.location_on_rounded,
                size: 18,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                s.description,
                style: TextStyle(
                  fontSize: 15,
                  color: c.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onQuickPlaceTap(
    _QuickPlace item,
    FavoritePlace? homeAddr,
    FavoritePlace? workAddr,
  ) async {
    // ── Choose on map ──
    if (item.title == 'Choose on map') {
      final result = await Navigator.of(context).push<Map<String, dynamic>>(
        slideFromRightRoute(
          MapPickerScreen(
            initialLat: widget.initialPickupLat,
            initialLng: widget.initialPickupLng,
          ),
        ),
      );
      if (result == null || !mounted) return;
      final addr = result['address'] as String;
      final lat = result['lat'] as double;
      final lng = result['lng'] as double;
      setState(() {
        _dropoffDetails = PlaceDetails(address: addr, lat: lat, lng: lng);
        _dropoffLabel = addr;
        _dropoffCtrl.text = addr;
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
      return;
    }

    // ── Home or Work ──
    final savedAddress = item.title == 'Home'
        ? homeAddr?.address
        : workAddr?.address;

    // If address already saved → geocode and use as dropoff
    if (savedAddress != null && savedAddress.isNotEmpty) {
      await _useAddressAsDropoff(savedAddress);
      return;
    }

    // No saved address → open Google Places autocomplete to save one
    final pickedAddress = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlacesAutocompleteSheet(
        title: S.of(context).setAddressFor(item.title),
        hint: S.of(context).searchAddressFor(item.title.toLowerCase()),
        initialLat: widget.initialPickupLat,
        initialLng: widget.initialPickupLng,
      ),
    );
    if (pickedAddress == null || pickedAddress.isEmpty || !mounted) return;

    // Save the address as a favorite
    await LocalDataService.saveFavorite(
      FavoritePlace(label: item.title, address: pickedAddress),
    );

    // Now use it as dropoff
    await _useAddressAsDropoff(pickedAddress);
  }

  Future<void> _useAddressAsDropoff(String address) async {
    try {
      final details = await _placesService.geocodeAddress(
        address,
        latitude: widget.initialPickupLat,
        longitude: widget.initialPickupLng,
      );
      if (details != null && mounted) {
        setState(() {
          _dropoffDetails = details;
          _dropoffLabel = address;
          _dropoffCtrl.text = address;
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
      }
    } catch (_) {}
  }

  Widget _buildRecentPlaces(AppColors c) {
    // Show some quick access items
    final quickItems = [
      _QuickPlace(
        Icons.home_rounded,
        S.of(context).homeLabel,
        S.of(context).setHomeAddress,
      ),
      _QuickPlace(
        Icons.work_rounded,
        S.of(context).workLabel,
        S.of(context).setWorkAddress,
      ),
      _QuickPlace(
        Icons.map_rounded,
        S.of(context).chooseOnMap,
        S.of(context).pickLocationOnMap,
      ),
    ];

    return FutureBuilder<List<FavoritePlace>>(
      future: LocalDataService.getFavorites(),
      builder: (context, snapshot) {
        final favorites = snapshot.data ?? [];
        final homeAddr = favorites
            .where((f) => f.label.toLowerCase() == 'home')
            .firstOrNull;
        final workAddr = favorites
            .where((f) => f.label.toLowerCase() == 'work')
            .firstOrNull;

        // Update subtitles if addresses are saved
        if (homeAddr != null)
          quickItems[0] = _QuickPlace(
            Icons.home_rounded,
            'Home',
            homeAddr.address,
          );
        if (workAddr != null)
          quickItems[1] = _QuickPlace(
            Icons.work_rounded,
            'Work',
            workAddr.address,
          );

        return ListView(
          padding: const EdgeInsets.only(top: 8),
          children: [
            for (final item in quickItems)
              ListTile(
                onTap: () => _onQuickPlaceTap(item, homeAddr, workAddr),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(item.icon, size: 20, color: c.textSecondary),
                ),
                title: Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                subtitle: Text(
                  item.subtitle,
                  style: TextStyle(fontSize: 13, color: c.textTertiary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 2,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _QuickPlace {
  final IconData icon;
  final String title;
  final String subtitle;
  const _QuickPlace(this.icon, this.title, this.subtitle);
}

// ─── Google Places Autocomplete Bottom Sheet ─────────────────────────
class _PlacesAutocompleteSheet extends StatefulWidget {
  final String title;
  final String hint;
  final double? initialLat;
  final double? initialLng;

  const _PlacesAutocompleteSheet({
    required this.title,
    required this.hint,
    this.initialLat,
    this.initialLng,
  });

  @override
  State<_PlacesAutocompleteSheet> createState() =>
      _PlacesAutocompleteSheetState();
}

class _PlacesAutocompleteSheetState extends State<_PlacesAutocompleteSheet> {
  final _controller = TextEditingController();
  final _places = PlacesService(ApiKeys.webServices);
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await _places.autocomplete(
          query,
          latitude: widget.initialLat,
          longitude: widget.initialLng,
        );
        if (mounted)
          setState(() {
            _suggestions = results;
            _loading = false;
          });
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: TextStyle(color: c.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: c.textTertiary,
                    size: 22,
                  ),
                  suffixIcon: _controller.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _controller.clear();
                            setState(() {
                              _suggestions = [];
                              _loading = false;
                            });
                          },
                          child: Icon(
                            Icons.close_rounded,
                            color: c.textTertiary,
                            size: 20,
                          ),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFFE8C547),
                ),
              ),
            ),
          // Suggestions
          Expanded(
            child: _suggestions.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.place_outlined,
                          color: c.textTertiary,
                          size: 48,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _controller.text.isEmpty
                              ? S.of(context).typeToSearchAddress
                              : S.of(context).noResultsFound,
                          style: TextStyle(color: c.textTertiary, fontSize: 14),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, bottomInset + 20),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, i) =>
                        Divider(color: c.divider, height: 1, indent: 52),
                    itemBuilder: (context, index) {
                      final s = _suggestions[index];
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.border),
                          ),
                          child: Icon(
                            Icons.location_on_rounded,
                            color: c.textSecondary,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          s.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onTap: () => Navigator.of(context).pop(s.description),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
