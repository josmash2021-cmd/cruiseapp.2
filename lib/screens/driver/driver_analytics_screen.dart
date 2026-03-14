import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

// ═══════════════════════════════════════════════════════════════
//  CRUISE DRIVER — ANALYTICS / DRIVING TIME SCREEN
//  Full-featured: period selector, time chart, sessions, heatmap
// ═══════════════════════════════════════════════════════════════

class DriverAnalyticsScreen extends StatefulWidget {
  const DriverAnalyticsScreen({super.key});

  @override
  State<DriverAnalyticsScreen> createState() => _DriverAnalyticsScreenState();
}

class _DriverAnalyticsScreenState extends State<DriverAnalyticsScreen> {
  static const _gold = Color(0xFFD4A843);
  static const _bg = Color(0xFF0A0A0A);

  // ── API data ──
  double _todayEarnings = 0;
  double _weekEarnings = 0;
  double _monthEarnings = 0;
  int _todayTrips = 0;
  int _weekTrips = 0;
  int _monthTrips = 0;
  double _todayHours = 0;
  double _weekHours = 0;
  double _monthHours = 0;
  List<double> _dailyEarnings = List.filled(7, 0);
  List<String> _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  bool _loaded = false;

  // ── Period selector ──
  int _selectedPeriod = 0; // 0=Today, 1=Week, 2=Month

  // ── Simulated driving sessions ──
  late List<_Session> _sessions;

  // ── Hourly distribution (24 hours) ──
  late List<double> _hourlyActivity;

  @override
  void initState() {
    super.initState();
    _buildSessionData();
    _load();
  }

  void _buildSessionData() {
    final now = DateTime.now();
    _sessions = [
      _Session(
        start: now.subtract(const Duration(hours: 1, minutes: 30)),
        end: now,
        trips: 4,
        earnings: 42.50,
        miles: 28.3,
        isActive: true,
      ),
      _Session(
        start: DateTime(now.year, now.month, now.day, 6, 15),
        end: DateTime(now.year, now.month, now.day, 9, 45),
        trips: 7,
        earnings: 78.20,
        miles: 52.1,
      ),
      _Session(
        start: DateTime(now.year, now.month, now.day - 1, 17, 0),
        end: DateTime(now.year, now.month, now.day - 1, 22, 30),
        trips: 11,
        earnings: 134.75,
        miles: 89.6,
      ),
      _Session(
        start: DateTime(now.year, now.month, now.day - 1, 7, 30),
        end: DateTime(now.year, now.month, now.day - 1, 11, 0),
        trips: 6,
        earnings: 65.00,
        miles: 41.2,
      ),
      _Session(
        start: DateTime(now.year, now.month, now.day - 2, 14, 0),
        end: DateTime(now.year, now.month, now.day - 2, 20, 15),
        trips: 13,
        earnings: 156.30,
        miles: 98.7,
      ),
      _Session(
        start: DateTime(now.year, now.month, now.day - 3, 8, 0),
        end: DateTime(now.year, now.month, now.day - 3, 12, 30),
        trips: 8,
        earnings: 92.40,
        miles: 55.3,
      ),
    ];

    // Build hourly activity heatmap (simulated)
    final rng = math.Random(42);
    _hourlyActivity = List.generate(24, (h) {
      if (h >= 0 && h < 5) return rng.nextDouble() * 0.1;
      if (h >= 5 && h < 8) return 0.2 + rng.nextDouble() * 0.3;
      if (h >= 8 && h < 10) return 0.5 + rng.nextDouble() * 0.4;
      if (h >= 10 && h < 12) return 0.3 + rng.nextDouble() * 0.3;
      if (h >= 12 && h < 14) return 0.4 + rng.nextDouble() * 0.3;
      if (h >= 14 && h < 17) return 0.3 + rng.nextDouble() * 0.3;
      if (h >= 17 && h < 20) return 0.7 + rng.nextDouble() * 0.3;
      if (h >= 20 && h < 23) return 0.4 + rng.nextDouble() * 0.3;
      return 0.1 + rng.nextDouble() * 0.2;
    });
  }

