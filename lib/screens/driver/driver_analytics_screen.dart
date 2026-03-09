import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

class DriverAnalyticsScreen extends StatefulWidget {
  const DriverAnalyticsScreen({super.key});

  @override
  State<DriverAnalyticsScreen> createState() => _DriverAnalyticsScreenState();
}

class _DriverAnalyticsScreenState extends State<DriverAnalyticsScreen> {
  static const _gold = Color(0xFFD4A843);

  double _todayEarnings = 0;
  double _weekEarnings = 0;
  double _monthEarnings = 0;
  int _todayTrips = 0;
  int _weekTrips = 0;
  double _todayHours = 0;
  double _weekHours = 0;
  List<double> _dailyEarnings = List.filled(7, 0);
  List<String> _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
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

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
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
            const SizedBox(height: 8),

            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator(color: _gold))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Summary cards row
                        Row(
                          children: [
                            Expanded(
                              child: _statCard(
                                s.today,
                                '\$${_todayEarnings.toStringAsFixed(2)}',
                                _gold,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                s.thisWeek,
                                '\$${_weekEarnings.toStringAsFixed(2)}',
                                const Color(0xFF4CAF50),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statCard(
                                s.thisMonth,
                                '\$${_monthEarnings.toStringAsFixed(2)}',
                                const Color(0xFF42A5F5),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),

                        // Weekly chart
                        _sectionTitle(s.weeklyChart),
                        const SizedBox(height: 12),
                        _barChart(),

                        const SizedBox(height: 24),

                        // Activity stats
                        _sectionTitle(s.activityStats),
                        const SizedBox(height: 12),
                        _infoRow(
                          Icons.directions_car_rounded,
                          s.tripsToday,
                          '$_todayTrips',
                        ),
                        _infoRow(
                          Icons.access_time_rounded,
                          s.onlineHoursToday,
                          '${_todayHours.toStringAsFixed(1)}h',
                        ),
                        _infoRow(
                          Icons.route_rounded,
                          s.tripsThisWeek,
                          '$_weekTrips',
                        ),
                        _infoRow(
                          Icons.timer_outlined,
                          s.onlineHoursWeek,
                          '${_weekHours.toStringAsFixed(1)}h',
                        ),
                        if (_todayTrips > 0)
                          _infoRow(
                            Icons.attach_money_rounded,
                            s.avgPerTrip,
                            '\$${(_todayEarnings / _todayTrips).toStringAsFixed(2)}',
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

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

  Widget _statCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
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
}
