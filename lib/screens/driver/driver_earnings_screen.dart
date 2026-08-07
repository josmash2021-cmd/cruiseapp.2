import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';
import '../../services/earnings_privacy.dart';
import '../../services/user_session.dart';
import '../../config/app_config.dart';
import '../../l10n/app_localizations.dart';
import 'payout_methods_screen.dart';
import '../../widgets/neu_style.dart';

/// Full-featured earnings screen — fetches real data from the backend.
/// Falls back to empty state if API is unreachable.
class DriverEarningsScreen extends StatefulWidget {
  const DriverEarningsScreen({super.key});

  @override
  State<DriverEarningsScreen> createState() => _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends State<DriverEarningsScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);

  int _selectedPeriod = 1; // 0=Today, 1=This Week, 2=This Month, 3=Year
  final _periodKeys = ['today', 'week', 'month', 'year'];

  /// Month currently shown in the Month tab. Only year/month matter.
  DateTime _selectedMonth = DateTime.now();

  late AnimationController _chartCtrl;
  late Animation<double> _chartAnim;

  bool _loading = true;
  double _total = 0.0;
  int _tripsCount = 0;
  double _onlineHours = 0.0;
  double _tipsTotal = 0.0;
  /// Offers turned down in the period. Counted from
  /// dispatch_offers, because a rejection never becomes a trip.
  int _ridesRejected = 0;
  List<double> _dailyEarnings = [0, 0, 0, 0, 0, 0, 0];
  List<String> _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Error state — surfaced under the headline figure.
  String? _earningsError;

  // Auto-payout data
  DateTime? _nextPayoutDate;
  double _pendingBalance = 0.0;
  bool _stripeConnected = false;
  List<Map<String, dynamic>> _cashoutHistory = [];

  // Payout methods
  bool _hasPayoutMethod = false;

  /// Mirrors [EarningsPrivacy.hidden] so the switch can be drawn.
  ///
  /// What it covers is the earnings chip on Home and Online, not the figures
  /// on this page. This is where a driver comes to read their earnings, on
  /// purpose; the chip is what sits at the top of the map in front of a
  /// passenger.
  bool _hideEarnings = false;

  Future<void> _loadHideEarnings() async {
    await EarningsPrivacy.load();
    if (mounted) setState(() => _hideEarnings = EarningsPrivacy.hidden.value);
  }

  Future<void> _toggleHideEarnings() async {
    HapticService.selectionClick();
    final next = !_hideEarnings;
    setState(() => _hideEarnings = next);
    await EarningsPrivacy.set(next);
  }

  /// Payout history, on request rather than always on the page.
  void _showCashoutHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: neuBase,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          20 + MediaQuery.of(ctx).padding.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_cashoutHistory.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(
                      S.of(context).noTripsYet,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              else
                ..._buildCashoutHistory(),
            ],
          ),
        ),
      ),
    );
  }

  double get _maxDay {
    final m = _dailyEarnings.isEmpty ? 0.0 : _dailyEarnings.reduce(max);
    return m > 0 ? m : 1.0;
  }

  double _toDouble(dynamic v, {double fallback = 0.0}) {
    if (v is num) {
      final d = v.toDouble();
      return d.isFinite ? d : fallback;
    }
    final p = double.tryParse(v?.toString() ?? '');
    if (p == null || !p.isFinite) return fallback;
    return p;
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  String _toStr(dynamic v, {String fallback = ''}) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? fallback : s;
  }

  /// Bounce non-driver users back — this screen is driver-only.
  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _chartCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _chartAnim = CurvedAnimation(
      parent: _chartCtrl,
      curve: Curves.easeOutCubic,
    );
    _loadHideEarnings();
    _fetchEarnings();
    _fetchPayoutData();
    _fetchPayoutMethods();
  }

  Future<void> _fetchEarnings() async {
    final period = _periodKeys[_selectedPeriod];
    final isMonth = period == 'month';
    final monthSuffix = isMonth
        ? '_${_selectedMonth.year}-${_selectedMonth.month.toString().padLeft(2, '0')}'
        : '';
    final cacheKey = 'driver_earnings_$period$monthSuffix';

    // Cache-first, but only from the stretch of time it describes.
    //
    // The cache was written with no date on it. A figure captioned "Today"
    // survived into the next day, and the next week's into the week after —
    // so the first thing a driver saw every morning was yesterday's total
    // under today's label, and it stayed there until a round trip came back
    // to correct it. On no signal it never did.
    //
    // The day is enough of a key for all four periods: a week, a month and a
    // year all roll over on some day, and a cache that is refused a day
    // early costs one fetch.
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    final cachedDay = prefs.getString('${cacheKey}_day');
    if (cached != null && cachedDay == _localDayKey() && _loading) {
      try {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        _applyEarningsData(data);
      } catch (_) {}
    }

    setState(() {
      _loading = true;
      _earningsError = null;
    });
    try {
      final data = await ApiService.getDriverEarnings(
        period: period,
        month: isMonth ? _selectedMonth : null,
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      _applyEarningsData(data);
      _chartCtrl.forward(from: 0);
      // Update cache
      prefs.setString(cacheKey, jsonEncode(data));
      // Stamped with the day it describes, so tomorrow cannot read
      // it as its own.
      prefs.setString('${cacheKey}_day', _localDayKey());
    } catch (e) {
      debugPrint('[Earnings] _fetchEarnings error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _earningsError = S.of(context).couldNotLoadEarnings;
      });
    }
  }

  /// The driver's current local date, as a key the cache is compared
  /// against. Local rather than UTC: their day turns over at their
  /// midnight, which is when the figure captioned "Today" should reset.
  String _localDayKey() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}'
        '-${d.day.toString().padLeft(2, '0')}';
  }

  void _applyEarningsData(Map<String, dynamic> data) {
    setState(() {
      _total = _toDouble(data['total']);
      _tripsCount = _toInt(data['trips_count']);
      _onlineHours = _toDouble(data['online_hours']);
      _tipsTotal = _toDouble(data['tips_total']);
      _ridesRejected = _toInt(data['rides_rejected']);

      final rawDaily = data['daily_earnings'];
      _dailyEarnings = rawDaily is List
        ? rawDaily.map((e) => _toDouble(e)).toList()
        : [0, 0, 0, 0, 0, 0, 0];
      if (_dailyEarnings.isEmpty) {
      _dailyEarnings = [0, 0, 0, 0, 0, 0, 0];
      }

      final rawLabels = data['day_labels'];
      _dayLabels = rawLabels is List
        ? rawLabels.map((e) => _toStr(e, fallback: '-')).toList()
        : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

      // The transactions list is not parsed any more — the Recent
      // Activity section it fed has been removed from this screen.
      _loading = false;
    });
  }

  Future<void> _fetchPayoutData() async {
    // Two independent requests, awaited independently. They used to share a
    // `Future.wait` inside one try, so the moment `getDriverCashouts` began
    // throwing on HTTP errors a failed history would also throw away a
    // perfectly good balance — the headline number on the screen.
    try {
      final info = await ApiService.getNextPayoutDate();
      if (!mounted) return;
      setState(() {
        _pendingBalance = (info['pending_balance'] as num?)?.toDouble() ?? 0.0;
        _stripeConnected = info['stripe_connected'] as bool? ?? false;
        final raw = info['next_payout_date'] as String?;
        if (raw != null) _nextPayoutDate = DateTime.tryParse(raw);
      });
    } catch (e) {
      debugPrint('[Earnings] next-payout-date error: $e');
    }
    try {
      final history = await ApiService.getDriverCashouts();
      if (!mounted) return;
      setState(() => _cashoutHistory = history);
    } catch (e) {
      // Logged, not shown. The payout block degrades to zeros on its own
      // and the headline figure carries its own error line — a second
      // message about a second request is noise on a screen the driver
      // opened to read one number.
      debugPrint('[Earnings] _fetchPayoutData error: $e');
    }
  }

  Future<void> _fetchPayoutMethods() async {
    try {
      final methods = await ApiService.getPayoutMethods().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _hasPayoutMethod = methods.isNotEmpty;
      });
    } catch (e) {
      debugPrint('[Earnings] _fetchPayoutMethods error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _chartCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      _chartCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chartCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      // Stacked, so the balance bar can sit over the scroll instead of at
      // the end of it. The list gets bottom padding to match — see the
      // spacer at the foot of the column.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App bar ──
          SliverAppBar(
            backgroundColor: neuBase,
            pinned: true,
            expandedHeight: 110,
            leading: IconButton(
              icon: Container(
                width: 38,
                height: 38,
                decoration: neuBox(radius: 19),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            centerTitle: true,
            title: Text(
              s.earningsTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Period: Day / Week / Month ──
                  _periodPill(),
                  const SizedBox(height: 14),
                  _periodLabel(),
                  const SizedBox(height: 18),

                  // ── The figure ──
                  _heroAmount(),
                  const SizedBox(height: 22),

                  // ── The chart ──
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                    decoration: neuBox(radius: 22),
                    child: ListenableBuilder(
                      listenable: _chartAnim,
                      builder: (ctx, child) => _buildBarChart(),
                    ),
                  ),
                  const SizedBox(height: 26),

                  // ── Stats ──
                  _sectionLabel(S.of(context).earningsYourStats),
                  const SizedBox(height: 12),
                  _statsRail(),
                  const SizedBox(height: 26),

                  // ── Actions ──
                  _sectionLabel(S.of(context).earningsActions),
                  const SizedBox(height: 12),
                  _actionsCard(),
                  const SizedBox(height: 20),

                  // The auto-payout card keeps its place under the actions:
                  // it is a statement of when money moves, not something to
                  // press, so it does not belong in a list of controls.
                  _buildNextPayoutCard(),
                  const SizedBox(height: 28),


                  // The Recent Activity list is gone from this screen.
                  //
                  // It was a scroll of every fare, each one a street
                  // address and a UTC timestamp printed raw, under a
                  // page whose job is to answer how much and when it
                  // arrives. The figures above say the how much; the
                  // per-trip detail belongs with the trips.

                  // Room for the pinned balance bar, so the last row is
                  // reachable rather than parked underneath it.
                  const SizedBox(height: 104),
                ],
              ),
            ),
          ),
        ],
      ),
          _stickyFooter(),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  THE REBUILT BODY
  // ═══════════════════════════════════════════════════════════════════

  /// Today / Week / Month / Year, in a sunken track with the live one
  /// raised in gold.
  ///
  /// Year draws twelve months rather than seven days. The chart takes
  /// whatever list it is handed and labels the columns underneath, so the
  /// two shapes need no branch here — see the backend, which fills the same
  /// two keys with months when the period is a year.
  Widget _periodPill() {
    final s = S.of(context);
    final labels = [
      s.earningsPeriodDay,
      s.earningsPeriodWeek,
      s.earningsPeriodMonth,
      s.earningsPeriodYear,
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: neuBox(radius: 22, pressed: true),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_selectedPeriod == i) return;
                  HapticService.selectionClick();
                  setState(() {
                    _selectedPeriod = i;
                    // Month always opens on the current month.
                    if (i == 2) _selectedMonth = DateTime.now();
                  });
                  _fetchEarnings();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: i == _selectedPeriod ? _gold : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: i == _selectedPeriod
                        ? [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.28),
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: i == _selectedPeriod
                          ? neuBase
                          : Colors.white.withValues(alpha: 0.38),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Which stretch of time the figure covers, spelled out.
  ///
  /// Month has left/right arrows so the driver can look at any past month.
  /// The right arrow is only live when there is a future month to move to.
  Widget _periodLabel() {
    final now = DateTime.now();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String text;
    switch (_selectedPeriod) {
      case 0:
        text = '${months[now.month - 1]} ${now.day}';
        break;
      case 1:
        // The week the backend reports: the last seven days ending today.
        final from = now.subtract(const Duration(days: 6));
        text = '${months[from.month - 1]} ${from.day} — '
            '${months[now.month - 1]} ${now.day}';
        break;
      case 2:
        text = '${months[_selectedMonth.month - 1]} ${_selectedMonth.year}';
        break;
      default:
        text = '${now.year}';
    }

    final label = Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
      ),
    );

    if (_selectedPeriod != 2) return Center(child: label);

    final canGoNext = _selectedMonth.year < now.year ||
        (_selectedMonth.year == now.year && _selectedMonth.month < now.month);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _shiftMonth(-1),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              Icons.chevron_left_rounded,
              color: Colors.white.withValues(alpha: 0.55),
              size: 20,
            ),
          ),
        ),
        label,
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canGoNext ? () => _shiftMonth(1) : null,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              Icons.chevron_right_rounded,
              color: canGoNext
                  ? Colors.white.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.18),
              size: 20,
            ),
          ),
        ),
      ],
    );
  }

  void _shiftMonth(int delta) {
    HapticService.selectionClick();
    setState(() {
      _selectedMonth = DateTime(
        _selectedMonth.year,
        _selectedMonth.month + delta,
      );
    });
    _fetchEarnings();
  }

  /// The number, at the size the screen is opened for.
  Widget _heroAmount() {
    final s = S.of(context);
    if (_loading && _total == 0) {
      return const SizedBox(
        height: 74,
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(color: _gold, strokeWidth: 2.4),
          ),
        ),
      );
    }
    final whole = _total.floor();
    final cents = ((_total - whole) * 100).round().toString().padLeft(2, '0');
    return Column(
      children: [
        // Always shown. The switch below covers the chip on the map, not
        // the page the driver opened to read this number.
        RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '\$$whole',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 46,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.4,
                    fontFamily: 'Poppins',
                  ),
                ),
                TextSpan(
                  text: '.$cents',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 46,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.4,
                    fontFamily: 'Poppins',
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          // The failure has to say so. The old body had a place for this
          // message and the rewrite did not, which would have left a driver
          // reading "$0.00 · no earnings yet" when the truth is that the
          // request did not come back.
          _earningsError ??
              (_total <= 0
                  ? s.earningsNoneYet
                  : '$_tripsCount ${s.tripsLabel.toLowerCase()} · '
                      '${s.earningsOnlineTime(_onlineHours.floor(), ((_onlineHours - _onlineHours.floor()) * 60).round())}'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _earningsError != null
                ? const Color(0xFFCC3333)
                : Colors.white.withValues(alpha: 0.38),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      );

  /// Three cards that scroll sideways, as in the reference.
  Widget _statsRail() {
    final s = S.of(context);
    final perHour = _onlineHours > 0 ? _total / _onlineHours : 0.0;
    return SizedBox(
      height: 118,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          _statCard(
            icon: Icons.attach_money_rounded,
            title: s.earningsStatsCard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statBig('\$${perHour.toStringAsFixed(2)}'),
                const SizedBox(height: 3),
                _statNote('${s.earningsPerOnlineHour}\n${s.earningsExcludingTips}'),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _statCard(
            icon: Icons.local_taxi_rounded,
            title: s.earningsDrivingCard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statRow(s.earningsRidesCompleted, '$_tripsCount'),
                _statRow(s.earningsRidesRejected, '$_ridesRejected'),
                _statRow(
                  s.online,
                  s.earningsOnlineTime(
                    _onlineHours.floor(),
                    ((_onlineHours - _onlineHours.floor()) * 60).round(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _statCard(
            icon: Icons.volunteer_activism_rounded,
            title: s.earningsTipsCard,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statBig('\$${_tipsTotal.toStringAsFixed(2)}'),
                const SizedBox(height: 3),
                _statNote(s.earningsFromTrips(_tripsCount)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Container(
      width: 172,
      padding: const EdgeInsets.all(14),
      decoration: neuBox(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: neuBox(radius: 7, pressed: true),
                child: Icon(icon, size: 12, color: _gold),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _statBig(String v) => Text(
        v,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      );

  Widget _statNote(String v) => Text(
        v,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.38),
          fontSize: 11,
          height: 1.25,
        ),
      );

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              k,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.38),
                fontSize: 11.5,
              ),
            ),
            Text(
              v,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );

  /// One list of controls, hairline-separated.
  ///
  /// Payout methods appears once here. It used to be drawn twice on this
  /// screen — a "Configure Payments" button in the balance block and the
  /// Stripe Connect button right underneath it, both saying the same words
  /// and both opening the same place.
  Widget _actionsCard() {
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: neuBox(radius: 20),
      child: Column(
        children: [
          _actionRow(
            icon: _hideEarnings
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded,
            label: s.earningsHideMine,
            sub: s.earningsHideMineDesc,
            trailing: _hideSwitch(),
            onTap: _toggleHideEarnings,
          ),
          _hairline(),
          _actionRow(
            icon: Icons.receipt_long_rounded,
            label: s.earningsPayoutHistory,
            sub: _cashoutHistory.isEmpty
                ? null
                : '${_cashoutHistory.length}',
            trailing: _chevron(),
            onTap: () {
              HapticService.selectionClick();
              _showCashoutHistorySheet();
            },
          ),
          _hairline(),
          _actionRow(
            icon: Icons.account_balance_wallet_rounded,
            label: s.earningsPayoutMethods,
            sub: s.earningsPayoutMethodsDesc,
            trailing: _chevron(),
            onTap: () {
              HapticService.mediumImpact();
              _openPayoutMethodsScreen();
            },
          ),
          // The Stripe Connect onboarding button used to sit here, and the
          // reason it can go is that it was never the only way in.
          // PayoutMethodsScreen adds a bank account and a debit card itself
          // through the native SDK — collectBankAccountToken and createToken
          // — so the row above is a complete path to getting paid. Two
          // buttons a line apart, both captioned about configuring payments,
          // were describing one thing.
        ],
      ),
    );
  }

  Widget _hairline() =>
      Divider(height: 1, color: Colors.white.withValues(alpha: 0.05));

  Widget _chevron() => Icon(
        Icons.chevron_right_rounded,
        color: Colors.white.withValues(alpha: 0.3),
        size: 20,
      );

  Widget _actionRow({
    required IconData icon,
    required String label,
    String? sub,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.6)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _hideSwitch() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: 42,
      height: 24,
      decoration: BoxDecoration(
        color: _hideEarnings ? _gold.withValues(alpha: 0.22) : neuPressed,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            offset: const Offset(2, 2),
            blurRadius: 5,
            spreadRadius: -2,
          ),
        ],
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment:
            _hideEarnings ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hideEarnings
                ? _gold
                : Colors.white.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }

  /// Balance and the one button that moves it, always in reach.
  ///
  /// Pinned rather than placed in the scroll. Cashing out is the reason a
  /// driver opens this screen with any urgency, and it used to sit halfway
  /// down a page that grows with every trip they take.
  Widget _stickyFooter() {
    final s = S.of(context);
    // Two buttons in one place, and only one of them can ever be dim.
    //
    // Which one it is comes from whether a payout destination exists, not
    // from the balance: a driver who has not set one up is asked to, and a
    // driver who has is offered the cash-out. Before this, both states were
    // folded into a single `hasMethod && balance > 0`, so a driver with no
    // card at all saw "Configure Payments" drawn in the dimmed style of a
    // disabled control — an instruction that looked like it could not be
    // followed, on the one screen where following it is the whole point.
    //
    // Configure is always live, because it always leads somewhere. Cash out
    // dims only at a zero balance, which is the one case where the button
    // genuinely has nothing to do.
    final hasDestination = _hasPayoutMethod;
    final canCash = hasDestination && _pendingBalance > 0;
    final enabled = !hasDestination || canCash;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          12 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: neuBase.withValues(alpha: 0.96),
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '\$${_pendingBalance.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  s.earningsAvailable,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const Spacer(),
            GestureDetector(
              onTap: () {
                HapticService.mediumImpact();
                // No destination: send them to set one up. With one, and
                // money behind it: cash out. With one and nothing behind
                // it there is nowhere useful to go, so the tap does not
                // pretend otherwise.
                if (!hasDestination) {
                  _openPayoutMethodsScreen();
                } else if (canCash) {
                  _openCashOutScreen();
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                decoration: BoxDecoration(
                  color: enabled ? _gold : _gold.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: enabled
                      ? [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  hasDestination ? s.cashOut : s.configurePayments,
                  style: TextStyle(
                    color: enabled
                        ? neuBase
                        : Colors.white.withValues(alpha: 0.55),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The next payday, named as the day the scheduler actually runs.
  ///
  /// `toUtc()`, not `toLocal()`. The backend answers with Monday 02:00 UTC,
  /// which is Sunday 21:00 in Alabama — converting to local printed
  /// "Sun, Aug 9" on this card while the cash-out page, which does not
  /// convert, printed "08-10" for the very same instant. One date, two
  /// screens, two different days, and the one this card showed was a day
  /// the payout never runs on.
  String _formatPayoutDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final d = dt.toUtc();
    return '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
  }

  Widget _buildNextPayoutCard() {
    final hasDate = _nextPayoutDate != null;
    final dateLabel = hasDate ? _formatPayoutDate(_nextPayoutDate!) : '—';
    final pendingLabel = '\$${_pendingBalance.toStringAsFixed(2)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: neuBox(
        radius: 20,
        borderColor: _stripeConnected
            ? const Color(0xFF34A853).withValues(alpha: 0.35)
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: neuBox(radius: 22, pressed: true),
            child: Icon(
              _stripeConnected
                  ? Icons.schedule_rounded
                  : Icons.info_outline_rounded,
              color: _stripeConnected ? const Color(0xFF34A853) : _gold,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Next Auto-Payout',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _stripeConnected
                      ? dateLabel
                      : 'Configura tus pagos para recibir depositos',
                  style: TextStyle(
                    color: _stripeConnected ? Colors.white : Colors.white54,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Pending',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                pendingLabel,
                style: TextStyle(
                  color: _pendingBalance > 0 ? _gold : Colors.white38,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCashoutHistory() {
    return [
      const Text(
        'Payout History',
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 14),
      // Failed rows are money that never moved — the amount is still in
      // the balance shown above, so listing it here as a payout counted it
      // twice, in orange, as if it were on its way.
      ..._cashoutHistory
          .where((c) => c['status'] != 'failed')
          .take(8)
          .map((c) {
        // The NET, matching the cash-out page. This showed the gross, so
        // one instant cashout appeared as two different numbers on two
        // screens a tap apart.
        final amount = (c['net_amount'] as num?)?.toDouble() ??
            (c['amount'] as num?)?.toDouble() ??
            0.0;
        final status = c['status'] as String? ?? 'pending';
        final rawDate = c['created_at'] as String?;
        final parsedDate = rawDate == null ? null : DateTime.tryParse(rawDate);
        // UTC for the weekly run, local for a cash-out the driver made —
        // same rule as the cash-out page, for the same reason.
        final date = parsedDate == null
            ? null
            : (c['method'] == 'instant'
                ? parsedDate.toLocal()
                : parsedDate.toUtc());
        final dateStr = date != null ? _formatPayoutDate(date) : '—';
        // "scheduled" is out of the platform and on Stripe's daily sweep —
        // done, not pending.
        final isCompleted = status == 'completed' || status == 'scheduled';
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: neuBox(radius: 16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: neuBox(radius: 19, pressed: true),
                child: Icon(
                  isCompleted
                      ? Icons.check_circle_rounded
                      : Icons.hourglass_top_rounded,
                  color: isCompleted
                      ? const Color(0xFF34A853)
                      : Colors.orange,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCompleted
                          ? S.of(context).cashoutDeposited
                          : S.of(context).cashoutStatusProcessing,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      dateStr,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '\$${amount.toStringAsFixed(2)}',
                style: TextStyle(
                  color: isCompleted ? const Color(0xFF34A853) : Colors.orange,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        );
      }),
      const SizedBox(height: 14),
    ];
  }

  Widget _buildBarChart() {
    final count = _dailyEarnings.length;
    if (count == 0) return const SizedBox.shrink();
    // Index of the best day — its bar gets the gold gradient.
    int maxIdx = 0;
    for (var i = 0; i < count; i++) {
      if (_dailyEarnings[i] > _dailyEarnings[maxIdx]) maxIdx = i;
    }
    final hasEarnings = _dailyEarnings.any((v) => v > 0);
    if (_selectedPeriod == 2) {
      return _buildMonthBarChart(count, maxIdx, hasEarnings);
    }
    return _buildCompactBarChart(count, maxIdx, hasEarnings);
  }

  bool _isBarToday(int index) {
    final now = DateTime.now();
    if (_selectedPeriod == 2) {
      return _selectedMonth.year == now.year &&
          _selectedMonth.month == now.month &&
          index + 1 == now.day;
    }
    return index == now.weekday - 1;
  }

  /// The seven-day chart used for Today / Week / Year.
  Widget _buildCompactBarChart(int count, int maxIdx, bool hasEarnings) {
    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(count, (i) {
          final val = _dailyEarnings[i];
          final h = (_maxDay > 0)
              ? (val / _maxDay) * 140 * _chartAnim.value
              : 0.0;
          final isMax = hasEarnings && i == maxIdx;
          final isToday = _isBarToday(i);
          return Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    val > 0
                        ? '\$${val.toStringAsFixed(2)}'
                        : '\$0',
                    maxLines: 1,
                    style: TextStyle(
                      color: val > 0
                          ? _gold.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.22),
                      fontSize: 10,
                      fontWeight: val > 0 ? FontWeight.w700 : FontWeight.w500,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  height: h < 4 ? 4 : h,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    gradient: isMax
                        ? const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFFF5D990), Color(0xFFE8C547)],
                          )
                        : null,
                    color: isMax
                        ? null
                        : Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: isMax
                        ? [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.35),
                              blurRadius: 10,
                            ),
                          ]
                        : [],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  i < _dayLabels.length ? _dayLabels[i] : '',
                  style: TextStyle(
                    color: isToday ? Colors.white : Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// The Month chart: every day of the selected month as a scrollable bar.
  Widget _buildMonthBarChart(int count, int maxIdx, bool hasEarnings) {
    const barWidth = 24.0;
    return SizedBox(
      height: 180,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: SizedBox(
          width: count * barWidth,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(count, (i) {
              final val = _dailyEarnings[i];
              final h = (_maxDay > 0)
                  ? (val / _maxDay) * 140 * _chartAnim.value
                  : 0.0;
              final isMax = hasEarnings && i == maxIdx;
              final isToday = _isBarToday(i);
              return SizedBox(
                width: barWidth,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Only label days that earned; 31 '$0' labels crowd the
                    // month view without adding information.
                    if (val > 0)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '\$${val.toStringAsFixed(2)}',
                          maxLines: 1,
                          style: TextStyle(
                            color: _gold.withValues(alpha: 0.85),
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      )
                    else
                      const SizedBox(height: 12),
                    const SizedBox(height: 4),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 600),
                      height: h < 3 ? 3 : h,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        gradient: isMax
                            ? const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xFFF5D990), Color(0xFFE8C547)],
                              )
                            : null,
                        color: isMax
                            ? null
                            : Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: isMax
                            ? [
                                BoxShadow(
                                  color: _gold.withValues(alpha: 0.35),
                                  blurRadius: 10,
                                ),
                              ]
                            : [],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      i < _dayLabels.length ? _dayLabels[i] : '',
                      style: TextStyle(
                        color: isToday ? Colors.white : Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }



  /// A full page rather than a sheet: cashing out is the whole task, and
  /// the auto-transfer date above the button is something the driver reads
  /// and decides on, not a detail to skim on a half-height card.
  void _openCashOutScreen() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => _CashOutScreen(
              available: _pendingBalance,
              nextPayoutDate: _nextPayoutDate,
              onCashedOut: _fetchEarnings,
            ),
          ),
        )
        // The balance changed under us if they went through with it, and
        // the eligibility window may have moved either way.
        .then((_) {
          if (!mounted) return;
          _fetchPayoutData();
        });
  }

  void _openPayoutMethodsScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PayoutMethodsScreen()),
    ).then((_) {
      // Refresh payout method status when returning
      _fetchPayoutMethods();
      _fetchPayoutData();
    });
  }
}

// ═══════════════════════════════════════════════════════════════════
//  CASH OUT — a page, not a sheet
//
//  One balance, the day it empties on its own, and one button. It used to
//  be a bottom sheet offering a choice between a free weekly ACH and an
//  instant card payout; there is no choice left to make, so a half-height
//  sheet asking the driver to pick from a list of one was the wrong shape.
//
//  The line above the button is the part a driver actually plans around:
//  the balance goes to zero by itself every Monday, and knowing which
//  Monday is what tells them whether cashing out early is worth 1.5%.
// ═══════════════════════════════════════════════════════════════════

class _CashOutScreen extends StatefulWidget {
  final double available;

  /// The next automatic weekly transfer, straight from
  /// `GET /drivers/payouts/next-date`. Null when that call failed — the
  /// screen falls back to the next Monday rather than dropping the line,
  /// because the date is the reason this page has a line at all.
  final DateTime? nextPayoutDate;
  final VoidCallback onCashedOut;

  const _CashOutScreen({
    required this.available,
    required this.nextPayoutDate,
    required this.onCashedOut,
  });

  @override
  State<_CashOutScreen> createState() => _CashOutScreenState();
}

class _CashOutScreenState extends State<_CashOutScreen> {
  static const _gold = Color(0xFFE8C547);

  // Local mirrors of the backend constants — the backend re-validates all
  // of them, but the UI needs them to decide what to draw without a second
  // round-trip. See INSTANT_* in backend/routers/drivers.py.
  static const double _instantFeeRate = 0.015;
  static const double _instantFeeMin = 0.50;
  static const double _instantMinAmount = 50.0;

  bool _loadingEligibility = true;
  bool _instantEnabled = false;
  String? _ineligibleReason;
  int _daysRemaining = 0;
  bool _submitting = false;

  List<Map<String, dynamic>> _history = const [];
  bool _loadingHistory = true;
  bool _historyFailed = false;
  bool _eligibilityFailed = false;

  @override
  void initState() {
    super.initState();
    _loadEligibility();
    _loadHistory();
  }

  /// Past payouts, both kinds.
  ///
  /// Fetched here rather than handed down from earnings so the list is
  /// current: a driver arrives on this page precisely when they are
  /// thinking about money moving, and the parent's copy can be minutes old.
  Future<void> _loadHistory() async {
    List<Map<String, dynamic>>? rows;
    try {
      rows = await ApiService.getDriverCashouts()
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      debugPrint('[Cashout] history unavailable: $e');
    }
    if (!mounted) return;
    setState(() {
      // An empty list because the request failed is NOT the same as an
      // empty list because the driver has never been paid, and the page
      // used to say the second thing for both. A driver with fourteen
      // payouts on a weak signal was told they had never been paid.
      _historyFailed = rows == null;
      if (rows != null) _history = rows;
      _loadingHistory = false;
    });
  }

  Future<void> _loadEligibility() async {
    Map<String, dynamic> e;
    try {
      e = await ApiService.getCashoutEligibility()
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // getCashoutEligibility already swallows its own errors, but a
      // timeout thrown here would otherwise leave the page spinning
      // forever with no button and no explanation.
      e = {'instant_enabled': false, 'reason': 'error'};
    }
    if (!mounted) return;
    setState(() {
      _loadingEligibility = false;
      _instantEnabled = e['instant_enabled'] == true;
      _ineligibleReason = e['reason'] as String?;
      _daysRemaining = (e['days_remaining'] as num?)?.toInt() ?? 0;
      // "We could not ask" is not "the answer is no". A dropped request
      // used to read as a permanent "Instant cash out is not available
      // right now", with nothing on the page offering to ask again — a
      // perfectly eligible driver on a weak signal was locked out until
      // they thought to leave and come back.
      _eligibilityFailed = e['reason'] == 'error';
    });
  }

  double get _fee {
    final raw = widget.available * _instantFeeRate;
    return raw < _instantFeeMin ? _instantFeeMin : double.parse(raw.toStringAsFixed(2));
  }

  double get _net => double.parse((widget.available - _fee).toStringAsFixed(2));

  bool get _belowMinimum => widget.available < _instantMinAmount;

  bool get _canConfirm =>
      !_submitting && !_loadingEligibility && _instantEnabled && !_belowMinimum;

  /// The Monday the balance empties itself on.
  ///
  /// Deliberately NOT converted to local time. The server sends Monday
  /// 02:00 UTC, which in Alabama is Sunday 21:00 — `toLocal()` would print
  /// the Sunday and the line would name a day the transfer never runs on.
  /// The UTC calendar day is the one the scheduler keys off, so that is
  /// the one to show.
  ///
  /// Snapped to Monday either way: this line's whole job is to name a
  /// Monday, and a server that ever answered with something else would
  /// otherwise put a Tuesday on screen with no way to notice.
  DateTime get _autoTransferDate {
    final given = widget.nextPayoutDate;
    if (given != null) {
      final d = DateTime(given.year, given.month, given.day);
      final drift = (DateTime.monday - d.weekday + 7) % 7;
      return d.add(Duration(days: drift));
    }
    // No answer from the server — the coming Monday, and the one after
    // when today is already Monday: today's run has either happened or is
    // hours away, and pointing at it is not something to plan around.
    final now = DateTime.now();
    final delta = (DateTime.monday - now.weekday + 7) % 7;
    return DateTime(now.year, now.month, now.day)
        .add(Duration(days: delta == 0 ? 7 : delta));
  }

  String _formatDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    // Day-first where the reader expects day-first. "04-21" is genuinely
    // ambiguous otherwise, and this line is a date the driver plans around.
    final es = Localizations.localeOf(context).languageCode == 'es';
    return es ? '$dd-$mm' : '$mm-$dd';
  }

  Future<void> _confirm() async {
    if (!_canConfirm) return;
    setState(() => _submitting = true);
    HapticService.mediumImpact();

    if (AppConfig.sandboxPayments) {
      await Future.delayed(const Duration(milliseconds: 1600));
      if (!mounted) return;
      widget.onCashedOut();
      _replaceWithSuccess(net: _net, cardBrand: 'Visa', cardLast4: '1084');
      return;
    }

    try {
      final result = await ApiService.requestCashout(
        amount: widget.available,
        method: 'instant',
      );
      if (!mounted) return;
      final transferId = result['transfer_id'] as String?;
      // Explicit flag from the backend, not inferred from the status
      // string: "processing" is also what a row looks like for the split
      // second between the funding transfer and the instant payout.
      final queued = result['queued'] == true;
      // Distinct from `queued`: the funding transfer got no definitive
      // answer, so whether the money moved is unknown. The balance is
      // already claimed either way, which is why this cannot be reported
      // as a plain failure.
      final uncertain = result['uncertain'] == true;
      final stripeErr = result['stripe_error'] as String?;

      if (transferId != null || queued || uncertain) {
        widget.onCashedOut();
        final netAmt = (result['net_amount'] as num?)?.toDouble() ?? _net;
        if (uncertain) {
          _snack(S.of(context).cashoutUncertain, Colors.orange);
          Navigator.maybeOf(context)?.pop();
          return;
        }
        if (queued && transferId == null) {
          // The money left the platform but the instant leg did not fire.
          // Saying "arrived instantly" here would be a lie the driver
          // discovers by refreshing their bank app.
          _snack(S.of(context).cashoutQueuedInstead, _gold);
          Navigator.maybeOf(context)?.pop();
          return;
        }
        _replaceWithSuccess(
          net: netAmt,
          cardBrand: result['card_brand'] as String?,
          cardLast4: result['card_last4'] as String?,
        );
        return;
      }

      setState(() => _submitting = false);
      debugPrint('[Cashout] no transfer id, stripe_error=$stripeErr');
      _snack(S.of(context).cashoutFailed, Colors.orange);
    } on TimeoutException catch (_) {
      // The request outlived the client, which is NOT the same as failing.
      // The backend claims the balance before it calls Stripe, so a cash-out
      // that actually went through has already moved the money — telling the
      // driver it failed would send them to tap again on a balance that is
      // already spent. Refresh what we can and say honestly that we do not
      // know yet.
      if (!mounted) return;
      setState(() => _submitting = false);
      debugPrint('[Cashout] request timed out — outcome unknown');
      widget.onCashedOut();
      _snack(S.of(context).cashoutUncertain, Colors.orange);
      // Leave, like the `uncertain` branch does. `widget.available` is
      // fixed at construction, so staying here would keep the old balance
      // under the driver's nose with a live button — and if the cash-out
      // did go through, that number is now wrong and the button would
      // spend money they no longer have. Popping hands control back to
      // earnings, whose `.then` re-reads the real balance.
      Navigator.maybeOf(context)?.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      debugPrint('[Cashout] error: $e');
      _snack(_errorMessage(e, S.of(context)), Colors.red);
    }
  }

  /// Turn a backend refusal into something the driver can act on.
  ///
  /// The endpoint's 400s are all written for a person to read, so the last
  /// resort is the server's own sentence rather than a generic "contact
  /// support" — a driver told "finish setting up your payouts" knows what
  /// to do; one told "try again or contact support" does not. The matches
  /// are on stable fragments of those messages, and each maps to a
  /// localized string so the driver reads it in their own language.
  String _errorMessage(Object e, S s) {
    if (e is! ApiException) return s.cashoutFailed;
    final raw = e.message;
    if (raw.contains('Insufficient')) return s.cashoutInsufficient;
    if (raw.contains('minimum of')) {
      return s.cashoutBelowMinimum('\$${_instantMinAmount.toStringAsFixed(0)}');
    }
    if (raw.contains('Payouts are not set up')) return s.cashoutNoStripeAccount;
    if (raw.contains('balance is untouched')) return s.cashoutNotStarted;
    if (raw.contains('no longer available')) return s.cashoutUnavailable;
    if (raw.contains('not available') || raw.contains('coming soon')) {
      return s.cashoutUnavailable;
    }
    return raw.isNotEmpty ? raw : s.cashoutFailed;
  }

  /// Replace, not push: the cash-out page has done its job and there is
  /// nothing to come back to. Popping off the success screen should land
  /// on earnings, with the new balance already fetched.
  void _replaceWithSuccess({
    required double net,
    String? cardBrand,
    String? cardLast4,
  }) {
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    nav.pushReplacement(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => _CashoutSuccessScreen(
          netAmount: net,
          instant: true,
          cardBrand: cardBrand,
          cardLast4: cardLast4,
        ),
        transitionDuration: const Duration(milliseconds: 320),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Why the button is dim, in one line under it.
  ///
  /// Null when the button is live — a page that explains itself when there
  /// is nothing to explain reads as a warning.
  String? _blockedReason(S s) {
    if (_loadingEligibility) return null;
    if (widget.available <= 0) return s.cashoutNothingToWithdraw;
    if (!_instantEnabled) {
      switch (_ineligibleReason) {
        case 'coming_soon':
          return s.cashoutComingSoon;
        case 'no_debit_card':
          return s.cashoutNeedCard;
        case 'cooldown':
          return s.cashoutCardVerifying(_daysRemaining);
        default:
          return s.cashoutUnavailable;
      }
    }
    if (_belowMinimum) {
      return s.cashoutBelowMinimum('\$${_instantMinAmount.toStringAsFixed(0)}');
    }
    return null;
  }

  // ── History ──────────────────────────────────────────────────────
  //
  // Two groups, split by whether the money has landed yet, because those
  // are two different questions: "did my request go through" and "has it
  // arrived". A single reverse-chronological list answers neither without
  // the driver reading every row.
  //
  // Failed rows appear in neither. A failed cashout never left the
  // platform and its amount is still sitting in the balance at the top of
  // this same page — a line saying it did not happen would be the only
  // thing on the screen contradicting the number above it.
  bool _isInstant(Map<String, dynamic> row) => row['method'] == 'instant';

  /// The money is out of the platform and on its way, by either route.
  ///
  /// "completed" is an instant payout Stripe accepted; "scheduled" is one
  /// riding the automatic daily payout because the instant leg did not
  /// fire, plus every legacy free cash-out. Both are finished as far as
  /// this app is concerned — neither is still waiting on us — so both
  /// belong under "Sent". Only a row we are still working on stays above.
  bool _hasLanded(Map<String, dynamic> row) =>
      row['status'] == 'completed' || row['status'] == 'scheduled';

  List<Map<String, dynamic>> get _initiated => _history
      .where((r) => r['status'] != 'failed' && !_hasLanded(r))
      .toList();

  List<Map<String, dynamic>> get _landed =>
      _history.where(_hasLanded).toList();

  /// The day to put on a row, which is not the same question for the two
  /// kinds of payout.
  ///
  /// An instant cashout happened when the driver tapped the button, so it
  /// belongs on their local calendar. The weekly run fires Monday 02:00
  /// UTC — Sunday evening in the Americas — so `toLocal()` dates it Sunday,
  /// one day before the Monday this very page names two inches higher. The
  /// scheduler keys off the UTC day, so that is the day a weekly row wears.
  String _rowDate(Map<String, dynamic> row) {
    final raw = row['created_at'] as String?;
    final parsed = raw == null ? null : DateTime.tryParse(raw);
    if (parsed == null) return '—';
    final d = _isInstant(row) ? parsed.toLocal() : parsed.toUtc();
    const en = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const es = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final month = (isEs ? es : en)[d.month - 1];
    return isEs ? '${d.day} $month' : '$month ${d.day}';
  }

  Widget _historySection(String title, String? note,
      List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.42),
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ...rows.map(_historyRow),
      ],
    );
  }

  Widget _historyRow(Map<String, dynamic> row) {
    final s = S.of(context);
    // What the driver actually received. The gross is what left their
    // balance; on an instant cashout the two differ by the fee, and the
    // number that belongs in a list of deposits is the one that arrived.
    final net = (row['net_amount'] as num?)?.toDouble() ??
        (row['amount'] as num?)?.toDouble() ??
        0.0;
    final label = _isInstant(row) ? s.cashoutRowInstant : s.cashoutRowWeekly;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showRowDetail(row),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _rowDate(row),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 15,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '\$${net.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.42),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.3),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  /// What the chevron opens: the numbers behind one row.
  ///
  /// Mostly it exists so the fee is visible somewhere after the fact — the
  /// success screen shows it once and is then gone, and a driver checking
  /// later why $161.72 arrived as $159.30 has nowhere else to look.
  void _showRowDetail(Map<String, dynamic> row) {
    final s = S.of(context);
    final gross = (row['amount'] as num?)?.toDouble() ?? 0.0;
    final fee = (row['fee'] as num?)?.toDouble() ?? 0.0;
    final net = (row['net_amount'] as num?)?.toDouble() ?? gross - fee;
    HapticService.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        decoration: const BoxDecoration(
          color: Color(0xFF14141A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  s.cashoutDetailTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 18),
                _detailRow(s.cashoutDetailDate, _rowDate(row)),
                _detailRow(s.cashoutDetailMethod,
                    _isInstant(row) ? s.cashoutRowInstant : s.cashoutRowWeekly),
                _detailRow(
                  s.cashoutDetailStatus,
                  _hasLanded(row)
                      ? s.cashoutStatusCompleted
                      : s.cashoutStatusProcessing,
                ),
                _detailRow(
                    s.cashoutDetailGross, '\$${gross.toStringAsFixed(2)}'),
                // Only when there was one. A weekly deposit showing
                // "Fee $0.00" invites the question of when it would not be.
                if (fee > 0)
                  _detailRow(s.cashoutDetailFee, '\$${fee.toStringAsFixed(2)}'),
                _detailRow(s.cashoutDetailNet, '\$${net.toStringAsFixed(2)}',
                    strong: true),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      s.gotIt,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: strong ? _gold : Colors.white,
              fontSize: 15,
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final blocked = _blockedReason(s);
    final needsCard = !_instantEnabled && _ineligibleReason == 'no_debit_card';
    final nothingYet =
        !_loadingHistory && _initiated.isEmpty && _landed.isEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Scrolls, and the balance sits at the top rather than in the
            // middle of the viewport: the history underneath it is the rest
            // of the page, and a centred block would push it below the fold
            // on every phone.
            ListView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(24, 52, 24, 40),
              children: [
                Text(
                  s.cashoutAvailableBalance,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '\$${widget.available.toStringAsFixed(2)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  s.cashoutAutoTransferOn(_formatDate(_autoTransferDate)),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.42),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _canConfirm ? _confirm : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: _gold.withValues(alpha: 0.28),
                      disabledForegroundColor:
                          Colors.black.withValues(alpha: 0.55),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: Text(
                      s.cashoutInstantButton,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // What it costs, or why it cannot run — never both, and
                // never nothing: the space under the button always carries
                // the one sentence that matters in this state.
                if (_loadingEligibility)
                  Center(
                    child: Container(
                      height: 16,
                      width: 140,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  )
                else
                  Text(
                    blocked ??
                        s.cashoutFeeLine(
                          '\$${_fee.toStringAsFixed(2)}',
                          '\$${_net.toStringAsFixed(2)}',
                        ),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                if (needsCard)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => const PayoutMethodsScreen(),
                          ),
                        );
                      },
                      child: Text(
                        s.cashoutAddCardAction,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                // The eligibility answer never arrived. Offer to ask again
                // rather than leaving "not available right now" standing as
                // if it were the server's verdict.
                if (_eligibilityFailed)
                  Center(
                    child: TextButton(
                      onPressed: () {
                        HapticService.selectionClick();
                        setState(() {
                          _loadingEligibility = true;
                          _eligibilityFailed = false;
                        });
                        _loadEligibility();
                      },
                      child: Text(
                        s.retry,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),

                // ── History ──
                _historySection(
                  s.cashoutInitiatedBy,
                  s.cashoutInitiatedNote,
                  _initiated,
                ),
                _historySection(
                  s.cashoutDeposited,
                  s.cashoutDepositedNote,
                  _landed,
                ),
                if (_historyFailed) ...[
                  const SizedBox(height: 36),
                  Center(
                    child: Column(
                      children: [
                        Text(
                          s.cashoutHistoryUnavailable,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: () {
                            HapticService.selectionClick();
                            setState(() {
                              _loadingHistory = true;
                              _historyFailed = false;
                            });
                            _loadHistory();
                          },
                          child: Text(
                            s.retry,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (nothingYet) ...[
                  const SizedBox(height: 40),
                  Text(
                    s.cashoutHistoryEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
            Positioned(
              top: 0,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 26),
                onPressed:
                    _submitting ? null : () => Navigator.of(context).pop(),
              ),
            ),
            // ── Processing ──
            //
            // Over the page rather than inside the button: the request goes
            // to Stripe and back and can take seconds, and a spinner in a
            // 56 pt button reads as a slow tap rather than as money moving.
            if (_submitting)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.92),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 54,
                        height: 54,
                        child: CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 3,
                        ),
                      ),
                      const SizedBox(height: 26),
                      Text(
                        s.cashoutProcessing,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        s.cashoutProcessingHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════
//  CASHOUT SUCCESS — Lyft-style full screen, Cruise gold theme
// ═══════════════════════════════════════════════════════════════════

class _CashoutSuccessScreen extends StatefulWidget {
  final double netAmount;
  final bool instant;
  final String? cardBrand;
  final String? cardLast4;

  const _CashoutSuccessScreen({
    required this.netAmount,
    required this.instant,
    this.cardBrand,
    this.cardLast4,
  });

  @override
  State<_CashoutSuccessScreen> createState() => _CashoutSuccessScreenState();
}

class _CashoutSuccessScreenState extends State<_CashoutSuccessScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _iconCtrl;
  late AnimationController _sparkleCtrl;
  late AnimationController _textCtrl;

  @override
  void initState() {
    super.initState();
    _iconCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _sparkleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    HapticService.mediumImpact();
    _iconCtrl.forward();
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _sparkleCtrl.repeat();
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _textCtrl.forward();
    });
  }

  @override
  void dispose() {
    _iconCtrl.dispose();
    _sparkleCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = widget.cardBrand ?? 'card';
    final last4 = widget.cardLast4 ?? '';
    final destination = last4.isNotEmpty
        ? '$brand ····$last4'
        : (widget.instant ? 'your debit card' : 'your bank account');

    final timing = widget.instant
        ? 'Funds should arrive in 30 minutes, but can take up to 1 day depending on your bank.'
        : 'Funds typically arrive in 1–2 business days.';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 180,
                      height: 180,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Sparkles — orbit around the icon
                          AnimatedBuilder(
                            animation: _sparkleCtrl,
                            builder: (_, __) {
                              return CustomPaint(
                                size: const Size(180, 180),
                                painter: _SparklePainter(_sparkleCtrl.value),
                              );
                            },
                          ),
                          // Bill stack with elastic pop
                          ScaleTransition(
                            scale: CurvedAnimation(
                              parent: _iconCtrl,
                              curve: Curves.elasticOut,
                            ),
                            child: const _GoldBillIcon(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    FadeTransition(
                      opacity: _textCtrl,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.15),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: _textCtrl,
                          curve: Curves.easeOutCubic,
                        )),
                        child: Column(
                          children: [
                            Text(
                              'Your \$${widget.netAmount.toStringAsFixed(2)} '
                              'transfer was initiated',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 14),
                            RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                                children: [
                                  const TextSpan(text: 'Your transfer to '),
                                  TextSpan(
                                    text: destination,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const TextSpan(text: ' is on its way. '),
                                  TextSpan(text: timing),
                                ],
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
            Positioned(
              left: 24,
              right: 24,
              bottom: 28,
              child: FadeTransition(
                opacity: _textCtrl,
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Got It',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoldBillIcon extends StatelessWidget {
  const _GoldBillIcon();

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFE8C547);
    const goldDeep = Color(0xFFC9A227);
    return SizedBox(
      width: 130,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Back bill (slightly rotated, deeper gold)
          Positioned(
            left: 28,
            top: 18,
            child: Transform.rotate(
              angle: 0.18,
              child: Container(
                width: 96,
                height: 60,
                decoration: BoxDecoration(
                  color: goldDeep,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black, width: 2),
                ),
              ),
            ),
          ),
          // Front bill
          Positioned(
            left: 14,
            top: 28,
            child: Container(
              width: 100,
              height: 62,
              decoration: BoxDecoration(
                color: gold,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black, width: 2),
              ),
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black, width: 2.2),
                  ),
                  child: const Center(
                    child: Text(
                      '\$',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Check badge (top-left)
          Positioned(
            left: -2,
            top: -2,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: gold,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black, width: 2.5),
              ),
              child: const Center(
                child: Icon(
                  Icons.check_rounded,
                  color: Colors.black,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparklePainter extends CustomPainter {
  final double progress; // 0..1, repeating
  _SparklePainter(this.progress);

  static const _gold = Color(0xFFE8C547);

  // (angle deg, radius factor, base size, phase offset 0..1)
  static const _stars = <List<double>>[
    [-15, 0.95, 8, 0.0],
    [40, 0.98, 6, 0.25],
    [110, 0.92, 7, 0.5],
    [200, 0.96, 5, 0.15],
    [255, 0.94, 7, 0.7],
    [320, 0.97, 6, 0.4],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final paint = Paint()..color = _gold;
    for (final s in _stars) {
      final angleRad = s[0] * 3.14159 / 180.0;
      final dx = center.dx + r * s[1] * (s[0] == 0 ? 0 : (1.0)) * _cos(angleRad);
      final dy = center.dy + r * s[1] * (s[0] == 0 ? 0 : (1.0)) * _sin(angleRad);
      final t = ((progress + s[3]) % 1.0);
      // Scale: pop in 0..0.4, hold 0.4..0.7, fade 0.7..1.0
      double scale;
      double opacity;
      if (t < 0.4) {
        scale = t / 0.4;
        opacity = (t / 0.4).clamp(0.0, 1.0);
      } else if (t < 0.7) {
        scale = 1.0;
        opacity = 1.0;
      } else {
        final f = (t - 0.7) / 0.3;
        scale = 1.0 - 0.3 * f;
        opacity = 1.0 - f;
      }
      paint.color = _gold.withValues(alpha: opacity * 0.95);
      _drawSparkle(canvas, Offset(dx, dy), s[2] * scale, paint);
    }
  }

  void _drawSparkle(Canvas canvas, Offset c, double size, Paint paint) {
    if (size <= 0.5) return;
    // Four-point star: vertical bar + horizontal bar with tapered ends.
    final path = Path()
      ..moveTo(c.dx, c.dy - size)
      ..lineTo(c.dx + size * 0.25, c.dy)
      ..lineTo(c.dx, c.dy + size)
      ..lineTo(c.dx - size * 0.25, c.dy)
      ..close()
      ..moveTo(c.dx - size, c.dy)
      ..lineTo(c.dx, c.dy - size * 0.25)
      ..lineTo(c.dx + size, c.dy)
      ..lineTo(c.dx, c.dy + size * 0.25)
      ..close();
    canvas.drawPath(path, paint);
  }

  double _cos(double rad) {
    // dart:math import is via the file's existing 'dart:math' import.
    return cos(rad);
  }

  double _sin(double rad) {
    return sin(rad);
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.progress != progress;
}