  Future<void> _load() async {
    try {
      final today = await ApiService.getDriverEarnings(period: 'today');
      final week = await ApiService.getDriverEarnings(period: 'week');
      final month = await ApiService.getDriverEarnings(period: 'month');
      if (!mounted) return;
      setState(() {
        _todayEarnings = (today['total'] as num?)?.toDouble() ?? 0;
        _todayTrips = (today['trips_count'] as num?)?.toInt() ?? 0;
        _todayHours = (today['online_hours'] as num?)?.toDouble() ?? 0;
        _weekEarnings = (week['total'] as num?)?.toDouble() ?? 0;
        _weekTrips = (week['trips_count'] as num?)?.toInt() ?? 0;
        _weekHours = (week['online_hours'] as num?)?.toDouble() ?? 0;
        _monthEarnings = (month['total'] as num?)?.toDouble() ?? 0;
        _monthTrips = (month['trips_count'] as num?)?.toInt() ?? 0;
        _monthHours = (month['online_hours'] as num?)?.toDouble() ?? 0;
        final de = week['daily_earnings'];
        if (de is List && de.length == 7) {
          _dailyEarnings = de.map((e) => (e as num).toDouble()).toList();
        }
        final dl = week['day_labels'];
        if (dl is List && dl.length == 7) {
          _dayLabels = dl.map((e) => e.toString()).toList();
        }
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  // Current period getters
  double get _earnings => [_todayEarnings, _weekEarnings, _monthEarnings][_selectedPeriod];
  int get _trips => [_todayTrips, _weekTrips, _monthTrips][_selectedPeriod];
  double get _hours => [_todayHours, _weekHours, _monthHours][_selectedPeriod];
  String get _periodLabel => ['Today', 'This Week', 'This Month'][_selectedPeriod];

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
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
                  ),
                  const SizedBox(width: 12),
                  Text(
                    s.analyticsLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── Period selector ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: List.generate(3, (i) {
                  final labels = ['Today', 'Week', 'Month'];
                  final selected = _selectedPeriod == i;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedPeriod = i);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? _gold.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? _gold.withValues(alpha: 0.3)
                                : Colors.white.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            labels[i],
                            style: TextStyle(
                              color: selected
                                  ? _gold
                                  : Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: !_loaded
                  ? const Center(
                      child: CircularProgressIndicator(color: _gold),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // ── Summary hero card ──
                        _heroCard(),
                        const SizedBox(height: 20),

                        // ── Weekly earnings chart ──
                        _sectionTitle(s.weeklyChart),
                        const SizedBox(height: 12),
                        _barChart(),
                        const SizedBox(height: 24),

                        // ── Hourly heatmap ──
                        _sectionTitle('PEAK HOURS'),
                        const SizedBox(height: 12),
                        _hourlyHeatmap(),
                        const SizedBox(height: 24),

                        // ── Efficiency metrics ──
                        _sectionTitle('EFFICIENCY'),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _metricCard(
                                Icons.speed_rounded,
                                'Avg/Trip',
                                _trips > 0
                                    ? '\$${(_earnings / _trips).toStringAsFixed(2)}'
                                    : '\$0.00',
                                _gold,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _metricCard(
                                Icons.timer_outlined,
                                'Avg/Hour',
                                _hours > 0
                                    ? '\$${(_earnings / _hours).toStringAsFixed(2)}'
                                    : '\$0.00',
                                const Color(0xFF4CAF50),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _metricCard(
                                Icons.trending_up_rounded,
                                'Utilization',
                                _hours > 0
                                    ? '${((_trips * 0.25 / _hours) * 100).clamp(0, 100).toStringAsFixed(0)}%'
                                    : '0%',
                                const Color(0xFF42A5F5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // ── Activity stats ──
                        _sectionTitle(s.activityStats),
                        const SizedBox(height: 12),
                        _infoRow(
                          Icons.directions_car_rounded,
                          '$_periodLabel Trips',
                          '$_trips',
                        ),
                        _infoRow(
                          Icons.access_time_rounded,
                          '$_periodLabel Hours',
                          '${_hours.toStringAsFixed(1)}h',
                        ),
                        _infoRow(
                          Icons.route_rounded,
                          'Total Miles',
                          '${(_sessions.fold<double>(0, (s, ss) => s + ss.miles)).toStringAsFixed(1)}',
                        ),
                        _infoRow(
                          Icons.emoji_events_rounded,
                          'Best Session',
                          _sessions.isNotEmpty
                              ? '\$${_sessions.map((s) => s.earnings).reduce(math.max).toStringAsFixed(2)}'
                              : '\$0',
                        ),
                        const SizedBox(height: 24),

                        // ── Session history ──
                        _sectionTitle('DRIVING SESSIONS'),
                        const SizedBox(height: 12),
                        ..._sessions.map(
                          (s) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _sessionCard(s),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HERO CARD — main stats
  // ═══════════════════════════════════════════════════
  Widget _heroCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _gold.withValues(alpha: 0.12),
            _gold.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Text(
            _periodLabel,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '\$${_earnings.toStringAsFixed(2)}',
            style: TextStyle(
              color: _gold,
              fontSize: 36,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _heroStat(Icons.directions_car_rounded, '$_trips', 'Trips')),
              _vDivider(),
              Expanded(child: _heroStat(Icons.access_time_rounded, '${_hours.toStringAsFixed(1)}h', 'Online')),
              _vDivider(),
              Expanded(
                child: _heroStat(
                  Icons.speed_rounded,
                  _hours > 0 ? '\$${(_earnings / _hours).toStringAsFixed(0)}/h' : '\$0/h',
                  'Rate',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroStat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: Colors.white.withValues(alpha: 0.3), size: 18),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _vDivider() {
    return Container(
      width: 1,
      height: 40,
      color: Colors.white.withValues(alpha: 0.06),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HOURLY HEATMAP
  // ═══════════════════════════════════════════════════
  Widget _hourlyHeatmap() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Your driving activity by hour',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text('Low', style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 9)),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text('High', style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 9)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 24-hour grid (4 rows × 6 cols)
          Wrap(
            spacing: 3,
            runSpacing: 3,
            children: List.generate(24, (h) {
              final intensity = _hourlyActivity[h].clamp(0.0, 1.0);
              final label = h == 0
                  ? '12a'
                  : h < 12
                      ? '${h}a'
                      : h == 12
                          ? '12p'
                          : '${h - 12}p';
              return SizedBox(
                width: (MediaQuery.of(context).size.width - 62) / 8 - 3,
                height: 32,
                child: Container(
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.08 + intensity * 0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: intensity > 0.5
                            ? Colors.black.withValues(alpha: 0.7)
                            : Colors.white.withValues(alpha: 0.4),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  SESSION CARD
  // ═══════════════════════════════════════════════════
  Widget _sessionCard(_Session s) {
    final duration = s.end.difference(s.start);
    final durationStr = duration.inHours > 0
        ? '${duration.inHours}h ${duration.inMinutes.remainder(60)}m'
        : '${duration.inMinutes}m';
    final timeStr = '${_formatTime(s.start)} — ${_formatTime(s.end)}';
    final dateStr = _isToday(s.start)
        ? 'Today'
        : _isYesterday(s.start)
            ? 'Yesterday'
            : '${s.start.month}/${s.start.day}';

    return GestureDetector(
      onTap: () => _showSessionDetail(s),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: s.isActive
              ? _gold.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: s.isActive
                ? _gold.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Row(
          children: [
            // Status indicator
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: s.isActive
                    ? _gold.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                s.isActive ? Icons.play_circle_filled_rounded : Icons.check_circle_rounded,
                color: s.isActive ? _gold : const Color(0xFF4CAF50).withValues(alpha: 0.6),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        dateStr,
                        style: TextStyle(
                          color: s.isActive ? _gold : Colors.white.withValues(alpha: 0.7),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (s.isActive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'LIVE',
                            style: TextStyle(
                              color: _gold,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$timeStr  •  $durationStr',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '\$${s.earnings.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${s.trips} trips  •  ${s.miles.toStringAsFixed(1)} mi',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSessionDetail(_Session s) {
    HapticFeedback.selectionClick();
    final duration = s.end.difference(s.start);
    final durationStr = '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    final rate = duration.inMinutes > 0
        ? (s.earnings / (duration.inMinutes / 60))
        : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Session Details',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _detailStat('\$${s.earnings.toStringAsFixed(2)}', 'Earnings', _gold)),
                Expanded(child: _detailStat('${s.trips}', 'Trips', Colors.white)),
                Expanded(child: _detailStat(durationStr, 'Duration', Colors.white)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _detailStat('${s.miles.toStringAsFixed(1)} mi', 'Distance', const Color(0xFF42A5F5))),
                Expanded(child: _detailStat('\$${rate.toStringAsFixed(2)}/h', 'Hourly Rate', const Color(0xFF4CAF50))),
                Expanded(
                  child: _detailStat(
                    s.trips > 0 ? '\$${(s.earnings / s.trips).toStringAsFixed(2)}' : '\$0',
                    'Per Trip',
                    const Color(0xFFFF6B35),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _infoRow(Icons.access_time_rounded, 'Start Time', _formatTime(s.start)),
            _infoRow(Icons.access_time_filled_rounded, 'End Time', s.isActive ? 'Now' : _formatTime(s.end)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _detailStat(String value, String label, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  //  SHARED WIDGETS
  // ═══════════════════════════════════════════════════
  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.5),
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _metricCard(IconData icon, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color.withValues(alpha: 0.6), size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _barChart() {
    final maxVal = _dailyEarnings.fold<double>(1, math.max);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: SizedBox(
        height: 140,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(7, (i) {
            final h = (_dailyEarnings[i] / maxVal * 100).clamp(4.0, 100.0);
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '\$${_dailyEarnings[i].toStringAsFixed(0)}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: h,
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _dayLabels[i],
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.4), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════
  String _formatTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:${dt.minute.toString().padLeft(2, '0')} $amPm';
  }

  bool _isToday(DateTime dt) {
    final now = DateTime.now();
    return dt.year == now.year && dt.month == now.month && dt.day == now.day;
  }

  bool _isYesterday(DateTime dt) {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day;
  }
}

// ═══════════════════════════════════════════════════════════════
//  SESSION DATA MODEL
// ═══════════════════════════════════════════════════════════════
class _Session {
  final DateTime start;
  final DateTime end;
  final int trips;
  final double earnings;
  final double miles;
  final bool isActive;

  const _Session({
    required this.start,
    required this.end,
    required this.trips,
    required this.earnings,
    required this.miles,
    this.isActive = false,
  });
}
