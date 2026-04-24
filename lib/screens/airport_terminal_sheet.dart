import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/api_keys.dart';
import '../data/airport_data.dart';
import '../l10n/app_localizations.dart';
import '../models/airport_models.dart';

export '../models/airport_models.dart';

/// Premium airport ride selector — 4-step bottom sheet.
/// Returns an [AirportSelection] on confirm, or null if dismissed.
///
/// Step 0: Direction (to / from airport)
/// Step 1: Select airport
/// Step 2a (toAirport):   Select airline → terminal auto-resolved
/// Step 2b (fromAirport): Select terminal → select arrival door
/// Step 3: Flight number + confirm
class AirportTerminalSheet extends StatefulWidget {
  final bool isDark;
  const AirportTerminalSheet({super.key, required this.isDark});

  @override
  State<AirportTerminalSheet> createState() => _AirportTerminalSheetState();
}

class _AirportTerminalSheetState extends State<AirportTerminalSheet>
    with SingleTickerProviderStateMixin {
  // ── colours ── (direct port of vip-apt-sheet.css:8-26 tokens)
  static const _gold      = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _blue      = Color(0xFF4285F4);
  static const _green     = Color(0xFF34A853);
  static const _red       = Color(0xFFEF4444);

  // ── animation ──
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeOut;
  late final Animation<double> _fadeIn;

  // ── state ──
  int _step = 0; // 0=direction 1=airport 2=details 3=confirm

  AirportDirection? _direction;
  AirportInfo?      _selectedAirport;
  AirportTerminal?  _selectedTerminal;
  String?           _selectedAirline;
  String?           _selectedArrivalDoor;

  final _flightCtrl  = TextEditingController();
  final _searchCtrl  = TextEditingController();
  String _searchQuery = '';
  bool   _flightError = false;

  // ── Google Places fallback ──
  List<_AirportSuggestion> _suggestions = [];
  bool _loadingSuggestions = false;
  Timer? _debounce;

  // ─────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    // Step-transition controller — drives the per-step fade out/in.
    //   STEP_OUT_MS = 120ms  (vip-apt-sheet.js:21)
    //   STEP_IN_MS  = 180ms  (vip-apt-sheet.js:22)
    //   total 300ms; the web stacks them so 0→.4 is "out", .4→1 is "in".
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
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

  // ─────────────────────────────────────────────
  //  Theme helpers
  // ─────────────────────────────────────────────
  Color get _bg         => widget.isDark ? const Color(0xFF111318) : Colors.white;
  Color get _surface    => widget.isDark ? const Color(0xFF1A1D24) : const Color(0xFFF5F5F5);
  Color get _textPrimary   => widget.isDark ? Colors.white : const Color(0xFF1A1D24);
  Color get _textSecondary => widget.isDark ? Colors.white54 : const Color(0xFF6B7280);
  Color get _border     => widget.isDark ? Colors.white10 : Colors.black12;

  // ─────────────────────────────────────────────
  //  Navigation helpers
  // ─────────────────────────────────────────────
  void _advance() {
    setState(() => _step++);
    _animCtrl.forward(from: 0);
  }

  void _goBack() {
    if (_step == 0) {
      Navigator.of(context).pop();
      return;
    }
    if (_step == 2) {
      // back to airport list — reset selections
      _selectedAirline = null;
      _selectedArrivalDoor = null;
      _selectedTerminal = null;
    }
    if (_step == 3) {
      // back to details — keep selections
    }
    setState(() => _step--);
    _animCtrl.reverse(from: 1);
  }

  void _selectDirection(AirportDirection dir) {
    setState(() => _direction = dir);
    _advance();
  }

  void _selectAirport(AirportInfo airport) {
    setState(() {
      _selectedAirport = airport;
      _selectedTerminal = null;
      _selectedAirline = null;
      _selectedArrivalDoor = null;
      _suggestions = [];
    });
    _advance();
  }

  // Guard against rapid taps: ignore a second airline/door selection
  // while the first is still waiting for its 220ms advance delay. Without
  // this, two selections in a row would each call _advance() and skip a
  // step of the state machine.
  bool _advancePending = false;

  void _selectAirline(String airline) {
    if (_advancePending) return;
    final matches = _selectedAirport!.terminalsForAirline(airline);
    setState(() {
      _selectedAirline  = airline;
      _selectedTerminal = matches.isNotEmpty ? matches.first : null;
    });
    _advancePending = true;
    Future.delayed(const Duration(milliseconds: 220), () {
      _advancePending = false;
      if (mounted) _advance();
    });
  }

  void _selectArrivalDoor(String door) {
    if (_advancePending) return;
    setState(() => _selectedArrivalDoor = door);
    _advancePending = true;
    Future.delayed(const Duration(milliseconds: 220), () {
      _advancePending = false;
      if (mounted) _advance();
    });
  }

  void _confirm() {
    if (_direction == AirportDirection.fromAirport &&
        _flightCtrl.text.trim().isEmpty) {
      setState(() => _flightError = true);
      return;
    }
    Navigator.of(context).pop(
      AirportSelection(
        airport:     _selectedAirport!,
        direction:   _direction!,
        terminal:    _selectedTerminal,
        airline:     _selectedAirline,
        arrivalDoor: _selectedArrivalDoor,
        flightNumber: _flightCtrl.text.trim().isNotEmpty
            ? _flightCtrl.text.trim()
            : null,
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Google Places search
  // ─────────────────────────────────────────────
  void _onSearchChanged(String q) {
    setState(() => _searchQuery = q);
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() { _suggestions = []; _loadingSuggestions = false; });
      return;
    }
    // 120ms matches the web's vip-apt-sheet.js debounce so the list
    // refreshes the moment the user stops typing.
    _debounce = Timer(const Duration(milliseconds: 120), () => _fetchSuggestions(q));
  }

  Future<void> _fetchSuggestions(String q) async {
    setState(() => _loadingSuggestions = true);
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', {
        'input': q, 'types': 'airport', 'key': ApiKeys.webServices, 'language': 'en',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final predictions = data['predictions'] as List? ?? [];
        final localCodes = kCommonAirports.map((a) => a.code).toSet();
        final suggestions = <_AirportSuggestion>[];
        for (final p in predictions) {
          final desc    = p['description'] as String? ?? '';
          final placeId = p['place_id']   as String? ?? '';
          final codeM   = RegExp(r'\b([A-Z]{3})\b').allMatches(desc);
          final code    = codeM.isNotEmpty ? codeM.last.group(0)! : '';
          if (localCodes.contains(code)) continue;
          suggestions.add(_AirportSuggestion(description: desc, placeId: placeId, code: code));
        }
        if (mounted) setState(() { _suggestions = suggestions; _loadingSuggestions = false; });
      } else {
        if (mounted) setState(() => _loadingSuggestions = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSuggestions = false);
    }
  }

  void _selectSuggestion(_AirportSuggestion s) {
    // Build a minimal AirportInfo for airports not in the local list
    final airport = AirportInfo(
      code: s.code.isNotEmpty ? s.code : '???',
      name: s.description,
      flatRateSurcharge: null,
      terminals: [
        AirportTerminal(
          name: S.of(context).mainTerminal,
          airlines: [],
          arrivalDoors: [S.of(context).arrivalsRidesharePickup, 'Rideshare Pickup Area'],
        ),
      ],
    );
    _selectAirport(airport);
  }

  // ─────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
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
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: _textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            // Header
            _buildHeader(),
            const SizedBox(height: 4),
            // Progress dots
            if (_step > 0) _buildProgressDots(),
            const SizedBox(height: 12),
            // Step content
            Flexible(
              child: AnimatedBuilder(
                animation: _animCtrl,
                builder: (_, child) => Opacity(
                  opacity: _animCtrl.isAnimating
                      ? (_animCtrl.value < 0.4 ? _fadeOut.value : _fadeIn.value)
                      : 1.0,
                  child: child,
                ),
                child: _buildStep(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final bool isTo   = _direction == AirportDirection.toAirport;
    final bool isFrom = _direction == AirportDirection.fromAirport;
    final IconData dirIcon = isFrom
        ? Icons.flight_land_rounded
        : Icons.flight_takeoff_rounded;
    final Color dirColor = isFrom ? _green : _blue;

    final String title = switch (_step) {
      0 => S.of(context).airportRideTitle,
      1 => S.of(context).selectAirport,
      2 => isFrom ? S.of(context).selectTerminalAndDoor : S.of(context).selectYourAirline,
      3 => isFrom ? S.of(context).confirmAirportPickupBtn : S.of(context).confirmAirportDropOff,
      _ => S.of(context).airportRideTitle,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          if (_step > 0)
            GestureDetector(
              onTap: _goBack,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(Icons.arrow_back_ios_rounded, color: _blue, size: 20),
              ),
            ),
          Icon(
            _step == 0 ? Icons.connecting_airports_rounded : dirIcon,
            color: _step == 0 ? _blue : dirColor,
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: _textPrimary, fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
          if (_selectedAirport != null && _step > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _blue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _selectedAirport!.code,
                style: const TextStyle(color: _blue, fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressDots() {
    const labels = ['', '', '', ''];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: List.generate(4, (i) {
          final active   = i == _step;
          final complete = i < _step;
          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 3,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: complete
                    ? _blue
                    : active
                        ? _blue.withValues(alpha: 0.6)
                        : _border,
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      0 => _buildDirectionPicker(),
      1 => _buildAirportList(),
      2 => _direction == AirportDirection.fromAirport
          ? _buildArrivalPicker()
          : _buildAirlinePicker(),
      3 => _buildConfirmDetails(),
      _ => const SizedBox.shrink(),
    };
  }

  // ─────────────────────────────────────────────
  //  STEP 0 — Direction Picker
  // ─────────────────────────────────────────────
  Widget _buildDirectionPicker() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        children: [
          _buildDirectionCard(
            direction: AirportDirection.toAirport,
            icon: Icons.flight_takeoff_rounded,
            color: _blue,
            title: S.of(context).takeMeToAirport,
            subtitle: S.of(context).flyingOutSubtitle,
          ),
          const SizedBox(height: 14),
          _buildDirectionCard(
            direction: AirportDirection.fromAirport,
            icon: Icons.flight_land_rounded,
            color: _green,
            title: S.of(context).pickMeUpFromAirport,
            subtitle: S.of(context).justLandedSubtitle,
          ),
        ],
      ),
    );
  }

  Widget _buildDirectionCard({
    required AirportDirection direction,
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    // .vrApt__dirCard (vip-apt-sheet.css:202-253):
    //   padding: 20px; border-radius: 20px;
    //   background: rgba(color,.07); border: 1.5px solid rgba(color,.25);
    //   gap: 14px;
    //   .vrApt__dirIcon: 56×56, radius 16, bg rgba(color,.12), icon 24px
    //   .vrApt__dirTitle: 16px w700
    //   .vrApt__dirSub:   13px w500
    //   :active transform: scale(.985)
    return _PressScale(
      onTap: () => _selectDirection(direction),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.25), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: _textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: TextStyle(
                          color: _textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, color: color, size: 16),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  STEP 1 — Airport List
  // ─────────────────────────────────────────────
  Widget _buildAirportList() {
    final filtered = _searchQuery.isEmpty
        ? kCommonAirports
        : kCommonAirports.where((a) =>
              a.code.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              a.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Column(
      children: [
        // Search field
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            // .vrApt__searchBox: padding 12px 14px (vip-apt-sheet.css:267)
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                icon: Icon(Icons.search_rounded, color: _textSecondary, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? GestureDetector(
                        onTap: () { _searchCtrl.clear(); _onSearchChanged(''); },
                        child: Icon(Icons.close_rounded, color: _textSecondary, size: 24),
                      )
                    : null,
                border: InputBorder.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              ...filtered.map((a) => _buildAirportTile(a)),
              if (_suggestions.isNotEmpty && filtered.isNotEmpty) _buildSeparator(),
              ..._suggestions.map((s) => _buildSuggestionTile(s)),
              if (_loadingSuggestions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: _blue.withValues(alpha: 0.7)),
                  )),
                ),
              if (!_loadingSuggestions && _suggestions.isEmpty && filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Column(children: [
                    Icon(Icons.search_off_rounded, color: _textSecondary, size: 40),
                    const SizedBox(height: 12),
                    Text(S.of(context).noAirportsFound, style: TextStyle(color: _textSecondary, fontSize: 14)),
                  ]),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAirportTile(AirportInfo a) {
    final int terminalCount = a.terminals.length;
    // .vrApt__airportItem:active (vip-apt-sheet.css:323):
    //   transform: scale(.985); 120ms ease-out — match the direction
    //   card press feedback exactly.
    return _PressScale(
      onTap: () => _selectAirport(a),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(color: _blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
              child: Center(child: Text(a.code, style: const TextStyle(color: _blue, fontSize: 14, fontWeight: FontWeight.w900))),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name, style: TextStyle(color: _textPrimary, fontSize: 14, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(S.of(context).terminalsCount(terminalCount), style: TextStyle(color: _textSecondary, fontSize: 12)),
                ],
              ),
            ),
            if (a.flatRateSurcharge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: _gold.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Text('+\$${a.flatRateSurcharge!.toStringAsFixed(0)}', style: const TextStyle(color: _gold, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionTile(_AirportSuggestion s) {
    return GestureDetector(
      onTap: () => _selectSuggestion(s),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _border)),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(color: _blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
              child: Center(
                child: s.code.isNotEmpty
                    ? Text(s.code, style: const TextStyle(color: _blue, fontSize: 13, fontWeight: FontWeight.w900))
                    : Icon(Icons.flight_rounded, color: _blue, size: 20),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(s.description, style: TextStyle(color: _textPrimary, fontSize: 14, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSeparator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Divider(color: _border, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(S.of(context).moreAirports, style: TextStyle(color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
        ),
        Expanded(child: Divider(color: _border, height: 1)),
      ]),
    );
  }

  // ─────────────────────────────────────────────
  //  STEP 2a — Airline Picker (toAirport)
  // ─────────────────────────────────────────────
  Widget _buildAirlinePicker() {
    if (_selectedAirport == null) return const SizedBox.shrink();
    final ap = _selectedAirport!;
    final allAirlines = ap.allAirlines;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Airport badge
          _buildAirportBadge(ap),
          const SizedBox(height: 20),

          Text(
            S.of(context).whichAirlineFlying.toUpperCase(),
            // .vrApt__sectionHeader (vip-apt-sheet.css:412-419):
            //   font-size: 12px; font-weight: 600;
            //   letter-spacing: 0.05em (≈0.6px at 12px);
            //   text-transform: uppercase;
            //   color: var(--vrApt-text-2) = rgba(255,255,255,.55);
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),

          if (allAirlines.isEmpty)
            // Fallback for unknown airports
            _buildUnknownAirportFallback()
          else
            ...allAirlines.map((airline) {
              // Show which terminal this airline maps to
              final terminals = ap.terminalsForAirline(airline);
              final termLabel = terminals.isNotEmpty ? terminals.first.name : '';
              final selected = _selectedAirline == airline;
              // .vrApt__airlineTile (vip-apt-sheet.css:431-462):
              //   padding 14px 16px → 13.5px 15.5px when selected
              //   (border grows 1→1.5px; padding shrinks .5px so the
              //    total card size stays identical — no layout jitter)
              //   icon 40×40, radius 10
              return GestureDetector(
                onTap: () => _selectAirline(airline),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: EdgeInsets.symmetric(
                    horizontal: selected ? 15.5 : 16,
                    vertical: selected ? 13.5 : 14,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? _blue.withValues(alpha: 0.12) : _surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: selected ? _blue : _border, width: selected ? 1.5 : 1),
                  ),
                  child: Row(
                    children: [
                      // .vrApt__airlineIcon (vip-apt-sheet.css:448-458):
                      //   width/height 38px; border-radius 10px
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: (selected ? _blue : _textSecondary).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.airplanemode_active_rounded, color: selected ? _blue : _textSecondary, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(airline, style: TextStyle(color: selected ? _blue : _textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
                            if (termLabel.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(termLabel, style: TextStyle(color: _textSecondary, fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                      if (selected) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: _blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                          child: Text(S.of(context).terminalAutoSelectedLabel, style: TextStyle(color: _blue, fontSize: 10, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.check_circle_rounded, color: _blue, size: 20),
                      ] else
                        Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 18),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildUnknownAirportFallback() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Icon(Icons.info_outline_rounded, color: _gold, size: 24),
          const SizedBox(height: 8),
          Text(
            "This airport's terminal data is not available. Your driver will confirm the terminal with you.",
            style: TextStyle(color: _textSecondary, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _advance,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
              decoration: BoxDecoration(color: _blue, borderRadius: BorderRadius.circular(12)),
              child: Text(S.of(context).continueButton, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  STEP 2b — Arrival Picker (fromAirport)
  // ─────────────────────────────────────────────
  Widget _buildArrivalPicker() {
    if (_selectedAirport == null) return const SizedBox.shrink();
    final ap = _selectedAirport!;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAirportBadge(ap),
          const SizedBox(height: 20),

          // Terminal chips — .vrApt__sectionHeader (vip-apt-sheet.css:412-419):
          //   12px w600 uppercase, color text-2 (rgba(255,255,255,.55)),
          //   letter-spacing .05em (≈0.6px at 12px).
          Text(S.of(context).whichTerminalArrived.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            )),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: ap.terminals.map((t) {
              final selected = _selectedTerminal?.name == t.name;
              return GestureDetector(
                onTap: () => setState(() {
                  _selectedTerminal = t;
                  _selectedArrivalDoor = null;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  // .vrApt__terminalChip: padding 10px 14px → 9.5px
                  // 13.5px when selected (border compensation)
                  padding: EdgeInsets.symmetric(
                    horizontal: selected ? 13.5 : 14,
                    vertical: selected ? 9.5 : 10,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? _green.withValues(alpha: 0.12) : _surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? _green : _border, width: selected ? 1.5 : 1),
                  ),
                  child: Text(t.name,
                    style: TextStyle(color: selected ? _green : _textPrimary, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, fontSize: 13)),
                ),
              );
            }).toList(),
          ),

          // Arrival doors — revealed after terminal selected.
          // Fade-in 200ms ease-out matches .vrApt__doorSection
          // animation: vrApt-fadeIn 200ms ease-out on the web.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: _selectedTerminal == null
                ? const SizedBox.shrink(key: ValueKey('no-doors'))
                : Column(
                    key: ValueKey('doors-${_selectedTerminal!.name}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      // .vrApt__sectionHeader (vip-apt-sheet.css:412-419):
                      //   12px w600 uppercase, color text-2,
                      //   letter-spacing .05em (≈0.6px at 12px).
                      Text(S.of(context).selectArrivalDoor.toUpperCase(),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.6)),
                      const SizedBox(height: 10),
                      ..._selectedTerminal!.arrivalDoors.map((door) {
                        final selected = _selectedArrivalDoor == door;
                        return GestureDetector(
                          onTap: () => _selectArrivalDoor(door),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            margin: const EdgeInsets.only(bottom: 8),
                            // .vrApt__doorTile: padding 14 → 13.5 selected
                            // (border 1→1.5 compensation).
                            padding: EdgeInsets.all(selected ? 13.5 : 14),
                            decoration: BoxDecoration(
                              color: selected
                                  ? _gold.withValues(alpha: 0.08)
                                  : _surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: selected
                                      ? _gold.withValues(alpha: 0.45)
                                      : _border,
                                  width: selected ? 1.5 : 1),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.pin_drop_rounded,
                                    color: selected ? _gold : _textSecondary,
                                    size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Text(door,
                                        style: TextStyle(
                                            color: selected
                                                ? _gold
                                                : _textPrimary,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            fontSize: 14))),
                                if (selected)
                                  Icon(Icons.check_circle_rounded,
                                      color: _gold, size: 20),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  STEP 3 — Flight Number + Confirm
  // ─────────────────────────────────────────────
  Widget _buildConfirmDetails() {
    if (_selectedAirport == null || _direction == null) return const SizedBox.shrink();
    final ap      = _selectedAirport!;
    final isFrom  = _direction == AirportDirection.fromAirport;
    final dirColor = isFrom ? _green : _blue;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: dirColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: dirColor.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: [
                _summaryRow(Icons.flight_rounded, S.of(context).airport, '${ap.code} — ${ap.name}', dirColor),
                if (_selectedTerminal != null) ...[
                  const SizedBox(height: 10),
                  _summaryRow(Icons.door_front_door_outlined, S.of(context).terminalLabel, _selectedTerminal!.name, dirColor),
                ],
                if (_selectedAirline != null) ...[
                  const SizedBox(height: 10),
                  _summaryRow(Icons.airplanemode_active_rounded, S.of(context).airlineLabel, _selectedAirline!, dirColor),
                ],
                if (_selectedArrivalDoor != null) ...[
                  const SizedBox(height: 10),
                  _summaryRow(Icons.pin_drop_rounded, S.of(context).arrivalDoorLabel, _selectedArrivalDoor!, dirColor),
                ],
                if (ap.flatRateSurcharge != null) ...[
                  const SizedBox(height: 10),
                  _summaryRow(Icons.attach_money_rounded, S.of(context).airportSurchargeLabel, '+\$${ap.flatRateSurcharge!.toStringAsFixed(2)}', _gold),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Direction note
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: dirColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(isFrom ? Icons.hail_rounded : Icons.place_rounded, color: dirColor, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isFrom ? S.of(context).driverWillWaitAtDoor : S.of(context).driverWillDropAtDepartures,
                    style: TextStyle(color: _textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Flight number
          Text(
            isFrom ? S.of(context).flightNumberRequiredLabel : S.of(context).flightNumberOptional,
            style: TextStyle(
              color: isFrom && _flightError ? _red : _textSecondary,
              fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _flightError ? _red.withValues(alpha: 0.6) : _border),
            ),
            child: TextField(
              controller: _flightCtrl,
              style: TextStyle(color: _textPrimary, fontSize: 15),
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) { if (_flightError) setState(() => _flightError = false); },
              decoration: InputDecoration(
                hintText: S.of(context).flightNumberHint,
                hintStyle: TextStyle(color: _textSecondary),
                // Web uses a plain plane icon (Lucide), not a ticket.
                icon: Icon(Icons.flight_rounded, color: _blue, size: 20),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_flightError) ...[
            const SizedBox(height: 6),
            Text(S.of(context).flightNumberRequiredError, style: const TextStyle(color: _red, fontSize: 12)),
          ],
          const SizedBox(height: 6),
          Text(S.of(context).flightTrackingNote, style: TextStyle(color: _textSecondary, fontSize: 12)),
          const SizedBox(height: 24),

          // Confirm button
          GestureDetector(
            onTap: _confirm,
            child: Container(
              width: double.infinity, height: 54,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: isFrom ? [_green, const Color(0xFF4CAF50)] : [_gold, _goldLight]),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: (isFrom ? _green : _gold).withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              // .vrApt__confirmBtn (vip-apt-sheet.css:716-725): text only,
              // no leading icon. Keep the button minimal like the web.
              child: Center(
                child: Text(
                  isFrom ? S.of(context).confirmAirportPickupBtn : S.of(context).confirmAirportDropOff,
                  style: TextStyle(color: isFrom ? Colors.white : Colors.black87, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAirportBadge(AirportInfo ap) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _blue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _blue.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          Icon(Icons.flight_rounded, color: _blue, size: 20),
          const SizedBox(width: 10),
          Text(ap.code, style: const TextStyle(color: _blue, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Expanded(child: Text(ap.name, style: TextStyle(color: _textPrimary, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value, Color iconColor) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 18),
        const SizedBox(width: 10),
        Text('$label: ', style: TextStyle(color: _textSecondary, fontSize: 13)),
        Expanded(
          child: Text(value, style: TextStyle(color: _textPrimary, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
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
  const _AirportSuggestion({required this.description, required this.placeId, required this.code});
}

// ═══════════════════════════════════════════════════════════════════
//  _PressScale — reusable :active scale(.985) ease-out 120ms wrapper.
//  Matches CSS `transition: transform 120ms cubic-bezier(0, 0, 0.58, 1);`
//  on .vrApt__dirCard / .vrApt__airportTile / .vrApt__airlineTile.
// ═══════════════════════════════════════════════════════════════════

class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressScale({
    required this.child,
    required this.onTap,
  });

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.985 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: const Cubic(0, 0, 0.58, 1),
        child: widget.child,
      ),
    );
  }
}
