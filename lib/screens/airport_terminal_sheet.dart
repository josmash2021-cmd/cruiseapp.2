import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

/// Airport data model
class AirportInfo {
  final String code;
  final String name;
  final List<String> terminals;
  final List<String> pickupZones;
  final double? flatRateSurcharge;

  const AirportInfo({
    required this.code,
    required this.name,
    required this.terminals,
    required this.pickupZones,
    this.flatRateSurcharge,
  });
}

/// Result from airport terminal selection
class AirportSelection {
  final AirportInfo airport;
  final String? terminal;
  final String? pickupZone;
  final String? flightNumber;

  const AirportSelection({
    required this.airport,
    this.terminal,
    this.pickupZone,
    this.flightNumber,
  });
}

/// Common US airports
const List<AirportInfo> _commonAirports = [
  AirportInfo(
    code: 'MIA',
    name: 'Miami International Airport',
    terminals: ['Terminal N', 'Terminal S', 'Central Terminal'],
    pickupZones: [
      'Arrivals Level 1 - Door 1',
      'Arrivals Level 1 - Door 5',
      'Arrivals Level 1 - Door 9',
    ],
    flatRateSurcharge: 5.0,
  ),
  AirportInfo(
    code: 'FLL',
    name: 'Fort Lauderdale-Hollywood Intl',
    terminals: ['Terminal 1', 'Terminal 2', 'Terminal 3', 'Terminal 4'],
    pickupZones: ['Ground Level - Rideshare Zone', 'Arrivals - Door 1'],
    flatRateSurcharge: 5.0,
  ),
  AirportInfo(
    code: 'JFK',
    name: 'John F. Kennedy International',
    terminals: [
      'Terminal 1',
      'Terminal 2',
      'Terminal 4',
      'Terminal 5',
      'Terminal 7',
      'Terminal 8',
    ],
    pickupZones: ['Arrivals - Rideshare Pickup', 'Terminal Curbside'],
    flatRateSurcharge: 8.0,
  ),
  AirportInfo(
    code: 'LAX',
    name: 'Los Angeles International',
    terminals: [
      'Terminal 1',
      'Terminal 2',
      'Terminal 3',
      'Terminal 4',
      'Terminal 5',
      'Terminal 6',
      'Terminal 7',
      'Tom Bradley Intl',
    ],
    pickupZones: ['LAX-it Rideshare Lot'],
    flatRateSurcharge: 6.0,
  ),
  AirportInfo(
    code: 'ORD',
    name: "Chicago O'Hare International",
    terminals: ['Terminal 1', 'Terminal 2', 'Terminal 3', 'Terminal 5'],
    pickupZones: ['Rideshare Pickup - Lower Level'],
    flatRateSurcharge: 5.0,
  ),
  AirportInfo(
    code: 'ATL',
    name: 'Hartsfield-Jackson Atlanta Intl',
    terminals: [
      'Domestic Terminal N',
      'Domestic Terminal S',
      'International Terminal',
    ],
    pickupZones: ['Ground Transportation - Rideshare'],
    flatRateSurcharge: 5.0,
  ),
  AirportInfo(
    code: 'SFO',
    name: 'San Francisco International',
    terminals: [
      'Terminal 1',
      'Terminal 2',
      'Terminal 3',
      'International Terminal',
    ],
    pickupZones: [
      'Domestic Parking Garage Level 5',
      'International Terminal G',
    ],
    flatRateSurcharge: 6.0,
  ),
  AirportInfo(
    code: 'DFW',
    name: 'Dallas/Fort Worth International',
    terminals: [
      'Terminal A',
      'Terminal B',
      'Terminal C',
      'Terminal D',
      'Terminal E',
    ],
    pickupZones: ['Rideshare Zone - Lower Level'],
    flatRateSurcharge: 5.0,
  ),
];

/// Premium airport terminal selector bottom sheet.
/// Returns an [AirportSelection] with the chosen airport, terminal, pickup zone, and flight number.
class AirportTerminalSheet extends StatefulWidget {
  final bool isDark;
  const AirportTerminalSheet({super.key, required this.isDark});

