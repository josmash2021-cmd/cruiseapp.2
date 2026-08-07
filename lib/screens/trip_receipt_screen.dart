import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../widgets/neu_style.dart';
import '../l10n/app_localizations.dart';
import '../config/api_keys.dart';
import '../services/api_service.dart';
import '../services/places_service.dart';
import '../services/local_data_service.dart';

class TripReceiptScreen extends StatefulWidget {
  final TripHistoryItem trip;

  const TripReceiptScreen({super.key, required this.trip});

  @override
  State<TripReceiptScreen> createState() => _TripReceiptScreenState();
}

class _TripReceiptScreenState extends State<TripReceiptScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  // Dark-neumorphism palette: one base surface, deep shadows bottom-right,
  // faint highlight top-left.
  static const _surface = Color(0xFF17171D);

  late AnimationController _entryController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;
  Map<String, dynamic>? _fareBreakdown;
  bool _breakdownLoading = true;

  /// The pickup street, when the stored address does not name one.
  ///
  /// A ride hailed from the rider's own position is saved as the literal
  /// "Current location". On a receipt that is worse than on a live screen —
  /// this is the record they keep, and it has to say where they were picked
  /// up, not where they happened to be standing when they opened the app.
  String? _resolvedPickup;

  Future<void> _resolvePickup() async {
    final raw = trip.pickup.toLowerCase().trim();
    final generic =
        raw.isEmpty || raw == 'current location' || raw == 'my location';
    if (!generic) return;
    final lat = trip.pickupLat, lng = trip.pickupLng;
    if (lat == null || lng == null) return;
    try {
      final addr = await PlacesService(ApiKeys.webServices)
          .reverseGeocode(lat: lat, lng: lng);
      if (addr != null && addr.isNotEmpty && mounted) {
        setState(() => _resolvedPickup = addr);
      }
    } catch (_) {
      // The stored phrase stays. A receipt is still a receipt without it.
    }
  }

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutCubic,
    ));
    _entryController.forward();
    _loadFareBreakdown();
    _resolvePickup();
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  TripHistoryItem get trip => widget.trip;

  Future<void> _loadFareBreakdown() async {
    final tid = trip.tripId;
    if (tid == null) {
      _breakdownLoading = false;
      return;
    }
    try {
      final data = await ApiService.getFareBreakdown(tid);
      if (mounted) {
        setState(() {
          _fareBreakdown = data;
          _breakdownLoading = false;
        });
      }
    } catch (e) {
      // Fare breakdown is optional — silently ignore errors in production,
      // but log in debug for troubleshooting
      debugPrint('[TripReceipt] Failed to load fare breakdown: $e');
      if (mounted) setState(() => _breakdownLoading = false);
    }
  }

  /// Distance: prefer backend fare breakdown over local trip data
  String get _effectiveMiles {
    final fbMiles = (_fareBreakdown?['distance_miles'] as num?)?.toDouble();
    if (fbMiles != null && fbMiles > 0) {
      return '${fbMiles.toStringAsFixed(1)} mi';
    }
    final local = trip.miles;
    if (local.isNotEmpty && local != '-- mi' && local != '0.0 mi' && local != '0.00 mi') {
      return local;
    }
    return '0.0 mi';
  }

  /// Duration: prefer backend fare breakdown over local trip data
  String get _effectiveDuration {
    final fbMin = (_fareBreakdown?['duration_minutes'] as num?)?.toInt();
    if (fbMin != null && fbMin > 0) {
      return _durationText(fbMin);
    }
    final local = trip.duration;
    if (local.isNotEmpty && local != '-- min' && local != '0 min') {
      // The local value arrives as plain minutes too, so it needs the same
      // treatment — otherwise the receipt reads in hours or not depending on
      // which of the two sources answered.
      final m = RegExp(r'^\s*(\d+)\s*min\s*$').firstMatch(local);
      final n = m == null ? null : int.tryParse(m.group(1)!);
      return n == null ? local : _durationText(n);
    }
    return '0 min';
  }

  /// Minutes, and hours once there are sixty of them.
  ///
  /// A receipt printing "2127 min" is asking the passenger to do the division
  /// themselves for a trip they have already taken and paid for.
  ///
  /// Exact, unlike the wait estimate on the booking sheet — that one rounds to
  /// five minutes because it is a guess, and rounding a guess is honest. This
  /// is a record of what happened, so 35 h 27 min stays 35 h 27 min.
  ///
  /// "min" and "h" are the same word in both languages this app speaks.
  String _durationText(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }

  /// A cancelled trip is not a sale: no PAID stamp, and the Total reads
  /// zero. The fare lines stay — they record what the ride would have
  /// cost; the Total records what was actually charged: nothing.
  bool get _isCancelled => trip.status.toLowerCase().contains('cancel');

  /// What the ride cost — backend `total` (trip.fare) wins, local trip
  /// price is the fallback. Shown on the header and the fare lines.
  String get _paidTotal {
    final t = (_fareBreakdown?['total'] as num?)?.toDouble();
    if (t != null && t > 0) return '\$${t.toStringAsFixed(2)}';
    return trip.price;
  }

  /// What the passenger was actually charged. Cancelled trips: zero.
  String get _chargedTotal => _isCancelled ? '\$0.00' : _paidTotal;

  /// The tier as the rider is shown it, from whatever `vehicle_type` holds.
  ///
  /// `suv` is tested before `vip`, or "SUV XL" matches the VIP branch and
  /// every receipt comes back BLACK.
  String _tierLabel(String vehicleType) {
    final n = vehicleType.toLowerCase();
    if (n.contains('suv')) return 'PREMIUM';
    if (n.contains('vip') || n.contains('suburban') || n.contains('black')) {
      return 'BLACK';
    }
    if (n.contains('sedan') || n.contains('camry') || n.contains('premium')) {
      return 'COMPACT';
    }
    return 'STANDARD';
  }

  /// The car that goes with it — the same four renders the booking sheet uses.
  String _tierAsset(String vehicleType) {
    final n = vehicleType.toLowerCase();
    if (n.contains('suv')) return 'assets/images/cruisert_suvxl.png';
    if (n.contains('vip') || n.contains('suburban') || n.contains('black')) {
      return 'assets/images/cruisert1.png';
    }
    if (n.contains('sedan') || n.contains('camry') || n.contains('premium')) {
      return 'assets/images/cruisert_compact.png';
    }
    return 'assets/images/cruisert3.png';
  }

  BoxDecoration _neu({double radius = 24}) => BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.045)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.60),
            offset: const Offset(7, 7),
            blurRadius: 16,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            offset: const Offset(-5, -5),
            blurRadius: 12,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      // The shared speckled ground, so this page sits on the same
      // surface as the menu it is reached from.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SlideTransition(
            position: _slideAnim,
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    children: [
                      // ── TOP BAR (back only — share + email removed) ──
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.of(context).pop(),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: _neu(radius: 14),
                              child: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // ── TITLE ──
                      Text(
                        S.of(context).tripReceipt,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── INVOICE CARD ──
                      // Torn-receipt bottom: the card ends in a sawtooth
                      // edge, and a soft shadow under the teeth fakes the
                      // slight curl of a ripped paper slip.
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Curl shadow, only visible through the teeth.
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: -7,
                            height: 18,
                            child: ImageFiltered(
                              imageFilter: ui.ImageFilter.blur(
                                  sigmaX: 7, sigmaY: 7),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black
                                      .withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          ClipPath(
                            clipper: _ReceiptEdgeClipper(),
                            child: Container(
                        padding: const EdgeInsets.all(22),
                        decoration: _neu(radius: 26),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Invoice header: brand + PAID stamp
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'CRUISE',
                                        style: TextStyle(
                                          color: _gold,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 4,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _fareBreakdown?['receipt_number'] ??
                                            '#CR-${trip.tripId ?? 0}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: c.textTertiary,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _formatDate(trip.createdAt),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: c.textTertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Status stamp — square to the page.
                                //
                                // It was rotated ten degrees to look like an
                                // ink stamp. On a receipt whose every other
                                // line is aligned, one tilted element reads as
                                // a rendering fault rather than as a flourish.
                                //
                                // Cancelled trips never say PAID — nothing
                                // was charged. Red CANCELLED stamp instead.
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 6),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _isCancelled
                                            ? const Color(0xFFE57373)
                                                .withValues(alpha: 0.9)
                                            : _gold.withValues(alpha: 0.85),
                                        width: 2,
                                      ),
                                    ),
                                    child: Text(
                                      _isCancelled
                                          ? S.of(context).cancelledBadge
                                              .toUpperCase()
                                          : S.of(context).statusPaid,
                                      style: TextStyle(
                                        color: _isCancelled
                                            ? const Color(0xFFE57373)
                                            : _gold,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 3,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // What they rode, and what it cost, on one line.
                            //
                            // This was a centred stack: the amount, the words
                            // "Paid by passenger" under it, and a tier pill
                            // under that. The caption said what the PAID stamp
                            // and the Payment Summary below already say twice
                            // over, and the pill named the tier without
                            // showing the car.
                            //
                            // Service on the left with its render, amount on
                            // the right. Two facts, one line, nothing repeated.
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Tier name hugging the left edge; the
                                    // car centred in its own box below.
                                    Text(
                                      _tierLabel(trip.rideName),
                                      textAlign: TextAlign.left,
                                      style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      width: 88,
                                      height: 34,
                                      child: Image.asset(
                                        _tierAsset(trip.rideName),
                                        fit: BoxFit.contain,
                                        // A touch left of centre — the
                                        // render's cabin mass sits right,
                                        // so dead-centre reads as right.
                                        alignment: Alignment(-0.45, 0),
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox.shrink(),
                                      ),
                                    ),
                                  ],
                                ),
                                const Spacer(),
                                // Shrinks rather than wrapping: a long fare is
                                // still one number and must read as one.
                                Flexible(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      _paidTotal,
                                      maxLines: 1,
                                      style: const TextStyle(
                                        color: _gold,
                                        fontSize: 40,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -1,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              child: _DashedDivider(color: c.divider),
                            ),

                            // ── ROUTE (miles + duration chips in header) ──
                            Row(
                              children: [
                                Text(
                                  S.of(context).routeHeader,
                                  style: TextStyle(
                                    color: c.textTertiary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const Spacer(),
                                _routeChip(c, Icons.straighten_rounded, _effectiveMiles),
                                const SizedBox(width: 8),
                                _routeChip(c, Icons.schedule_rounded, _effectiveDuration),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Timeline: donut — connector — hollow ring in
                            // a stretched left rail so the line physically
                            // touches both endpoint shapes. Cancelled: the
                            // line breaks in the middle and carries the
                            // CANCELLED tag in the gap.
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Column(
                                        children: [
                                          const SizedBox(height: 2),
                                          // Pickup: gold ring with a solid
                                          // gold core inside.
                                          Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: _gold,
                                                width: 1.6,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: _gold.withValues(
                                                      alpha: 0.45),
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: Container(
                                                width: 5,
                                                height: 5,
                                                decoration:
                                                    const BoxDecoration(
                                                  color: _gold,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: _RouteConnector(
                                                cancelled: _isCancelled),
                                          ),
                                          // Drop-off: hollow white ring.
                                          Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1.6,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.white
                                                      .withValues(
                                                          alpha: 0.30),
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                        ],
                                      ),
                                      // The tag sits in the line's break:
                                      // a small pill, tilted a touch like
                                      // it was stamped on the slip. Kept
                                      // tight (font 7, short padding) so
                                      // it clears the card's clip — a
                                      // wider pill gets cut by the edge.
                                      if (_isCancelled)
                                        Positioned(
                                          left: -30,
                                          right: -30,
                                          top: 0,
                                          bottom: 0,
                                          child: Center(
                                            child: Transform.rotate(
                                              angle: -0.18,
                                              child: Container(
                                                padding: const EdgeInsets
                                                    .symmetric(
                                                    horizontal: 5,
                                                    vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: _surface,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          4),
                                                  border: Border.all(
                                                    color: const Color(
                                                            0xFFE57373)
                                                        .withValues(
                                                            alpha: 0.9),
                                                    width: 1,
                                                  ),
                                                ),
                                                child: Text(
                                                  S.of(context)
                                                      .cancelledBadge
                                                      .toUpperCase(),
                                                  softWrap: false,
                                                  style: const TextStyle(
                                                    color: Color(
                                                        0xFFE57373),
                                                    fontSize: 7,
                                                    fontWeight:
                                                        FontWeight.w900,
                                                    letterSpacing: 0.8,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _routeBlock(
                                          c,
                                          label: S.of(context).pickupTagLabel,
                                          address:
                                              _resolvedPickup ?? trip.pickup,
                                        ),
                                        const SizedBox(height: 22),
                                        _routeBlock(
                                          c,
                                          label: S.of(context).dropoffTagLabel,
                                          address: trip.dropoff,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // ── PAYMENT SUMMARY — skeleton shimmer while
                            // loading, then a smooth swap to the real lines ──
                            if (_breakdownLoading || _fareBreakdown != null) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 20),
                                child: _DashedDivider(color: c.divider),
                              ),
                              Text(
                                S.of(context).fareBreakdownHeader,
                                style: TextStyle(
                                  color: c.textTertiary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 14),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOut,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 400),
                                  child: _breakdownLoading
                                      ? const _BreakdownSkeleton(
                                          key: ValueKey('skeleton'))
                                      : Column(
                                          key: const ValueKey('rows'),
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: _buildBreakdownRows(c),
                                        ),
                                ),
                              ),
                              if (!_breakdownLoading) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 14),
                                child: _DashedDivider(color: c.divider),
                              ),
                              Row(
                                children: [
                                  Text(
                                    S.of(context).totalLabel,
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    _chargedTotal,
                                    style: const TextStyle(
                                      color: _gold,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                              if (_fareBreakdown?['payment_method'] != null) ...[
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Icon(Icons.credit_card_rounded,
                                        color: c.textTertiary, size: 15),
                                    const SizedBox(width: 8),
                                    Text(
                                      S.of(context).paymentMethodLabel,
                                      style: TextStyle(
                                          color: c.textSecondary, fontSize: 13),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _fareBreakdown!['payment_method'] as String,
                                      style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              ],
                            ],
                          ],
                        ),
                          ),
                          ),
                        ],
                      ),

                      // No thanks on a ride that never happened.
                      if (!_isCancelled) ...[
                      const SizedBox(height: 20),
                      Center(
                        child: Text(
                          S.of(context).thankYouForRiding,
                          style: TextStyle(
                            color: c.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      ],
                    ],
                  ),
                ),

                // ── DONE BUTTON ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: const Color(0xFF08090C),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        S.of(context).done,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
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

  /// Payment lines, cent-exact so the visible rows always add up to the
  /// Total rendered below: Trip fare + extras + Tax + Tip = Total.
  List<Widget> _buildBreakdownRows(AppColors c) {
    final fb = _fareBreakdown!;
    int centsOf(String key) => (((fb[key] as num?) ?? 0) * 100).round();
    String money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

    // Extra charges, each shown as its own line when present.
    final extras = <({String label, int cents, bool highlight})>[];
    final surgeMult = (fb['surge_multiplier'] as num?) ?? 1.0;
    if (surgeMult > 1.0 && centsOf('surge_extra') > 0) {
      extras.add((
        label: S.of(context).surgeLabel(surgeMult.toStringAsFixed(1) + 'x'),
        cents: centsOf('surge_extra'),
        highlight: true,
      ));
    }
    if (centsOf('wait_time_charge') > 0) {
      extras.add((
        label: S.of(context).waitTimeLabel(
            _durationText(((fb['wait_time_minutes'] as num?) ?? 0).toInt())),
        cents: centsOf('wait_time_charge'),
        highlight: false,
      ));
    }
    if (centsOf('scheduled_surcharge') > 0) {
      extras.add((
        label: S.of(context).scheduledFeeLabel,
        cents: centsOf('scheduled_surcharge'),
        highlight: false,
      ));
    }
    if (centsOf('airport_fee') > 0) {
      extras.add((
        label: S.of(context).airportSurchargeLabel,
        cents: centsOf('airport_fee'),
        highlight: false,
      ));
    }
    if (centsOf('meet_greet_fee') > 0) {
      extras.add((
        label: S.of(context).meetGreetLabel,
        cents: centsOf('meet_greet_fee'),
        highlight: false,
      ));
    }
    if (centsOf('cancellation_fee') > 0) {
      extras.add((
        label: S.of(context).cancellationFeeLabel,
        cents: centsOf('cancellation_fee'),
        highlight: false,
      ));
    }

    final extrasC = extras.fold<int>(0, (sum, e) => sum + e.cents);
    final tipC = centsOf('tip_amount');
    var totalC = centsOf('total');
    if (totalC <= 0) {
      // Fallback: reconstruct the total from its components.
      totalC = centsOf('base_fare') +
          centsOf('mileage_charge') +
          centsOf('time_charge') +
          extrasC +
          tipC;
    }
    // Trip fare = whatever remains after extras and tip, so the visible
    // lines always reconcile with the Total line below.
    final remaining = totalC - extrasC - tipC;
    final tripFareC = remaining > 0 ? remaining : 0;

    final rows = <Widget>[
      _breakdownRow(c, S.of(context).tripFareLabel, money(tripFareC)),
      for (final e in extras)
        _breakdownRow(
          c,
          e.label,
          '${e.highlight ? '+' : ''}${money(e.cents)}',
          highlight: e.highlight,
        ),
    ];

    // Tip line is always visible so the receipt shows whether the
    // passenger left one or not.
    if (tipC > 0) {
      rows.add(_breakdownRow(c, S.of(context).tipLabel, money(tipC)));
    } else {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                S.of(context).tipLabel,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
            Text(
              S.of(context).noTipLabel,
              style: TextStyle(
                color: c.textTertiary,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ));
    }
    return rows;
  }

  Widget _routeChip(AppColors c, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: _neu(radius: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _gold, size: 12),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _routeBlock(
    AppColors c, {
    required String label,
    required String address,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: c.textTertiary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          address,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final amPm = value.hour >= 12 ? 'PM' : 'AM';
    return '${months[value.month - 1]} ${value.day}, ${value.year} · $hour:$minute $amPm';
  }

  Widget _breakdownRow(AppColors c, String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: highlight ? Colors.redAccent : c.textSecondary,
                fontSize: 13,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.redAccent : c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashed horizontal divider — gives the receipt its invoice "tear line".
class _DashedDivider extends StatelessWidget {
  final Color color;

  const _DashedDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dashWidth = 6.0;
        const dashSpace = 4.0;
        final count =
            (constraints.maxWidth / (dashWidth + dashSpace)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            count,
            (_) => Container(width: dashWidth, height: 1, color: color),
          ),
        );
      },
    );
  }
}

/// Animated route connector — a dashed gold line with a glowing pulse
/// that travels pickup -> dropoff on a 2 s loop (easeInOut), fading in
/// and out at the ends. Painted so it stretches to exactly fill the gap
/// between the endpoint shapes.
class _RouteConnector extends StatefulWidget {
  const _RouteConnector({this.cancelled = false});

  /// Cancelled trips: the line breaks in the middle (the CANCELLED tag
  /// fills the gap) and the travelling pulse does not run — nothing is
  /// moving on a ride that never happened.
  final bool cancelled;

  @override
  State<_RouteConnector> createState() => _RouteConnectorState();
}

class _RouteConnectorState extends State<_RouteConnector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (!widget.cancelled) _ctl.repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (_, __) => CustomPaint(
          painter: _RouteConnectorPainter(
              t: _ctl.value, cancelled: widget.cancelled),
        ),
      ),
    );
  }
}

class _RouteConnectorPainter extends CustomPainter {
  final double t;
  final bool cancelled;

  _RouteConnectorPainter({required this.t, required this.cancelled});

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    const inset = 1.0;

    final linePaint = Paint()
      ..color = const Color(0x59E8C547)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    if (cancelled) {
      // Two solid segments with a break in the middle for the tag; no
      // pulse — nothing is moving on a ride that never happened.
      const gapHalf = 16.0;
      final mid = size.height / 2;
      canvas.drawLine(
          Offset(x, inset), Offset(x, mid - gapHalf), linePaint);
      canvas.drawLine(
          Offset(x, mid + gapHalf), Offset(x, size.height - inset),
          linePaint);
      return;
    }

    // Live trips: dashed base line with the travelling glow pulse.
    const dashH = 3.5;
    const gap = 3.5;
    double y = inset;
    while (y < size.height - inset) {
      final end = (y + dashH).clamp(y, size.height - inset);
      canvas.drawLine(Offset(x, y), Offset(x, end), linePaint);
      y += dashH + gap;
    }

    // Traveling glow pulse, eased, fading near the ends
    final eased = Curves.easeInOut.transform(t);
    final cy = inset + (size.height - inset * 2) * eased;
    final edgeFade =
        (1.0 - ((t - 0.5).abs() * 2 - 0.7) / 0.3).clamp(0.0, 1.0);
    final glowPaint = Paint()
      ..color = const Color(0xFFE8C547).withValues(alpha: 0.9 * edgeFade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(x, cy), 3.2, glowPaint);
    canvas.drawCircle(
      Offset(x, cy),
      1.8,
      Paint()..color = Colors.white.withValues(alpha: edgeFade),
    );
  }

  @override
  bool shouldRepaint(_RouteConnectorPainter old) =>
      old.t != t || old.cancelled != cancelled;
}

/// Shimmer skeleton shown while the fare breakdown loads — three fake
/// label/amount lines plus a total line, with a highlight band sweeping
/// left -> right on a 1.4 s loop.
class _BreakdownSkeleton extends StatefulWidget {
  const _BreakdownSkeleton({super.key});

  @override
  State<_BreakdownSkeleton> createState() => _BreakdownSkeletonState();
}

class _BreakdownSkeletonState extends State<_BreakdownSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (_, __) {
        final t = _ctl.value;
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return Column(
              children: [
                _skeletonRow(t, w, labelWidth: 0.38),
                const SizedBox(height: 12),
                _skeletonRow(t, w, labelWidth: 0.22),
                const SizedBox(height: 12),
                _skeletonRow(t, w, labelWidth: 0.30),
                const SizedBox(height: 18),
                _skeletonRow(t, w,
                    labelWidth: 0.26, amountWidth: 64, height: 15),
              ],
            );
          },
        );
      },
    );
  }

  Widget _skeletonRow(
    double t,
    double maxWidth, {
    required double labelWidth,
    double amountWidth = 48,
    double height = 12,
  }) {
    return Row(
      children: [
        SizedBox(
          width: maxWidth * labelWidth,
          child: _SkeletonBar(t: t, height: height),
        ),
        const Spacer(),
        SizedBox(
          width: amountWidth,
          child: _SkeletonBar(t: t, height: height),
        ),
      ],
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  final double t;
  final double height;

  const _SkeletonBar({required this.t, required this.height});

  @override
  Widget build(BuildContext context) {
    final start = (t - 0.25).clamp(0.0, 1.0);
    final mid = t.clamp(0.0, 1.0);
    final end = (t + 0.25).clamp(0.0, 1.0);
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [
            Color(0x0DFFFFFF),
            Color(0x22FFFFFF),
            Color(0x0DFFFFFF),
          ],
          stops: [start, mid, end],
        ),
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

/// Torn-receipt edge: keeps the card's top corners rounded but replaces
/// the bottom edge with a sawtooth, like a slip ripped off the roll.
class _ReceiptEdgeClipper extends CustomClipper<Path> {
  /// How deep each tooth bites, in logical pixels.
  static const double depth = 8.0;

  /// Tooth width — narrow enough to read as serration, wide enough to
  /// survive anti-aliasing at phone densities.
  static const double tooth = 12.0;

  /// Top corner radius, matching the card's _neu(radius: 26).
  static const double radius = 26.0;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final baseY = h - depth;
    final path = Path()
      ..moveTo(0, radius)
      ..quadraticBezierTo(0, 0, radius, 0)
      ..lineTo(w - radius, 0)
      ..quadraticBezierTo(w, 0, w, radius)
      ..lineTo(w, baseY);
    // Zigzag back along the bottom, right to left: each tooth dips to
    // baseY + depth at its midpoint and returns to the base line.
    var x = w;
    while (x > 0) {
      final next = (x - tooth).clamp(0.0, w);
      path
        ..lineTo((x + next) / 2, baseY + depth)
        ..lineTo(next, baseY);
      x = next;
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(_ReceiptEdgeClipper old) => false;
}
