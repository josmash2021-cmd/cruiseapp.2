import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../config/api_keys.dart';
import '../data/airport_data.dart';
import '../l10n/app_localizations.dart';
import '../models/airport_models.dart';
import '../widgets/neu_style.dart';

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

  /// When provided (airport flow from [AirportDirectionScreen]), the
  /// direction step is skipped and the sheet starts at the airport list.
  final AirportDirection? initialDirection;

  const AirportTerminalSheet({
    super.key,
    required this.isDark,
    this.initialDirection,
  });

  @override
  State<AirportTerminalSheet> createState() => _AirportTerminalSheetState();
}

class _AirportTerminalSheetState extends State<AirportTerminalSheet>
    with TickerProviderStateMixin {
  static final _airportCodeRe = RegExp(r'\b([A-Z]{3})\b');

  // ── colours ── Premium gold palette matching web
  static const _gold      = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5DC7A);
  static const _blue      = Color(0xFF3B82F6);
  static const _green     = Color(0xFF22C55E);
  static const _red       = Color(0xFFEF4444);

  // ── animation ──
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeOut;
  late final Animation<double> _fadeIn;
  // Slow repeating sweep for the active progress segment.
  late final AnimationController _shimmerCtl;

  // ── state ──
  int _step = 0; // 0=direction 1=airport 2=details 3=confirm

  // ── video background (direction step only) ──
  VideoPlayerController? _video;
  bool _videoReady = false;

  AirportDirection? _direction;
  AirportInfo?      _selectedAirport;
  AirportTerminal?  _selectedTerminal;
  String?           _selectedAirline;
  String?           _selectedArrivalDoor;

  final _flightCtrl  = TextEditingController();
  final _searchCtrl  = TextEditingController();
  // Dedicated controller for the airport list scrollbar (step 1 — 40+ rows).
  final _airportListScrollCtrl = ScrollController();
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
    _shimmerCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _initVideo();
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
    // When the direction was picked on AirportDirectionScreen, skip the
    // in-sheet direction step and start at the airport list.
    if (widget.initialDirection != null) {
      _direction = widget.initialDirection;
      _step = 1;
    }
  }

  Future<void> _initVideo() async {
    try {
      _video = VideoPlayerController.asset('assets/videos/airport_bg.mp4');
      await _video!.initialize();
      await _video!.setLooping(true);
      await _video!.setVolume(0);
      if (mounted) {
        setState(() => _videoReady = true);
        if (_step == 0) _video!.play();
      }
    } catch (_) {
      // Video unavailable — the neuBase background stays as fallback.
    }
  }

  /// Play the background video only on the direction step.
  void _syncVideoToStep() {
    if (!_videoReady) return;
    if (_step == 0) {
      _video?.play();
    } else {
      _video?.pause();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _shimmerCtl.dispose();
    _video?.dispose();
    _flightCtrl.dispose();
    _searchCtrl.dispose();
    _airportListScrollCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  Theme helpers
  // ─────────────────────────────────────────────
  Color get _textPrimary   => widget.isDark ? Colors.white : const Color(0xFF0F1419);
  Color get _textSecondary => widget.isDark ? Colors.white.withValues(alpha: 0.55) : const Color(0xFF6B7280);
  Color get _border     => widget.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black12;

  // ─────────────────────────────────────────────
  //  Navigation helpers
  // ─────────────────────────────────────────────
  void _advance() {
    setState(() => _step++);
    _animCtrl.forward(from: 0);
    _syncVideoToStep();
  }

  void _goBack() {
    // Step 1 → step 0 (direction picker) even when the direction came
    // pre-selected: back should return to the previous page of the
    // flow, never drop the rider straight to home. Back at step 0 pops.
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
    _syncVideoToStep();
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
          final codeM   = _airportCodeRe.allMatches(desc);
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
  //  BUILD — ALL STEPS fullscreen 1:1 with web
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final kb = mq.viewInsets.bottom;

    // ALL steps: Fullscreen mode with video background (1:1 with web)
    return _buildFullscreenSheet(context, kb);
  }

  // Fullscreen sheet for ALL steps — 1:1 with web vrApt--full
  Widget _buildFullscreenSheet(BuildContext context, double keyboardHeight) {
    final isStep0 = _step == 0;

    // The modal sheet already respects the status bar (useSafeArea:
    // true), so no manual top inset here — adding one left a visible
    // dead gap above the header.
    return Stack(
      fit: StackFit.expand,
      children: [
        // Neumorphic base background.
        const SizedBox.expand(
          child: ColoredBox(color: neuBase),
        ),
        // Video background on the direction step only.
        if (_step == 0 && _videoReady && _video != null) ...[
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _video!.value.size.width,
                height: _video!.value.size.height,
                child: VideoPlayer(_video!),
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.78)),
        ],
        // Main content column.
        Padding(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              // Header row: Back button (step > 0) or Close (step 0) + Title
              Padding(
                padding: EdgeInsets.fromLTRB(16, isStep0 ? 8 : 16, 16, 8),
                child: Row(
                  children: [
                    // Back/Close button
                    if (isStep0)
                      _HeaderCircleBtn(
                        icon: Icons.arrow_back_ios_rounded,
                        iconColor: Colors.white.withValues(alpha: 0.7),
                        onTap: () => Navigator.of(context).pop(),
                      )
                    else
                      _HeaderCircleBtn(
                        icon: Icons.arrow_back_ios_rounded,
                        iconColor: Colors.white.withValues(alpha: 0.7),
                        onTap: _goBack,
                      ),
                    const SizedBox(width: 12),
                    // Title (hidden in step 0)
                    if (!isStep0) ...[
                      Expanded(
                        child: _buildHeaderTitle(),
                      ),
                      // Airport code pill if available (step 2+)
                      if (_selectedAirport != null && _step >= 2)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _selectedAirport!.code,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                    ] else
                      // Step 0 — centered "Airport Ride" title (same as
                      // the standalone direction screen).
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 40),
                            child: Text(
                              S.of(context).airportRideTitle,
                              style: const TextStyle(
                                fontFamily: 'Poppins',
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Progress dots (steps 1-3)
              if (!isStep0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _buildProgressDots(),
                ),
              // Step content — fade + gentle vertical slide so steps
              // never swap abruptly.
              Expanded(
                child: AnimatedBuilder(
                  animation: _animCtrl,
                  builder: (_, child) {
                    final animating = _animCtrl.isAnimating;
                    final fadingOut =
                        animating && _animCtrl.value < 0.4;
                    final opacity = animating
                        ? (fadingOut ? _fadeOut.value : _fadeIn.value)
                        : 1.0;
                    final dy = animating
                        ? (fadingOut
                            ? -10 * (1 - _fadeOut.value)
                            : 14 * (1 - _fadeIn.value))
                        : 0.0;
                    return Opacity(
                      opacity: opacity,
                      child: Transform.translate(
                        offset: Offset(0, dy),
                        child: child,
                      ),
                    );
                  },
                  child: _buildStep(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Header title widget for steps 1-3
  Widget _buildHeaderTitle() {
    final bool isTo = _direction == AirportDirection.toAirport;
    final bool isFrom = _direction == AirportDirection.fromAirport;

    final String title = switch (_step) {
      0 => S.of(context).airportRideTitle,
      1 => S.of(context).selectAirport,
      2 => isFrom ? S.of(context).selectTerminalAndDoor : S.of(context).selectYourAirline,
      3 => isFrom ? S.of(context).confirmAirportPickupBtn : S.of(context).confirmAirportDropOff,
      _ => S.of(context).airportRideTitle,
    };

    return Text(
      title,
      style: const TextStyle(
        fontFamily: 'Poppins',
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.02,
      ),
    );
  }

  Widget _buildHeader() {
    final bool isTo   = _direction == AirportDirection.toAirport;
    final bool isFrom = _direction == AirportDirection.fromAirport;
    final IconData dirIcon = isFrom
        ? Icons.flight_land_rounded
        : Icons.flight_takeoff_rounded;
    final Color dirColor = isFrom ? _gold : _blue;

    // Título según el paso
    final String title = switch (_step) {
      0 => S.of(context).airportRideTitle,
      1 => S.of(context).selectAirport, // "Seleccionar Aeropuerto"
      2 => isFrom ? S.of(context).selectTerminalAndDoor : S.of(context).selectYourAirline,
      3 => isFrom ? S.of(context).confirmAirportPickupBtn : S.of(context).confirmAirportDropOff,
      _ => S.of(context).airportRideTitle,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          // Botón back (solo si no es paso 0)
          if (_step > 0) ...[
            _HeaderCircleBtn(
              icon: Icons.arrow_back_ios_rounded,
              iconColor: Colors.white.withValues(alpha: 0.7),
              onTap: _goBack,
            ),
            const SizedBox(width: 12),
          ],
          // Ícono de avión DORADO (como en web)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF5DC7A), Color(0xFFE8C547)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _step == 0 ? Icons.flight_rounded : dirIcon,
              color: Colors.black,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          // Título con Poppins
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                height: 1.2,
              ),
            ),
          ),
          // Código de aeropuerto seleccionado (si aplica)
          if (_selectedAirport != null && _step > 1) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _gold.withValues(alpha: 0.3)),
              ),
              child: Text(
                _selectedAirport!.code,
                style: const TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          // Botón cerrar
          _HeaderCircleBtn(
            icon: Icons.close_rounded,
            iconColor: Colors.white.withValues(alpha: 0.55),
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressDots() {
    // .vrApt__progress (css:143-158): padding 0 16px 16px.
    // Active segment carries a slow shimmer sweep so it reads alive.
    return AnimatedBuilder(
      animation: _shimmerCtl,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
                            ? null
                            : _border,
                    gradient: active
                        ? LinearGradient(
                            colors: [
                              _blue.withValues(alpha: 0.35),
                              _blue,
                              _blue.withValues(alpha: 0.35),
                            ],
                            stops: [
                              (_shimmerCtl.value - 0.3).clamp(0.0, 1.0),
                              _shimmerCtl.value,
                              (_shimmerCtl.value + 0.3).clamp(0.0, 1.0),
                            ],
                          )
                        : null,
                  ),
                ),
              );
            }),
          ),
        );
      },
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
  //  STEP 0 — Direction Picker (1:1 with web - vertical cards)
  // ─────────────────────────────────────────────
  Widget _buildDirectionPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        children: [
          const Spacer(flex: 2),
          _buildDirectionCardVertical(
            direction: AirportDirection.toAirport,
            title: S.of(context).takeMeToAirport,
            subtitle: S.of(context).flyingOutSubtitle,
            isToAirport: true,
          ),
          const SizedBox(height: 28),
          _buildDirectionCardVertical(
            direction: AirportDirection.fromAirport,
            title: S.of(context).pickMeUpFromAirport,
            subtitle: S.of(context).justLandedSubtitle,
            isToAirport: false,
          ),
          const Spacer(flex: 3),
        ],
      ),
    );
  }

  // 1:1 with web — Vertical direction cards with large glass icon
  Widget _buildDirectionCardVertical({
    required AirportDirection direction,
    required String title,
    required String subtitle,
    required bool isToAirport,
  }) {
    return _PressScale(
      onTap: () => _selectDirection(direction),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.transparent),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Large glass icon container — 1:1 with web .vrApt__dirIcon--big
            _AnimatedPlaneIcon(
              isToAirport: isToAirport,
            ),
            const SizedBox(height: 16),
            // Title — large, centered, white
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                height: 1.25,
                letterSpacing: -0.02,
              ),
            ),
            const SizedBox(height: 6),
            // Subtitle — smaller, centered, muted
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
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
        // Search field — lives in the .vrApt__body padding (0 20 24).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            // .vrApt__searchBox (css:263-272): padding 12px 14px, gap 10px,
            // bg surface, radius 14, border .10, margin-bottom 12px.
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: neuBox(radius: 14, pressed: true),
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
        // .vrApt__searchBox margin-bottom: 12px.
        const SizedBox(height: 12),
        Expanded(
          // .vrApt__body::-webkit-scrollbar (css:169): width 3px,
          // thumb rgba(255,255,255,.15). Flutter equivalent below.
          child: RawScrollbar(
            controller: _airportListScrollCtrl,
            thumbColor: Colors.white.withValues(alpha: 0.15),
            thickness: 3,
            radius: const Radius.circular(2),
            thumbVisibility: true,
            child: ListView(
              controller: _airportListScrollCtrl,
              physics: const BouncingScrollPhysics(),
              // Align with .vrApt__body padding: 0 20px 24px. Previously
              // was horizontal 16 which offset tiles 4px inwards from the
              // search box — visible as a misalignment on the left edge.
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
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
        ),
      ],
    );
  }

  Widget _buildAirportTile(AirportInfo a) {
    final int terminalCount = a.terminals.length;
    // Premium airport tile matching web design
    return _PressScale(
      onTap: () => _selectAirport(a),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
        child: Row(
          children: [
            // Airport code in premium gold badge
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF5DC7A), Color(0xFFE8C547)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  a.code,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Airport name with Poppins
                  Text(
                    a.name,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  // Terminals count
                  Text(
                    '$terminalCount terminales',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Flecha al final
            Icon(
              Icons.arrow_forward_ios_rounded, 
              color: Colors.white.withValues(alpha: 0.3), 
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionTile(_AirportSuggestion s) {
    // Same :active scale(.985) feedback as .vrApt__airportTile.
    return _PressScale(
      onTap: () => _selectSuggestion(s),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 16),
        child: Row(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(color: _blue.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
              child: Center(
                child: s.code.isNotEmpty
                    ? Text(s.code, style: const TextStyle(color: _blue, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.26))
                    : Icon(Icons.flight_rounded, color: _blue, size: 20),
              ),
            ),
            // .vrApt__airportTile: gap 12px.
            const SizedBox(width: 12),
            Expanded(child: Text(s.description, style: TextStyle(color: _textPrimary, fontSize: 14, fontWeight: FontWeight.w600, height: 1.3), maxLines: 2, overflow: TextOverflow.ellipsis)),
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
          child: Text(S.of(context).moreAirports, style: TextStyle(color: _textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
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
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Airport badge (gold version matching web)
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
                  decoration: selected
                      ? neuBox(radius: 14, borderColor: _gold, borderWidth: 1.5)
                      : neuBox(radius: 14),
                  child: Row(
                    children: [
                      // .vrApt__airlineIcon (vip-apt-sheet.css:448-458):
                      //   width/height 38px; border-radius 10px
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: (selected ? _gold : _textSecondary).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.airplanemode_active_rounded, color: selected ? _gold : _textSecondary, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(airline, style: TextStyle(color: selected ? _gold : _textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
                            if (termLabel.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(termLabel, style: TextStyle(color: _textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
                            ],
                          ],
                        ),
                      ),
                      if (selected) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: _gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                          child: Text(S.of(context).terminalAutoSelectedLabel, style: TextStyle(color: _gold, fontSize: 10, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.check_circle_rounded, color: _gold, size: 20),
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
      decoration: neuBox(radius: 14, borderColor: _gold.withValues(alpha: 0.2)),
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
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
                  decoration: selected
                      ? neuBox(radius: 12, borderColor: _gold, borderWidth: 1.5)
                      : neuBox(radius: 12),
                  child: Text(t.name,
                    style: TextStyle(color: selected ? _gold : _textPrimary, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, fontSize: 13)),
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
                            decoration: selected
                                ? neuBox(
                                    radius: 14,
                                    borderColor: _gold.withValues(alpha: 0.45),
                                    borderWidth: 1.5,
                                  )
                                : neuBox(radius: 14),
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

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: neuBox(
              radius: 16,
              borderColor: dirColor.withValues(alpha: 0.18),
            ),
            // .vrApt__summaryRow (vip-apt-sheet.css:619-632):
            //   padding: 4px 0 per row — compact spacing, no gaps.
            child: Column(
              children: [
                _summaryRow(Icons.flight_rounded, S.of(context).airport, '${ap.code} — ${ap.name}', dirColor),
                if (_selectedTerminal != null) ...[
                  const SizedBox(height: 12),
                  _summaryRow(Icons.door_front_door_outlined, S.of(context).terminalLabel, _selectedTerminal!.name, dirColor),
                ],
                if (_selectedAirline != null) ...[
                  const SizedBox(height: 12),
                  _summaryRow(Icons.airplanemode_active_rounded, S.of(context).airlineLabel, _selectedAirline!, dirColor),
                ],
                if (_selectedArrivalDoor != null) ...[
                  const SizedBox(height: 12),
                  _summaryRow(Icons.pin_drop_rounded, S.of(context).arrivalDoorLabel, _selectedArrivalDoor!, dirColor),
                ],
                // Airport surcharge is charged but intentionally NOT
                // shown to the rider on this page.
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Direction note
          Container(
            padding: const EdgeInsets.all(12),
            decoration: neuBox(radius: 12, pressed: true),
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
            decoration: neuBox(
              radius: 14,
              pressed: true,
              borderColor: _flightError ? _red.withValues(alpha: 0.6) : null,
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
        ],
      ),
          ),
        ),

        // Confirm button pinned at the bottom — same placement as every
        // other screen in the flow.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: _PressScale(
            onTap: _confirm,
            child: Container(
              width: double.infinity, height: 54,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: isFrom ? [_green, const Color(0xFF4CAF50)] : [_gold, _goldLight]),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: (isFrom ? _green : _gold).withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Center(
                child: Text(
                  isFrom ? S.of(context).confirmAirportPickupBtn : S.of(context).confirmAirportDropOff,
                  style: TextStyle(color: isFrom ? Colors.white : Colors.black87, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAirportBadge(AirportInfo ap) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: neuBox(
        radius: 14,
        pressed: true,
        borderColor: _gold.withValues(alpha: 0.45),
      ),
      child: Row(
        children: [
          Icon(Icons.flight_rounded, color: _gold, size: 20),
          const SizedBox(width: 10),
          Text(ap.code, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Expanded(child: Text(ap.name, style: const TextStyle(color: _gold, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value, Color iconColor) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: neuBox(radius: 10, pressed: true),
          child: Icon(icon, color: iconColor, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
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

/// Internal model for a Google Places airport autocomplete suggestion.
class _AirportSuggestion {
  final String description;
  final String placeId;
  final String code;
  const _AirportSuggestion({required this.description, required this.placeId, required this.code});
}

// ═══════════════════════════════════════════════════════════════════
//  _HeaderCircleBtn — 1:1 port of .vrApt__backBtn / .vrApt__closeBtn.
//  CSS ref (vip-apt-sheet.css:91-110):
//    width/height: 36px; border-radius: 50%;
//    background: transparent; hover bg rgba(255,255,255,.06);
//    transition: background-color 160ms ease-out.
// ═══════════════════════════════════════════════════════════════════
class _HeaderCircleBtn extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  const _HeaderCircleBtn({
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  State<_HeaderCircleBtn> createState() => _HeaderCircleBtnState();
}

class _HeaderCircleBtnState extends State<_HeaderCircleBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: const Cubic(0, 0, 0.58, 1),
        width: 40,
        height: 40,
        decoration: neuBox(radius: 14, pressed: _pressed),
        alignment: Alignment.center,
        child: Icon(widget.icon, color: widget.iconColor, size: 20),
      ),
    );
  }
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

// ═══════════════════════════════════════════════════════════════════
//  _AnimatedPlaneIcon — 1:1 with web .vrApt__dirIcon--big
//  Large glass icon with subtle flight animation and arrow badge
// ═══════════════════════════════════════════════════════════════════
class _AnimatedPlaneIcon extends StatefulWidget {
  final bool isToAirport;

  const _AnimatedPlaneIcon({
    required this.isToAirport,
  });

  @override
  State<_AnimatedPlaneIcon> createState() => _AnimatedPlaneIconState();
}

class _AnimatedPlaneIconState extends State<_AnimatedPlaneIcon>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 3.6s animation like web's vrAptPlaneTo/vrAptPlaneFrom
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller.stop();
    } else if (state == AppLifecycleState.resumed) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFE8C547);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Subtle floating animation (1:1 with web)
        final t = _controller.value;
        final dx = widget.isToAirport
            ? 4 * math.sin(t * 2 * math.pi) // Fly right
            : -4 * math.sin(t * 2 * math.pi); // Fly left
        final dy = widget.isToAirport
            ? -5 * math.sin(t * 2 * math.pi) // Up
            : -4 * math.sin(t * 2 * math.pi); // Up less
        final rot = widget.isToAirport
            ? 1.5 * math.sin(t * 2 * math.pi) // Tilt
            : -1.5 * math.sin(t * 2 * math.pi); // Tilt other way

        return Container(
          width: 150,
          height: 150,
          decoration: neuBox(radius: 22, pressed: true),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Soft glowing trail behind plane (1:1 with web glow)
                Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, 0),
                      radius: 0.6,
                      colors: [
                        gold.withValues(alpha: 0.15 * (0.7 + 0.3 * math.sin(t * 2 * math.pi))),
                        gold.withValues(alpha: 0.05),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
                // Animated plane image — full 3D PNG sized to fill most
                // of the 190x190 glass tile, with internal padding so the
                // wings don't kiss the rounded border.
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Transform.translate(
                    offset: Offset(dx, dy),
                    child: Transform.rotate(
                      angle: rot * math.pi / 180,
                      child: Image.asset(
                        widget.isToAirport
                            ? 'assets/airport/airport_takeoff.png'
                            : 'assets/airport/airport_landing.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                // Arrow badge in top-right (1:1 with web ::after)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE8C547), Color(0xFFFBE47A)],
                      ),
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: [
                        BoxShadow(
                          color: gold.withValues(alpha: 0.5),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        widget.isToAirport ? '→' : '←',
                        style: const TextStyle(
                          color: Color(0xFF0A0E1A),
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
