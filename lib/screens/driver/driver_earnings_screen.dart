import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/api_service.dart';
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

  double get _maxDay {
    final m = _dailyEarnings.isEmpty ? 0.0 : _dailyEarnings.reduce(max);
    return m > 0 ? m : 1.0;
  }

  @override
  void initState() {
    super.initState();
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
  }

  Future<void> _fetchEarnings() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getDriverEarnings(
        period: _periodKeys[_selectedPeriod],
      );
      if (!mounted) return;
      setState(() {
        _total = (data['total'] as num?)?.toDouble() ?? 0.0;
        _tripsCount = (data['trips_count'] as num?)?.toInt() ?? 0;
        _onlineHours = (data['online_hours'] as num?)?.toDouble() ?? 0.0;
        _tipsTotal = (data['tips_total'] as num?)?.toDouble() ?? 0.0;
        _dailyEarnings =
            (data['daily_earnings'] as List<dynamic>?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            [0, 0, 0, 0, 0, 0, 0];
        _dayLabels =
            (data['day_labels'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        _transactions =
            (data['transactions'] as List<dynamic>?)
                ?.map((e) => Map<String, dynamic>.from(e as Map))
                .toList() ??
            [];
        _loading = false;
      });
      _chartCtrl.forward(from: 0);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _listCtrl.forward(from: 0);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
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
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 56, bottom: 16),
              title: Text(
                s.earningsTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
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
                  const SizedBox(height: 28),

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
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.1),
                        end: Offset.zero,
                      ).animate(_listAnim),
                      child: Column(
                        children: _transactions
                            .map((t) => _transactionTile(t))
                            .toList(),
                      ),
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
    IconData icon;
    Color iconColor;
    switch (t['type']) {
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
                  t['desc'] as String,
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
                  t['time'] as String,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '+\$${(t['amount'] as num).toStringAsFixed(2)}',
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
                    try {
                      await ApiService.requestCashout(amount: _total);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            S
                                .of(context)
                                .cashOutInitiated(_total.toStringAsFixed(2)),
                          ),
                          backgroundColor: _gold,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            S.of(context).cashOutFailed(e.toString()),
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
