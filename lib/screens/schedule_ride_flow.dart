import 'package:flutter/material.dart';

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../widgets/gold_particles_background.dart';

// ═══════════════════════════════════════════════════════════════════
//  Shared constants & helpers
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
const _bg = Color(0xFF08090C);

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Entry point — opens the schedule flow and returns
/// `(scheduledAt, isAirport)` or `null` if the user cancelled.
Future<(DateTime, bool)?> showScheduleRideFlow(BuildContext context) {
  return Navigator.of(context).push<(DateTime, bool)>(
    slideUpFadeRoute(const _ScheduleDateScreen()),
  );
}

// ═══════════════════════════════════════════════════════════════════
//  SCREEN 1 — "Schedule a Ride" (calendar)
// ═══════════════════════════════════════════════════════════════════

class _ScheduleDateScreen extends StatefulWidget {
  const _ScheduleDateScreen();

  @override
  State<_ScheduleDateScreen> createState() => _ScheduleDateScreenState();
}

class _ScheduleDateScreenState extends State<_ScheduleDateScreen> {
  late DateTime _viewMonth;      // First day of the visible month
  late DateTime _selected;
  bool _isAirport = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    _viewMonth = DateTime(now.year, now.month, 1);
  }

  bool _isPast(DateTime d) {
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    return d.isBefore(t);
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _pickQuick(String key) {
    final now = DateTime.now();
    DateTime target = DateTime(now.year, now.month, now.day);
    if (key == 'tomorrow') {
      target = target.add(const Duration(days: 1));
    } else if (key == 'weekend') {
      final d = target.weekday; // Mon=1 … Sun=7
      // Next Saturday (weekday 6). If today is Sat already, jump to next Sat.
      final delta = ((6 - d + 7) % 7 == 0) ? 7 : (6 - d + 7) % 7;
      target = target.add(Duration(days: delta));
    }
    setState(() {
      _selected = target;
      _viewMonth = DateTime(target.year, target.month, 1);
    });
  }

  void _changeMonth(int delta) {
    setState(() {
      _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + delta, 1);
    });
  }

  Future<void> _goNext() async {
    final result = await Navigator.of(context).push<(DateTime, bool)>(
      slideUpFadeRoute(
        _ScheduleTimeScreen(date: _selected, isAirport: _isAirport),
      ),
    );
    if (result != null && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isEs = Localizations.localeOf(context).languageCode == 'es';

    String todayLabel = isEs ? 'Hoy' : 'Today';
    String tomorrowLabel = isEs ? 'Mañana' : 'Tomorrow';
    String weekendLabel = isEs ? 'Fin de semana' : 'Weekend';

    final today = DateTime.now();
    final tomorrow = today.add(const Duration(days: 1));
    final isTodaySel = _sameDay(_selected, today);
    final isTomorrowSel = _sameDay(_selected, tomorrow);
    // "Weekend" chip shows active when the selected day is Sat/Sun
    // within ~1 week of today.
    final isWeekendSel = !isTodaySel &&
        !isTomorrowSel &&
        (_selected.weekday == 6 || _selected.weekday == 7) &&
        _selected.difference(today).inDays <= 8;

    return Scaffold(
      backgroundColor: _bg,
      body: GoldParticlesBackground(child: SafeArea(
        child: Column(
          children: [
            _Header(
              title: isEs ? 'Programar un Viaje' : 'Schedule a Ride',
              subtitle: s.chooseDateForRide,
              trailingIcon: Icons.calendar_today_rounded,
              onBack: () => Navigator.pop(context),
            ),

            const SizedBox(height: 4),

            // Quick chips
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _QuickChip(
                    label: todayLabel,
                    active: isTodaySel,
                    onTap: () => _pickQuick('today'),
                  ),
                  const SizedBox(width: 8),
                  _QuickChip(
                    label: tomorrowLabel,
                    active: isTomorrowSel,
                    onTap: () => _pickQuick('tomorrow'),
                  ),
                  const SizedBox(width: 8),
                  _QuickChip(
                    label: weekendLabel,
                    active: isWeekendSel,
                    onTap: () => _pickQuick('weekend'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Calendar card
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _CalendarBody(
                  viewMonth: _viewMonth,
                  selected: _selected,
                  onMonthChange: _changeMonth,
                  onSelect: (d) => setState(() => _selected = d),
                  isPast: _isPast,
                  isToday: _isToday,
                ),
              ),
            ),

            // Airport toggle + Select Time
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.flight_takeoff_rounded,
                            color: _gold, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            s.airportTripLabel,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _Toggle(
                          value: _isAirport,
                          onChanged: (v) => setState(() => _isAirport = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _PrimaryButton(
                    label: s.selectTimeTitle,
                    icon: Icons.access_time_rounded,
                    onTap: _goNext,
                  ),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }
}

class _CalendarBody extends StatelessWidget {
  final DateTime viewMonth;
  final DateTime selected;
  final ValueChanged<int> onMonthChange;
  final ValueChanged<DateTime> onSelect;
  final bool Function(DateTime) isPast;
  final bool Function(DateTime) isToday;

  const _CalendarBody({
    required this.viewMonth,
    required this.selected,
    required this.onMonthChange,
    required this.onSelect,
    required this.isPast,
    required this.isToday,
  });

  @override
  Widget build(BuildContext context) {
    final year = viewMonth.year;
    final month = viewMonth.month;
    // Sunday-first: DateTime.weekday → Mon=1…Sun=7. We want Sun=0…Sat=6.
    final firstWeekday = DateTime(year, month, 1).weekday % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month nav
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              Row(
                children: [
                  Text(
                    '${_months[month - 1]} $year',
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down_rounded,
                      color: Colors.white, size: 20),
                ],
              ),
              const Spacer(),
              _NavBtn(
                icon: Icons.chevron_left_rounded,
                onTap: () => onMonthChange(-1),
              ),
              const SizedBox(width: 6),
              _NavBtn(
                icon: Icons.chevron_right_rounded,
                onTap: () => onMonthChange(1),
              ),
            ],
          ),
        ),

        const SizedBox(height: 4),

        // Weekday row
        Row(
          children: const ['S', 'M', 'T', 'W', 'T', 'F', 'S']
              .map((d) => Expanded(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          d,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: Color(0x59FFFFFF),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ))
              .toList(),
        ),

        // Grid
        Expanded(
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
              childAspectRatio: 1,
            ),
            itemCount: firstWeekday + daysInMonth,
            itemBuilder: (_, i) {
              if (i < firstWeekday) return const SizedBox.shrink();
              final day = i - firstWeekday + 1;
              final d = DateTime(year, month, day);
              return _DayCell(
                day: day,
                date: d,
                past: isPast(d),
                today: isToday(d),
                selected: d.year == selected.year &&
                    d.month == selected.month &&
                    d.day == selected.day,
                onTap: () => onSelect(d),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DayCell extends StatefulWidget {
  final int day;
  final DateTime date;
  final bool past;
  final bool today;
  final bool selected;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.date,
    required this.past,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: widget.selected ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant _DayCell old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) {
      _ripple.forward(from: 0);
    } else if (!widget.selected && old.selected) {
      _ripple.reverse();
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.past ? null : widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _ripple,
        builder: (_, __) {
          final t = _ripple.value;
          // Ripple: 0.85 → 1.12 → 1.0 (ease-out-back)
          final scale = t == 0
              ? 1.0
              : (t < 0.6
                  ? 0.85 + (1.12 - 0.85) * (t / 0.6)
                  : 1.12 - (1.12 - 1.0) * ((t - 0.6) / 0.4));
          return Center(
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.selected ? _gold : Colors.transparent,
                  border: (!widget.selected && widget.today)
                      ? Border.all(color: _gold, width: 1.5)
                      : null,
                  boxShadow: widget.selected
                      ? [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.45),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  '${widget.day}',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 14,
                    fontWeight: widget.selected
                        ? FontWeight.w800
                        : FontWeight.w600,
                    color: widget.selected
                        ? const Color(0xFF0A0E1A)
                        : widget.today
                            ? _gold
                            : widget.past
                                ? Colors.white.withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.72),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  SCREEN 2 — "Select Time" (clock)
// ═══════════════════════════════════════════════════════════════════

class _ScheduleTimeScreen extends StatefulWidget {
  final DateTime date;
  final bool isAirport;
  const _ScheduleTimeScreen({required this.date, required this.isAirport});

  @override
  State<_ScheduleTimeScreen> createState() => _ScheduleTimeScreenState();
}

class _ScheduleTimeScreenState extends State<_ScheduleTimeScreen> {
  // We snap to 30-min slots.
  late int _totalMinutes; // 0..1439

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // If scheduling for today, start at now + 30 min rounded up; otherwise
    // start at 09:00.
    if (_sameDay(widget.date, now)) {
      final advanced = now.add(const Duration(minutes: 30));
      final mins = advanced.hour * 60 + advanced.minute;
      _totalMinutes = _snap30(mins);
    } else {
      _totalMinutes = 9 * 60;
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  int _snap30(int m) {
    final r = m % 30;
    return r == 0 ? m : m + (30 - r);
  }

  int _minMinutesForToday() {
    final now = DateTime.now();
    if (!_sameDay(widget.date, now)) return 0;
    final advanced = now.add(const Duration(minutes: 30));
    return _snap30(advanced.hour * 60 + advanced.minute);
  }

  void _step(int deltaMin) {
    setState(() {
      int next = _totalMinutes + deltaMin;
      if (next < 0) next = 0;
      if (next > 23 * 60 + 30) next = 23 * 60 + 30;
      final floor = _minMinutesForToday();
      if (next < floor) next = floor;
      _totalMinutes = next;
    });
  }

  void _quickAdd(int mins) {
    final now = DateTime.now();
    final target = now.add(Duration(minutes: mins));
    final snapped = _snap30(target.hour * 60 + target.minute);
    setState(() => _totalMinutes = snapped);
  }

  DateTime _composed() {
    final d = widget.date;
    return DateTime(d.year, d.month, d.day, _totalMinutes ~/ 60, _totalMinutes % 60);
  }

  void _confirm() {
    Navigator.of(context).pop((_composed(), widget.isAirport));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isEs = Localizations.localeOf(context).languageCode == 'es';

    final h24 = _totalMinutes ~/ 60;
    final m = _totalMinutes % 60;
    final pm = h24 >= 12;
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    final hText = h12.toString().padLeft(2, '0');
    final mText = m.toString().padLeft(2, '0');

    final summary =
        '${widget.date.month}/${widget.date.day}/${widget.date.year}  ·  $hText:$mText ${pm ? 'PM' : 'AM'}';

    final slotsLabel = isEs
        ? 'Intervalos de 30 min'
        : '30-min slots from now';

    return Scaffold(
      backgroundColor: _bg,
      body: GoldParticlesBackground(child: SafeArea(
        child: Column(
          children: [
            _Header(
              title: s.selectTimeTitle,
              subtitle: s.pickPreferredTime,
              trailingIcon: Icons.access_time_rounded,
              onBack: () => Navigator.pop(context),
            ),

            const SizedBox(height: 4),

            // Quick-add chips
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _QuickChip(
                    label: '+30 min',
                    active: false,
                    onTap: () => _quickAdd(30),
                  ),
                  const SizedBox(width: 8),
                  _QuickChip(
                    label: isEs ? '+1 hr' : '+1 hr',
                    active: false,
                    onTap: () => _quickAdd(60),
                  ),
                  const SizedBox(width: 8),
                  _QuickChip(
                    label: isEs ? '+2 hr' : '+2 hr',
                    active: false,
                    onTap: () => _quickAdd(120),
                  ),
                ],
              ),
            ),

            // Clock face
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _BigArrow(
                    icon: Icons.arrow_drop_up_rounded,
                    onTap: () => _step(30),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _TimeBox(text: hText),
                      const SizedBox(width: 6),
                      const Text(
                        ':',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Color(0x4DFFFFFF),
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _TimeBox(text: mText),
                      const SizedBox(width: 10),
                      Text(
                        pm ? 'PM' : 'AM',
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: _gold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    slotsLabel,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Color(0x80E8C547),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _BigArrow(
                    icon: Icons.arrow_drop_down_rounded,
                    onTap: () => _step(-30),
                  ),
                  const SizedBox(height: 28),
                  _SummaryPill(text: summary),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: _PrimaryButton(
                label: s.confirmAndBook,
                icon: Icons.check_rounded,
                onTap: _confirm,
              ),
            ),
          ],
        ),
      )),
    );
  }
}

class _TimeBox extends StatelessWidget {
  final String text;
  const _TimeBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0x14E8C547),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x33E8C547), width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Poppins',
          fontSize: 46,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1.0,
          letterSpacing: -1,
        ),
      ),
    );
  }
}

class _BigArrow extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _BigArrow({required this.icon, required this.onTap});

  @override
  State<_BigArrow> createState() => _BigArrowState();
}

class _BigArrowState extends State<_BigArrow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 72,
          height: 46,
          decoration: BoxDecoration(
            color: _pressed
                ? const Color(0x33E8C547)
                : const Color(0x1FE8C547),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0x40E8C547),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, color: _gold, size: 28),
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  final String text;
  const _SummaryPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_today_rounded,
              color: _gold, size: 14),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Shared widgets (header, chip, button, toggle, nav buttons)
// ═══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData trailingIcon;
  final VoidCallback onBack;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.trailingIcon,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
            splashRadius: 22,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0x14E8C547),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x33E8C547)),
            ),
            child: Icon(trailingIcon, color: _gold, size: 20),
          ),
        ],
      ),
    );
  }
}

class _QuickChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _QuickChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_QuickChip> createState() => _QuickChipState();
}

class _QuickChipState extends State<_QuickChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: widget.active
                ? _gold
                : const Color(0x14E8C547),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.active ? _gold : const Color(0x38E8C547),
              width: 1,
            ),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: widget.active
                  ? const Color(0xFF0A0E1A)
                  : _gold,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _NavBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, color: Colors.white.withValues(alpha: 0.55), size: 22),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 44,
        height: 24,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? _gold : Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40E8C547),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 20,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: const Color(0xFF0A0E1A), size: 18),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Color(0xFF0A0E1A),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
