import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../config/app_config.dart';
import '../../l10n/app_localizations.dart';

/// Full-featured earnings screen — fetches real data from the backend.
/// Falls back to empty state if API is unreachable.
class DriverEarningsScreen extends StatefulWidget {
  const DriverEarningsScreen({super.key});

  @override
  State<DriverEarningsScreen> createState() => _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends State<DriverEarningsScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  int _selectedPeriod = 1; // 0=Today, 1=This Week, 2=This Month
  final _periodKeys = ['today', 'week', 'month'];

  late AnimationController _chartCtrl;
  late Animation<double> _chartAnim;
  late AnimationController _listCtrl;
  late Animation<double> _listAnim;

  bool _loading = true;
  double _total = 0.0;
  int _tripsCount = 0;
  double _onlineHours = 0.0;
  double _tipsTotal = 0.0;
  List<double> _dailyEarnings = [0, 0, 0, 0, 0, 0, 0];
  List<String> _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  List<Map<String, dynamic>> _transactions = [];

  // Auto-payout data
  DateTime? _nextPayoutDate;
  double _pendingBalance = 0.0;
  bool _stripeConnected = false;
  List<Map<String, dynamic>> _cashoutHistory = [];

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
    _listCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _listAnim = CurvedAnimation(parent: _listCtrl, curve: Curves.easeOutCubic);
    _fetchEarnings();
    _fetchPayoutData();
  }

  Future<void> _fetchEarnings() async {
    final period = _periodKeys[_selectedPeriod];
    final cacheKey = 'driver_earnings_$period';

    // Cache-first: show last-known earnings instantly
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(cacheKey);
    if (cached != null && _loading) {
      try {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        _applyEarningsData(data);
      } catch (_) {}
    }

    setState(() => _loading = true);
    try {
      final data = await ApiService.getDriverEarnings(period: period);
      if (!mounted) return;
      _applyEarningsData(data);
      _chartCtrl.forward(from: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _listCtrl.forward(from: 0);
      });
      // Update cache
      prefs.setString(cacheKey, jsonEncode(data));
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _applyEarningsData(Map<String, dynamic> data) {
    setState(() {
      _total = _toDouble(data['total']);
      _tripsCount = _toInt(data['trips_count']);
      _onlineHours = _toDouble(data['online_hours']);
      _tipsTotal = _toDouble(data['tips_total']);

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

      final rawTx = data['transactions'];
      _transactions = rawTx is List
        ? rawTx
          .whereType<Map>()
          .map((e) => <String, dynamic>{
            'type': _toStr(e['type'], fallback: 'trip'),
            'desc': _toStr(e['desc'], fallback: 'Trip'),
            'time': _toStr(e['time'], fallback: 'Now'),
            'amount': _toDouble(e['amount']),
            })
          .toList()
        : [];
      _loading = false;
    });
  }

  Future<void> _fetchPayoutData() async {
    try {
      final results = await Future.wait([
        ApiService.getNextPayoutDate(),
        ApiService.getDriverCashouts(),
      ]);
      if (!mounted) return;
      final info = results[0] as Map<String, dynamic>;
      final history = results[1] as List<Map<String, dynamic>>;
      setState(() {
        _pendingBalance = (info['pending_balance'] as num?)?.toDouble() ?? 0.0;
        _stripeConnected = info['stripe_connected'] as bool? ?? false;
        _cashoutHistory = history;
        final raw = info['next_payout_date'] as String?;
        if (raw != null) _nextPayoutDate = DateTime.tryParse(raw);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _chartCtrl.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final periods = [s.today, s.thisWeek, s.thisMonth];
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App bar ──
          SliverAppBar(
            backgroundColor: _surface,
            pinned: true,
            expandedHeight: 110,
            leading: IconButton(
              icon: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                ),
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
                  // ── Total card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.18),
                          _gold.withValues(alpha: 0.06),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: _gold.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          periods[_selectedPeriod],
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _loading
                            ? const SizedBox(
                                height: 44,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    color: _gold,
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : Text(
                                '\$${_total.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -1,
                                ),
                              ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _miniStat('$_tripsCount', s.tripsStatLabel),
                            const SizedBox(width: 28),
                            _miniStat(
                              '${_onlineHours.toStringAsFixed(1)}h',
                              s.onlineStatLabel,
                            ),
                            const SizedBox(width: 28),
                            _miniStat(
                              '\$${_tipsTotal.toStringAsFixed(2)}',
                              s.tipsStatLabel,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Period selector ──
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: List.generate(3, (i) {
                        final sel = i == _selectedPeriod;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _selectedPeriod = i);
                              _fetchEarnings();
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: sel
                                    ? _gold.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(11),
                                border: sel
                                    ? Border.all(
                                        color: _gold.withValues(alpha: 0.3),
                                      )
                                    : null,
                              ),
                              child: Text(
                                periods[i],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: sel ? _gold : Colors.white38,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Weekly bar chart ──
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListenableBuilder(
                      listenable: _chartAnim,
                      builder: (ctx, child) => _buildBarChart(),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Cash Out ──
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        _showCashOutSheet();
                      },
                      icon: const Icon(Icons.account_balance_rounded, size: 20),
                      label: Text(
                        S.of(context).cashOut,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                        shadowColor: _gold.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Stripe Connect (Setup Payouts) ──
                  _StripeConnectButton(),

                  const SizedBox(height: 20),

                  // ── Next Auto-Payout card ──
                  _buildNextPayoutCard(),

                  const SizedBox(height: 28),

                  // ── Cashout history ──
                  if (_cashoutHistory.isNotEmpty) ...
                    _buildCashoutHistory(),

                  // ── Recent transactions ──
                  Text(
                    S.of(context).recentActivity,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FadeTransition(
                    opacity: _listAnim,
                    child: Column(
                        children: _transactions
                            .map((t) => _transactionTile(t))
                            .toList(),
                      ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatPayoutDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final d = dt.toLocal();
    return '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
  }

  Widget _buildNextPayoutCard() {
    final hasDate = _nextPayoutDate != null;
    final dateLabel = hasDate ? _formatPayoutDate(_nextPayoutDate!) : '—';
    final pendingLabel = '\$${_pendingBalance.toStringAsFixed(2)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _stripeConnected
              ? const Color(0xFF34A853).withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _stripeConnected
                  ? const Color(0xFF34A853).withValues(alpha: 0.15)
                  : _gold.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
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
                      : 'Connect Stripe to enable',
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
      ..._cashoutHistory.take(8).map((c) {
        final amount = (c['amount'] as num?)?.toDouble() ?? 0.0;
        final status = c['status'] as String? ?? 'pending';
        final rawDate = c['created_at'] as String?;
        DateTime? date;
        if (rawDate != null) date = DateTime.tryParse(rawDate)?.toLocal();
        final dateStr = date != null ? _formatPayoutDate(date) : '—';
        final isCompleted = status == 'completed';
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isCompleted
                      ? const Color(0xFF34A853).withValues(alpha: 0.15)
                      : Colors.orange.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
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
                      isCompleted ? 'Payout Sent' : 'Pending',
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
    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(count, (i) {
          final val = _dailyEarnings[i];
          final h = (_maxDay > 0)
              ? (val / _maxDay) * 140 * _chartAnim.value
              : 0.0;
          final isToday = i == DateTime.now().weekday - 1;
          return Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '\$${val.toInt()}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  height: h,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: isToday ? _gold : _gold.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: isToday
                        ? [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.3),
                              blurRadius: 8,
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

  Widget _miniStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _transactionTile(Map<String, dynamic> t) {
    final type = _toStr(t['type'], fallback: 'trip');
    final desc = _toStr(t['desc'], fallback: 'Trip');
    final time = _toStr(t['time'], fallback: 'Now');
    final amount = _toDouble(t['amount']);

    IconData icon;
    Color iconColor;
    switch (type) {
      case 'bonus':
        icon = Icons.bolt_rounded;
        iconColor = const Color(0xFFF5D990);
        break;
      case 'tip':
        icon = Icons.volunteer_activism_rounded;
        iconColor = const Color(0xFFE8C547);
        break;
      default:
        icon = Icons.directions_car_rounded;
        iconColor = _gold;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  desc,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  time,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '+\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Color(0xFFE8C547),
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  void _showCashOutSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(28),
          decoration: const BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.account_balance_rounded, color: _gold, size: 40),
              SizedBox(height: 16),
              Text(
                S.of(ctx).cashOut,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(ctx).availableBalance(_total.toStringAsFixed(2)),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.of(ctx).fundsTransferDesc,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    // Sandbox mode: simulate successful cashout
                    if (AppConfig.sandboxPayments) {
                      await Future.delayed(const Duration(milliseconds: 800));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '✅ ${S.of(context).cashOutInitiated(_total.toStringAsFixed(2))}',
                          ),
                          backgroundColor: _gold,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                      _fetchEarnings();
                      return;
                    }
                    try {
                      final result = await ApiService.requestCashout(amount: _total);
                      if (!mounted) return;
                      final transferId = result['transfer_id'] as String?;
                      final stripeErr = result['stripe_error'] as String?;
                      if (transferId != null) {
                        // Real Stripe transfer initiated
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '✅ ${S.of(context).cashOutInitiated(_total.toStringAsFixed(2))}',
                            ),
                            backgroundColor: _gold,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        );
                        _fetchEarnings();
                      } else if (stripeErr != null) {
                        // Transfer failed — show clean message, log raw error
                        debugPrint('Cashout Stripe error: $stripeErr');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text(
                              'Cashout could not be completed. Please try again or contact support.',
                            ),
                            backgroundColor: Colors.orange,
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        );
                      } else {
                        // No Stripe Connect — cashout pending manual processing
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text(
                              'Cashout requested. Set up Stripe payouts below to receive funds automatically.',
                            ),
                            backgroundColor: _gold,
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (!mounted) return;
                      debugPrint('Cashout error: $e');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            S.of(context).cashOutFailed('Please try again or contact support.'),
                          ),
                          backgroundColor: Colors.red,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    S.of(ctx).confirmCashOut,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  S.of(ctx).cancel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Stripe Connect Setup Payouts Button ──────────────────────────────────────
class _StripeConnectButton extends StatefulWidget {
  @override
  State<_StripeConnectButton> createState() => _StripeConnectButtonState();
}

class _StripeConnectButtonState extends State<_StripeConnectButton> {
  bool _loading = false;
  bool? _connected;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final s = await ApiService.getStripeConnectStatus();
      if (mounted) setState(() => _connected = s['connected'] == true);
    } catch (_) {}
  }

  Future<void> _startOnboarding() async {
    setState(() => _loading = true);
    try {
      final url = await ApiService.getStripeConnectLink();
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _checkStatus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_connected == true) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A3A2A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF34A853).withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded, color: Color(0xFF34A853), size: 20),
            SizedBox(width: 10),
            Text('Payouts Connected',
                style: TextStyle(
                    color: Color(0xFF34A853),
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
          ],
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton.icon(
        onPressed: _loading ? null : _startOnboarding,
        icon: _loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.account_balance_wallet_rounded, size: 20),
        label: Text(_loading ? 'Opening...' : 'Setup Payouts (Stripe)',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}
