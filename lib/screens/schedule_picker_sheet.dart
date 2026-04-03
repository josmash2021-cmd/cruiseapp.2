import 'package:flutter/material.dart';

/// Reusable schedule bottom sheet with calendar → clock picker.
/// Returns (DateTime scheduledAt, bool isAirport) on confirm, or null on cancel.
class SchedulePickerSheet extends StatefulWidget {
  final bool isDark;
  const SchedulePickerSheet({super.key, required this.isDark});

  @override
  State<SchedulePickerSheet> createState() => _SchedulePickerSheetState();
}

class _SchedulePickerSheetState extends State<SchedulePickerSheet>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeOut;
  late final Animation<double> _fadeIn;

  bool _showingClock = false;
  bool _isAirport = false;
  DateTime _selectedDate = DateTime.now();
  int _selectedHour = TimeOfDay.now().hour;
  int _selectedMinute = (TimeOfDay.now().minute ~/ 5) * 5;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
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
    super.dispose();
  }

  void _goToClock() {
    setState(() => _showingClock = true);
    _animCtrl.forward(from: 0);
  }

  void _goBackToCalendar() {
    setState(() => _showingClock = false);
    _animCtrl.reverse(from: 1);
  }

  void _confirm() {
    final scheduled = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedHour,
      _selectedMinute,
    );
    Navigator.of(context).pop((scheduled, _isAirport));
  }

  Color get _bg => const Color(0xFF161820);
  Color get _surface => const Color(0xFF1A1D24);
  Color get _textPrimary => Colors.white;
  Color get _textSecondary => Colors.white54;
  Color get _border => Colors.white10;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_showingClock)
                    GestureDetector(
                      onTap: _goBackToCalendar,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.arrow_back_ios_rounded,
                          color: _gold,
                          size: 20,
                        ),
                      ),
                    ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _showingClock ? 'Select Time' : 'Schedule a Ride',
                      key: ValueKey(_showingClock),
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Icon(
                      _showingClock
                          ? Icons.access_time_filled_rounded
                          : Icons.calendar_month_rounded,
                      key: ValueKey(_showingClock),
                      color: _gold,
                      size: 26,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    _showingClock
                        ? 'Pick your preferred time'
                        : 'Choose a date for your ride',
                    key: ValueKey(_showingClock),
                    style: TextStyle(color: _textSecondary, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: _animCtrl,
                builder: (context, _) {
                  return SizedBox(
                    height: 320,
                    child: Stack(
                      children: [
                        if (!_showingClock || _animCtrl.isAnimating)
                          FadeTransition(
                            opacity: _fadeOut,
                            child: _buildCalendar(),
                          ),
                        if (_showingClock)
                          FadeTransition(
                            opacity: _fadeIn,
                            child: _buildTimePicker(),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => setState(() => _isAirport = !_isAirport),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _isAirport
                        ? const Color(0xFF4285F4).withValues(alpha: 0.12)
                        : _surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _isAirport
                          ? const Color(0xFF4285F4).withValues(alpha: 0.4)
                          : _border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.flight_rounded,
                        size: 20,
                        color: _isAirport
                            ? const Color(0xFF4285F4)
                            : _textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Airport trip',
                        style: TextStyle(
                          color: _isAirport
                              ? const Color(0xFF4285F4)
                              : _textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 42,
                        height: 24,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: _isAirport
                              ? const Color(0xFF4285F4)
                              : Colors.white12,
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isAirport
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 20,
                            height: 20,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _showingClock ? _confirm : _goToClock,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
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
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Row(
                        key: ValueKey(_showingClock),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _showingClock
                                ? Icons.check_rounded
                                : Icons.access_time_rounded,
                            color: Colors.black87,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _showingClock ? 'Confirm & Book' : 'Select Time',
                            style: const TextStyle(
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalendar() {
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, now.day);
    final lastDay = firstDay.add(const Duration(days: 30));

    return Theme(
      data: (widget.isDark ? ThemeData.dark() : ThemeData.light()).copyWith(
        colorScheme: widget.isDark
            ? ColorScheme.dark(
                primary: _gold,
                onPrimary: Colors.white,
                surface: _bg,
                onSurface: Colors.white,
              )
            : ColorScheme.light(
                primary: _gold,
                onPrimary: Colors.white,
                surface: _bg,
                onSurface: const Color(0xFF1A1D24),
              ),
        datePickerTheme: DatePickerThemeData(
          backgroundColor: _bg,
          headerBackgroundColor: _bg,
          headerForegroundColor: _textPrimary,
          // Selected day: white text on gold circle — number clearly visible
          dayForegroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF1A1400); // dark text on gold bg
            }
            return _textPrimary;
          }),
          dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return _gold; // gold circle fill
            }
            return null;
          }),
          dayOverlayColor: WidgetStatePropertyAll(
            _gold.withValues(alpha: 0.12),
          ),
          todayForegroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF1A1400);
            }
            return _gold;
          }),
          todayBorder: const BorderSide(color: _gold, width: 1.5),
          yearForegroundColor: WidgetStatePropertyAll(_textPrimary),
          weekdayStyle: TextStyle(
            color: _textSecondary,
            fontWeight: FontWeight.w600,
          ),
          dayStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      child: CalendarDatePicker(
        initialDate: _selectedDate,
        firstDate: firstDay,
        lastDate: lastDay,
        onDateChanged: (date) => setState(() => _selectedDate = date),
      ),
    );
  }

  Widget _buildTimePicker() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text(
            _selectedHour < 12 ? 'AM' : 'PM',
            style: TextStyle(
              color: _gold,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _timeDigit(
                value: _selectedHour == 0
                    ? 12
                    : (_selectedHour > 12 ? _selectedHour - 12 : _selectedHour),
                label: 'Hour',
                onUp: () =>
                    setState(() => _selectedHour = (_selectedHour + 1) % 24),
                onDown: () => setState(
                  () => _selectedHour = (_selectedHour - 1 + 24) % 24,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  ':',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 44,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
              _timeDigit(
                value: _selectedMinute,
                label: 'Min',
                padZero: true,
                onUp: () => setState(
                  () => _selectedMinute = (_selectedMinute + 5) % 60,
                ),
                onDown: () => setState(
                  () => _selectedMinute = (_selectedMinute - 5 + 60) % 60,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _amPmChip('AM', _selectedHour < 12, () {
                if (_selectedHour >= 12) setState(() => _selectedHour -= 12);
              }),
              const SizedBox(width: 12),
              _amPmChip('PM', _selectedHour >= 12, () {
                if (_selectedHour < 12) setState(() => _selectedHour += 12);
              }),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_rounded, color: _gold, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${_selectedDate.month}/${_selectedDate.day}/${_selectedDate.year}',
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 14),
                Icon(Icons.schedule_rounded, color: _gold, size: 18),
                const SizedBox(width: 8),
                Text(
                  _formatTime(),
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeDigit({
    required int value,
    required String label,
    bool padZero = false,
    required VoidCallback onUp,
    required VoidCallback onDown,
  }) {
    final display =
        padZero ? value.toString().padLeft(2, '0') : value.toString();
    return Column(
      children: [
        GestureDetector(
          onTap: onUp,
          child: Container(
            width: 70,
            height: 36,
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border),
            ),
            child: Icon(
              Icons.keyboard_arrow_up_rounded,
              color: _gold,
              size: 24,
            ),
          ),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
          child: Text(
            display,
            key: ValueKey(value),
            style: TextStyle(
              color: _textPrimary,
              fontSize: 44,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: _textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onDown,
          child: Container(
            width: 70,
            height: 36,
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border),
            ),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: _gold,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _amPmChip(String text, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        decoration: BoxDecoration(
          color: active ? _gold.withValues(alpha: 0.15) : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? _gold : _border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: active ? _gold : _textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  String _formatTime() {
    final h = _selectedHour == 0
        ? 12
        : (_selectedHour > 12 ? _selectedHour - 12 : _selectedHour);
    final m = _selectedMinute.toString().padLeft(2, '0');
    final ampm = _selectedHour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }
}