  @override
  State<AirportTerminalSheet> createState() => _AirportTerminalSheetState();
}

class _AirportTerminalSheetState extends State<AirportTerminalSheet>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _airportBlue = Color(0xFF4285F4);

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeOut;
  late final Animation<double> _fadeIn;

  // Steps: 0 = select airport, 1 = select terminal, 2 = confirm details
  int _step = 0;
  AirportInfo? _selectedAirport;
  String? _selectedTerminal;
  String? _selectedPickupZone;
  final _flightCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Google Places airport autocomplete
  List<_AirportSuggestion> _suggestions = [];
  bool _loadingSuggestions = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _animCtrl,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );
    _fadeIn = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _flightCtrl.dispose();
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Color get _bg => widget.isDark ? const Color(0xFF111318) : Colors.white;
  Color get _surface =>
      widget.isDark ? const Color(0xFF1A1D24) : const Color(0xFFF5F5F5);
  Color get _textPrimary =>
      widget.isDark ? Colors.white : const Color(0xFF1A1D24);
  Color get _textSecondary =>
      widget.isDark ? Colors.white54 : const Color(0xFF6B7280);
  Color get _border => widget.isDark ? Colors.white10 : Colors.black12;

  void _selectAirport(AirportInfo airport) {
    setState(() {
      _selectedAirport = airport;
      _selectedTerminal = airport.terminals.isNotEmpty
          ? airport.terminals.first
          : null;
      _selectedPickupZone = airport.pickupZones.isNotEmpty
          ? airport.pickupZones.first
          : null;
      _suggestions = [];
      _step = 1;
    });
    _animCtrl.forward(from: 0);
  }

  void _onSearchChanged(String q) {
    setState(() => _searchQuery = q);
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _loadingSuggestions = false;
      });
      return;
    }
    // Check local list first — only call API when needed
    final localHits = _commonAirports
        .where(
          (a) =>
              a.code.toLowerCase().contains(q.toLowerCase()) ||
              a.name.toLowerCase().contains(q.toLowerCase()),
        )
        .toList();
    if (localHits.isNotEmpty) {
      setState(() => _suggestions = []);
    }
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _fetchAirportSuggestions(q),
    );
  }

  Future<void> _fetchAirportSuggestions(String q) async {
    setState(() => _loadingSuggestions = true);
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        {
          'input': q,
          'types': 'airport',
          'key': ApiKeys.webServices,
          'language': 'en',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final predictions = data['predictions'] as List? ?? [];
        // Filter out airports already in local list
        final localCodes = _commonAirports.map((a) => a.code).toSet();
        final suggestions = <_AirportSuggestion>[];
        for (final p in predictions) {
          final desc = p['description'] as String? ?? '';
          final placeId = p['place_id'] as String? ?? '';
          // Extract IATA code from description (e.g. "Birmingham–Shuttlesworth (BHM)")
          final codeMatch = RegExp(r'\b([A-Z]{3})\b').allMatches(desc);
          final code = codeMatch.isNotEmpty ? codeMatch.last.group(0)! : '';
          if (localCodes.contains(code)) continue;
          suggestions.add(
            _AirportSuggestion(description: desc, placeId: placeId, code: code),
          );
        }
        if (mounted) {
          setState(() {
            _suggestions = suggestions;
            _loadingSuggestions = false;
          });
        }
      } else {
        if (mounted) {
          setState(() => _loadingSuggestions = false);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSuggestions = false);
    }
  }

  /// When user picks a Google Places airport result, create a minimal AirportInfo
  void _selectSuggestion(_AirportSuggestion s) {
    final airport = AirportInfo(
      code: s.code.isNotEmpty ? s.code : '???',
      name: s.description,
      terminals: [S.of(context).mainTerminal],
      pickupZones: [S.of(context).arrivalsRidesharePickup],
      flatRateSurcharge: null,
    );
    _selectAirport(airport);
  }

  void _goBack() {
    if (_step == 1) {
      setState(() => _step = 0);
      _animCtrl.reverse(from: 1);
    } else if (_step == 2) {
      setState(() => _step = 1);
      _animCtrl.reverse(from: 1);
    }
  }

  void _goToConfirm() {
    setState(() => _step = 2);
    _animCtrl.forward(from: 0);
  }

  void _confirm() {
    Navigator.of(context).pop(
      AirportSelection(
        airport: _selectedAirport!,
        terminal: _selectedTerminal,
        pickupZone: _selectedPickupZone,
        flightNumber: _flightCtrl.text.trim().isNotEmpty
            ? _flightCtrl.text.trim()
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  if (_step > 0)
                    GestureDetector(
                      onTap: _goBack,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.arrow_back_ios_rounded,
                          color: _airportBlue,
                          size: 20,
                        ),
                      ),
                    ),
                  Icon(
                    Icons.flight_takeoff_rounded,
                    color: _airportBlue,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _step == 0
                          ? S.of(context).selectAirport
                          : _step == 1
                          ? S.of(context).selectTerminal
                          : S.of(context).confirmDetails,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (_selectedAirport != null && _step > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _airportBlue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _selectedAirport!.code,
                        style: const TextStyle(
                          color: _airportBlue,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Content
            Flexible(
              child: _step == 0
                  ? _buildAirportList()
                  : _step == 1
                  ? _buildTerminalSelector()
                  : _buildConfirmDetails(),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 0: Airport List ──
  Widget _buildAirportList() {
    final filtered = _searchQuery.isEmpty
        ? _commonAirports
        : _commonAirports
              .where(
                (a) =>
                    a.code.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                    a.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();

    return Column(
      children: [
        // Search
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border),
            ),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              style: TextStyle(color: _textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: S.of(context).searchAnyAirport,
                hintStyle: TextStyle(color: _textSecondary),
                icon: Icon(
                  Icons.search_rounded,
                  color: _textSecondary,
                  size: 20,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                          _onSearchChanged('');
                        },
                        child: Icon(
                          Icons.close_rounded,
                          color: _textSecondary,
                          size: 18,
                        ),
                      )
                    : null,
                border: InputBorder.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Results list
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              // Local matches
              if (filtered.isNotEmpty)
                ...filtered.map((a) => _buildLocalAirportTile(a)),

              // Separator when showing Google results
              if (_suggestions.isNotEmpty && filtered.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Divider(color: _border, height: 1)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          S.of(context).moreAirports,
                          style: TextStyle(
                            color: _textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: _border, height: 1)),
                    ],
                  ),
                ),

              // Google Places suggestions
              if (_suggestions.isNotEmpty)
                ..._suggestions.map(
                  (s) => GestureDetector(
                    onTap: () => _selectSuggestion(s),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF4285F4,
                              ).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: s.code.isNotEmpty
                                  ? Text(
                                      s.code,
                                      style: const TextStyle(
                                        color: Color(0xFF4285F4),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.flight_rounded,
                                      color: Color(0xFF4285F4),
                                      size: 20,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              s.description,
                              style: TextStyle(
                                color: _textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: _textSecondary,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Loading indicator
              if (_loadingSuggestions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: const Color(0xFF4285F4).withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),

              // Empty state
              if (!_loadingSuggestions &&
                  _suggestions.isEmpty &&
                  filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Column(
                    children: [
                      Icon(
                        Icons.search_off_rounded,
                        color: _textSecondary,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        S.of(context).noAirportsFound,
                        style: TextStyle(color: _textSecondary, fontSize: 14),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLocalAirportTile(AirportInfo a) {
    return GestureDetector(
      onTap: () => _selectAirport(a),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _airportBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(
                  a.code,
                  style: const TextStyle(
                    color: _airportBlue,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.name,
                    style: TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    S.of(context).terminalsCount(a.terminals.length),
                    style: TextStyle(color: _textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (a.flatRateSurcharge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '+\$${a.flatRateSurcharge!.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Step 1: Terminal Selector ──
  Widget _buildTerminalSelector() {
    if (_selectedAirport == null) return const SizedBox.shrink();
    final ap = _selectedAirport!;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Airport badge
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _airportBlue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _airportBlue.withValues(alpha: 0.15)),
            ),
            child: Row(
              children: [
                Icon(Icons.flight_rounded, color: _airportBlue, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ap.name,
                    style: TextStyle(
                      color: _textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Terminal selection
          Text(
            S.of(context).terminalLabel,
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ap.terminals.map((t) {
              final selected = _selectedTerminal == t;
              return GestureDetector(
                onTap: () => setState(() => _selectedTerminal = t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? _airportBlue.withValues(alpha: 0.15)
                        : _surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? _airportBlue : _border,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    t,
                    style: TextStyle(
                      color: selected ? _airportBlue : _textPrimary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          // Pickup zone
          Text(
            S.of(context).pickupZone,
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          ...ap.pickupZones.map((z) {
            final selected = _selectedPickupZone == z;
            return GestureDetector(
              onTap: () => setState(() => _selectedPickupZone = z),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: selected ? _gold.withValues(alpha: 0.08) : _surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected ? _gold.withValues(alpha: 0.4) : _border,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.pin_drop_rounded,
                      color: selected ? _gold : _textSecondary,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        z,
                        style: TextStyle(
                          color: selected ? _gold : _textPrimary,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (selected)
                      const Icon(
                        Icons.check_circle_rounded,
                        color: _gold,
                        size: 20,
                      ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 20),

          // Continue button
          GestureDetector(
            onTap: _goToConfirm,
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_airportBlue, Color(0xFF5A9CF5)],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _airportBlue.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      S.of(context).continueButton,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
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

  // ── Step 2: Confirm Details ──
  Widget _buildConfirmDetails() {
    if (_selectedAirport == null) return const SizedBox.shrink();
    final ap = _selectedAirport!;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _airportBlue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _airportBlue.withValues(alpha: 0.15)),
            ),
            child: Column(
              children: [
                _summaryRow(
                  Icons.flight_rounded,
                  S.of(context).airport,
                  '${ap.code} — ${ap.name}',
                ),
                const SizedBox(height: 10),
                if (_selectedTerminal != null)
                  _summaryRow(
                    Icons.door_front_door_outlined,
                    S.of(context).terminalLabel,
                    _selectedTerminal!,
                  ),
                if (_selectedTerminal != null) const SizedBox(height: 10),
                if (_selectedPickupZone != null)
                  _summaryRow(
                    Icons.pin_drop_rounded,
                    S.of(context).pickupLabel,
                    _selectedPickupZone!,
                  ),
                if (ap.flatRateSurcharge != null) ...[
                  const SizedBox(height: 10),
                  _summaryRow(
                    Icons.attach_money_rounded,
                    S.of(context).airportSurchargeLabel,
                    '+\$${ap.flatRateSurcharge!.toStringAsFixed(2)}',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Flight number (optional)
          Text(
            S.of(context).flightNumberOptional,
            style: TextStyle(
              color: _textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border),
            ),
            child: TextField(
              controller: _flightCtrl,
              style: TextStyle(color: _textPrimary, fontSize: 15),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: S.of(context).flightNumberHint,
                hintStyle: TextStyle(color: _textSecondary),
                icon: Icon(
                  Icons.airplane_ticket_outlined,
                  color: _airportBlue,
                  size: 20,
                ),
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            S.of(context).flightTrackingNote,
            style: TextStyle(color: _textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 24),

          // Confirm button
          GestureDetector(
            onTap: _confirm,
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_gold, _goldLight]),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_rounded, color: Colors.black87, size: 20),
                    SizedBox(width: 8),
                    Text(
                      S.of(context).confirmAirportDetails,
                      style: TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
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

  Widget _summaryRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: _airportBlue, size: 18),
        const SizedBox(width: 10),
        Text('$label: ', style: TextStyle(color: _textSecondary, fontSize: 13)),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: _textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Internal model for a Google Places airport autocomplete suggestion.
class _AirportSuggestion {
  final String description;
  final String placeId;
  final String code;
  const _AirportSuggestion({
    required this.description,
    required this.placeId,
    required this.code,
  });
}
