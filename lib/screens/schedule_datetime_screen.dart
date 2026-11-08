import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../config/api_keys.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../services/directions_service.dart';
import '../../services/places_service.dart';
import '../../widgets/neu_style.dart';
import 'pickup_dropoff_search_screen.dart';
import 'schedule_cancel_policy_screen.dart';

/// "Schedule a ride" — Depart/Arrive date-time page (2026-08-22).
///
/// Cupertino wheels (day / hour / minute / AM-PM) over the dark neu ground.
/// Earliest bookable: now + 40 min, on the wheels' 5-minute step; latest:
/// +30 days. On Next the page
/// pushes the pickup/dropoff search ON TOP of itself (back returns to the
/// wheels, same contract as the legacy time screen) and pops with
/// `(scheduledAt, searchResult)` once the rider confirms addresses.
///
/// [estimatedMinutes] is the pickup→dropoff drive time when the caller
/// already knows it — the "Estimated ride time" / Drop-off / Pickup lines
/// render only then (at this point in the flow addresses come later, so
/// the hub passes null and the lines stay out).
/// Reservations open 40 minutes ahead at the earliest (owner 2026-11-08,
/// "debe ser con 40 min de anticipación cualquier reserva"; was 30).
const int kScheduleMinLeadMinutes = 40;

/// The page's clock — tests pin it.
@visibleForTesting
DateTime Function() scheduleClock = DateTime.now;

/// [t] up to the next 5-minute mark (the minute wheel's step); a time already
/// on a mark with no seconds stays.
DateTime ceilToFiveMinutes(DateTime t) {
  final bump = t.second > 0 || t.millisecond > 0 || t.microsecond > 0;
  var m = t.minute + (bump ? 1 : 0);
  final r = m % 5;
  if (r != 0) m += 5 - r;
  return DateTime(t.year, t.month, t.day, t.hour, m);
}

/// The earliest pickup a rider can book from [now]: 40 minutes later, up to
/// the next 5-minute mark — what the wheels open on.
DateTime earliestSchedulePickup(DateTime now) => ceilToFiveMinutes(
    now.add(const Duration(minutes: kScheduleMinLeadMinutes)));

class ScheduleDateTimeScreen extends StatefulWidget {
  const ScheduleDateTimeScreen({
    super.key,
    this.initialPickupLat,
    this.initialPickupLng,
    this.initialDateTime,
    this.estimatedMinutes,
    this.prefilledPickup,
    this.prefilledDropoff,
    this.prefilledPickupLabel,
    this.prefilledDropoffLabel,
    this.prefilledStopAddress,
    this.prefilledStopLat,
    this.prefilledStopLng,
  });

  final double? initialPickupLat;
  final double? initialPickupLng;

  /// Calendar shortcut prefill: the event's start time seeds the wheels.
  final DateTime? initialDateTime;

  /// Drive time of the route, when known. Null = no route yet → the
  /// estimated-time lines stay hidden (never a guessed number).
  final int? estimatedMinutes;

  /// 2026-08-22 chain order: addresses come BEFORE this page. When they
  /// arrive prefilled, Next pops `(scheduledAt, searchResult)` straight up
  /// instead of pushing the address search.
  final PlaceDetails? prefilledPickup;
  final PlaceDetails? prefilledDropoff;
  final String? prefilledPickupLabel;
  final String? prefilledDropoffLabel;

  /// The optional intermediate stop from the addresses page — travels in
  /// the record and into the booking notes ("Stop: …"); its coordinates
  /// pin the stop on the booking map and route the preview through it.
  final String? prefilledStopAddress;
  final double? prefilledStopLat;
  final double? prefilledStopLng;

  @override
  State<ScheduleDateTimeScreen> createState() =>
      _ScheduleDateTimeScreenState();
}

class _ScheduleDateTimeScreenState extends State<ScheduleDateTimeScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _maxDays = 30;

  /// false = Salida (the wheels are the pickup time), true = Llegada (the
  /// wheels are the drop-off time; the pickup is it minus the ride).
  bool _arriveMode = false;

  /// What the wheels show, always on a 5-minute mark.
  late DateTime _wheelTime;

  /// The ride's minutes, pickup → drop-off. From the caller, or worked out
  /// here from the addresses when the caller's quick try ran out of time.
  int? _est;
  bool _estLoading = false;

  /// The wheels are being moved by the page (to the earliest bookable time):
  /// their change callbacks only follow along.
  bool _snapping = false;

  /// A short line under the tabs (why Llegada can't open yet, or that a
  /// time that passed moved to the earliest).
  String? _notice;
  Timer? _noticeTimer;

  /// The earliest time moves with the clock: an open page keeps the wheels
  /// on a bookable time.
  Timer? _minWatch;

  late final FixedExtentScrollController _dayCtrl;
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minCtrl;
  late final FixedExtentScrollController _ampmCtrl;

  /// Days offered: today .. today+30d.
  late final DateTime _day0;

  @override
  void initState() {
    super.initState();
    final now = scheduleClock();
    _day0 = DateTime(now.year, now.month, now.day);
    _est = widget.estimatedMinutes;
    // Opens on the earliest bookable pickup — or on the time the rider had,
    // when that is still bookable (rounded onto the wheels' 5 minutes).
    final earliest = earliestSchedulePickup(now);
    final seed = widget.initialDateTime;
    final seeded = seed == null ? earliest : ceilToFiveMinutes(seed);
    _wheelTime = seeded.isBefore(earliest) ? earliest : seeded;
    final last = _lastWheelTime;
    if (_wheelTime.isAfter(last)) _wheelTime = last;

    final at = _positionsOf(_wheelTime);
    _dayCtrl = FixedExtentScrollController(initialItem: at.day);
    _hourCtrl = FixedExtentScrollController(initialItem: at.hour);
    _minCtrl = FixedExtentScrollController(initialItem: at.minute);
    _ampmCtrl = FixedExtentScrollController(initialItem: at.ampm);

    if (_est == null &&
        widget.prefilledPickup != null &&
        widget.prefilledDropoff != null) {
      _fetchEstimate();
    }
    _minWatch = Timer.periodic(
        const Duration(seconds: 20), (_) => _keepBookable(announce: true));
  }

  @override
  void dispose() {
    _minWatch?.cancel();
    _noticeTimer?.cancel();
    _dayCtrl.dispose();
    _hourCtrl.dispose();
    _minCtrl.dispose();
    _ampmCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchEstimate() async {
    final a = widget.prefilledPickup!, b = widget.prefilledDropoff!;
    setState(() => _estLoading = true);
    try {
      final route = await DirectionsService(ApiKeys.webServices)
          .getRoute(origin: LatLng(a.lat, a.lng), destination: LatLng(b.lat, b.lng))
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      final secs = route?.durationSeconds;
      if (!mounted) return;
      setState(() {
        if (secs != null && secs > 0) _est = (secs / 60).ceil();
        _estLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _estLoading = false);
    }
  }

  // ── Time math ──────────────────────────────────────────────────────

  /// Calendar days from today (never 24-hour blocks: a daylight-saving
  /// night is 23 or 25 hours long).
  int _dayIndexOf(DateTime t) => DateTime.utc(t.year, t.month, t.day)
      .difference(DateTime.utc(_day0.year, _day0.month, _day0.day))
      .inDays;

  DateTime _dayAt(int i) => DateTime(_day0.year, _day0.month, _day0.day + i);

  DateTime _compose(int dayIdx, int hourIdx, int minIdx, int ampmIdx) {
    final day = _dayAt(dayIdx);
    var hour = hourIdx == 0 ? 12 : hourIdx; // wheel 0 shows "12"
    if (ampmIdx == 1 && hour != 12) hour += 12;
    if (ampmIdx == 0 && hour == 12) hour = 0;
    return DateTime(day.year, day.month, day.day, hour, minIdx * 5);
  }

  DateTime get _lastWheelTime {
    final d = _dayAt(_maxDays);
    return DateTime(d.year, d.month, d.day, 23, 55);
  }

  /// The earliest the wheels may show now: the earliest pickup (Salida), or
  /// the drop-off it leads to (Llegada). Null in Llegada without the ride's
  /// minutes — nothing can be checked then.
  DateTime? get _earliestWheel {
    final pickup = earliestSchedulePickup(scheduleClock());
    if (!_arriveMode) return pickup;
    final est = _est;
    if (est == null) return null;
    return ceilToFiveMinutes(pickup.add(Duration(minutes: est)));
  }

  /// The pickup the booking carries. Null in Llegada without the ride's
  /// minutes (Next waits for them).
  DateTime? get _pickupTime {
    if (!_arriveMode) return _wheelTime;
    final est = _est;
    if (est == null) return null;
    return _wheelTime.subtract(Duration(minutes: est));
  }

  String _fmtTime(DateTime d) {
    final h24 = d.hour;
    final pm = h24 >= 12;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h12:$mm ${pm ? 'PM' : 'AM'}';
  }

  /// "3:34 PM", or "12:04 AM · Mañana" when it lands on another day than
  /// the wheels show.
  String _fmtWithDay(DateTime d, S s) {
    final t = _fmtTime(d);
    if (_dayIndexOf(d) == _dayIndexOf(_wheelTime)) return t;
    return '$t · ${_dayLabel(_dayIndexOf(d), s)}';
  }

  // ── Wheels ─────────────────────────────────────────────────────────
  //
  // Each wheel lists only what can still be booked (owner 2026-11-08: "horas
  // pasadas… no deben aparecer"): days from the earliest one, and on that
  // day AM/PM, hours and minutes from the earliest on. A wheel's list
  // depends only on the wheels left of it (day → AM/PM → hour → minute), so
  // turning one only reshapes the ones after it.

  int _dayValueOf(DateTime t) => _dayIndexOf(t);
  int _ampmValueOf(DateTime t) => t.hour >= 12 ? 1 : 0;
  int _hourValueOf(DateTime t) => t.hour % 12; // 0 shows "12"
  int _minuteValueOf(DateTime t) => t.minute ~/ 5;

  List<int> get _dayOptions {
    final e = _earliestWheel;
    final first = e == null ? 0 : _dayValueOf(e);
    return [for (var d = first; d <= _maxDays; d++) d];
  }

  List<int> _ampmOptions(int day) {
    final e = _earliestWheel;
    if (e != null && day == _dayValueOf(e) && _ampmValueOf(e) == 1) {
      return const [1];
    }
    return const [0, 1];
  }

  List<int> _hourOptions(int day, int ampm) {
    final e = _earliestWheel;
    final from = (e != null && day == _dayValueOf(e) && ampm == _ampmValueOf(e))
        ? _hourValueOf(e)
        : 0;
    return [for (var h = from; h < 12; h++) h];
  }

  List<int> _minuteOptions(int day, int ampm, int hour) {
    final e = _earliestWheel;
    final from = (e != null &&
            day == _dayValueOf(e) &&
            ampm == _ampmValueOf(e) &&
            hour == _hourValueOf(e))
        ? _minuteValueOf(e)
        : 0;
    return [for (var m = from; m < 12; m++) m];
  }

  /// Where each wheel sits for [t], in the lists [t] itself makes.
  ({int day, int ampm, int hour, int minute}) _positionsOf(DateTime t) {
    final d = _dayValueOf(t), a = _ampmValueOf(t), h = _hourValueOf(t);
    int at(List<int> opts, int v) {
      final i = opts.indexOf(v);
      return i < 0 ? 0 : i;
    }

    return (
      day: at(_dayOptions, d),
      ampm: at(_ampmOptions(d), a),
      hour: at(_hourOptions(d, a), h),
      minute: at(_minuteOptions(d, a, h), _minuteValueOf(t)),
    );
  }

  /// One wheel moved to [pos] of its list: rebuild the time from it and the
  /// others' values. Coming onto the earliest day/half/hour with a value
  /// that no longer exists there takes the earliest time.
  void _onWheel(String wheel, int pos) {
    if (_snapping) return;
    final t = _wheelTime;
    var day = _dayValueOf(t), ampm = _ampmValueOf(t);
    var hour = _hourValueOf(t), minute = _minuteValueOf(t);
    int pick(List<int> opts) => opts[pos.clamp(0, opts.length - 1)];
    switch (wheel) {
      case 'day':
        day = pick(_dayOptions);
      case 'ampm':
        ampm = pick(_ampmOptions(day));
      case 'hour':
        hour = pick(_hourOptions(day, ampm));
      case 'minute':
        minute = pick(_minuteOptions(day, ampm, hour));
    }
    var next = _compose(day, hour, minute, ampm);
    final e = _earliestWheel;
    if (e != null && next.isBefore(e)) next = e;
    _setWheelTime(next);
  }

  /// Puts the wheels on [t] — the lists change with it, so after the frame
  /// each wheel is moved to where [t]'s value now sits in its list.
  void _setWheelTime(DateTime t) {
    setState(() => _wheelTime = t);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWheels());
  }

  void _syncWheels() {
    if (!mounted) return;
    final at = _positionsOf(_wheelTime);
    _snapping = true;
    try {
      for (final (c, i) in [
        (_dayCtrl, at.day),
        (_ampmCtrl, at.ampm),
        (_hourCtrl, at.hour),
        (_minCtrl, at.minute),
      ]) {
        if (c.hasClients && c.selectedItem != i) c.jumpToItem(i);
      }
    } finally {
      _snapping = false;
    }
  }

  /// The earliest time moves with the clock: a time it passes gives way to
  /// the earliest one (told, when [announce]); the lists shrink with it.
  void _keepBookable({bool announce = false}) {
    if (!mounted) return;
    final earliest = _earliestWheel;
    if (earliest != null && _wheelTime.isBefore(earliest)) {
      if (announce) {
        _showNotice(S.of(context).schedMovedToEarliest(_fmtTime(earliest)));
      }
      _setWheelTime(earliest);
    } else {
      _setWheelTime(_wheelTime);
    }
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  // ── Salida / Llegada ───────────────────────────────────────────────

  /// Llegada shows the drop-off the current pickup leads to; Salida the
  /// pickup the current drop-off needs — so switching never changes the
  /// plan, only which end of it the wheels show (rounded onto 5 minutes,
  /// never earlier than bookable).
  void _setArriveMode(bool arrive) {
    if (arrive == _arriveMode) return;
    final est = _est;
    if (arrive && est == null) {
      _showNotice(_estLoading
          ? S.of(context).schedRouteLoading
          : S.of(context).schedArriveNeedsRoute);
      return;
    }
    final pickup = _pickupTime ?? _wheelTime;
    setState(() => _arriveMode = arrive);
    var t = arrive
        ? ceilToFiveMinutes(pickup.add(Duration(minutes: est!)))
        : ceilToFiveMinutes(pickup);
    final earliest = _earliestWheel;
    if (earliest != null && t.isBefore(earliest)) t = earliest;
    if (t.isAfter(_lastWheelTime)) t = _lastWheelTime;
    _setWheelTime(t);
  }

  Future<void> _onNext() async {
    final pickup = _pickupTime;
    if (pickup == null) return;
    // The clock moved while the rider sat here: never book a time that is
    // now under 40 minutes away — show the earliest instead.
    if (pickup.isBefore(earliestSchedulePickup(scheduleClock()))) {
      _keepBookable(announce: true);
      return;
    }
    final scheduledAt = pickup;

    // Addresses came prefilled (2026-08-22 chain: addresses → wheels) —
    // pop the record straight up, no second search.
    final drop = widget.prefilledDropoff;
    if (drop != null) {
      Navigator.of(context).pop((
        scheduledAt,
        <String, dynamic>{
          'pickup': widget.prefilledPickup,
          'dropoff': drop,
          'pickupLabel': widget.prefilledPickupLabel ?? '',
          'dropoffLabel': widget.prefilledDropoffLabel ?? drop.address,
          if (widget.prefilledStopAddress != null &&
              widget.prefilledStopAddress!.isNotEmpty)
            'stopAddress': widget.prefilledStopAddress,
          if (widget.prefilledStopLat != null &&
              widget.prefilledStopLng != null) ...{
            'stopLat': widget.prefilledStopLat,
            'stopLng': widget.prefilledStopLng,
          },
        },
      ));
      return;
    }

    final searchResult =
        await Navigator.of(context).push<Map<String, dynamic>>(
      slideUpFadeRoute(
        PickupDropoffSearchScreen(
          initialPickupLat: widget.initialPickupLat,
          initialPickupLng: widget.initialPickupLng,
          scheduledAt: scheduledAt,
          isAirportTrip: false,
        ),
      ),
    );
    // Back from the search stays here; a confirmed pair bubbles up.
    if (searchResult != null && mounted) {
      Navigator.of(context).pop((scheduledAt, searchResult));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final est = _est;
    final earliest = _earliestWheel;
    final pickupTime = _pickupTime;
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: Column(
              children: [
                // ── Top row: back / title ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.arrow_back_ios_new_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            s.schedDateTimeTitle,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 38),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ── Depart / Arrive tabs (gold indicator) ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.all(4),
                    decoration: neuBox(radius: 14, pressed: true),
                    child: Row(
                      children: [
                        _tab(s.schedDepart, !_arriveMode,
                            () => _setArriveMode(false)),
                        _tab(s.schedArrive, _arriveMode,
                            () => _setArriveMode(true)),
                      ],
                    ),
                  ),
                ),

                // Why Llegada can't open yet / a passed time moved on.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _notice == null
                      ? const SizedBox(height: 12)
                      : Padding(
                          key: ValueKey(_notice),
                          padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
                          child: Text(
                            _notice!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),

                // ── Wheels ── only bookable times are listed.
                Expanded(
                  child: Center(
                    child: SizedBox(
                      height: 220,
                      child: Builder(builder: (_) {
                        final t = _wheelTime;
                        final day = _dayValueOf(t), ampm = _ampmValueOf(t);
                        final hour = _hourValueOf(t);
                        final days = _dayOptions;
                        final halves = _ampmOptions(day);
                        final hours = _hourOptions(day, ampm);
                        final minutes = _minuteOptions(day, ampm, hour);
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _wheel(
                              key: const ValueKey('wheel-day'),
                              controller: _dayCtrl,
                              width: 128,
                              itemCount: days.length,
                              label: (i) => _dayLabel(days[i], s),
                              onChanged: (i) => _onWheel('day', i),
                            ),
                            _wheel(
                              key: const ValueKey('wheel-hour'),
                              controller: _hourCtrl,
                              width: 62,
                              itemCount: hours.length,
                              label: (i) => hours[i] == 0 ? '12' : '${hours[i]}',
                              onChanged: (i) => _onWheel('hour', i),
                            ),
                            _wheel(
                              key: const ValueKey('wheel-minute'),
                              controller: _minCtrl,
                              width: 62,
                              itemCount: minutes.length,
                              label: (i) =>
                                  (minutes[i] * 5).toString().padLeft(2, '0'),
                              onChanged: (i) => _onWheel('minute', i),
                            ),
                            _wheel(
                              key: const ValueKey('wheel-ampm'),
                              controller: _ampmCtrl,
                              width: 66,
                              itemCount: halves.length,
                              label: (i) => halves[i] == 0 ? 'AM' : 'PM',
                              onChanged: (i) => _onWheel('ampm', i),
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),

                // The earliest bookable time, so the rule is never a surprise.
                if (earliest != null) ...[
                  Text(
                    s.schedEarliest(_fmtWithDay(earliest, s)),
                    key: const ValueKey('sched-earliest'),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                ],

                // ── Estimate block (only with a known route time) ──
                // Salida: the exact drop-off. Llegada: when they're picked
                // up — what the booking carries.
                if (est != null) ...[
                  Text(
                    s.schedEstimatedRideTime(est),
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _arriveMode
                        ? s.schedPickupAt(_fmtWithDay(
                            _wheelTime.subtract(Duration(minutes: est)), s))
                        : s.schedDropoffAt(_fmtWithDay(
                            _wheelTime.add(Duration(minutes: est)), s)),
                    key: const ValueKey('sched-other-end'),
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                ] else if (_estLoading) ...[
                  Text(
                    s.schedRouteLoading,
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                ],

                // ── Priority note ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.star_rounded, color: _gold, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.schedPriorityNote,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => Navigator.of(context).push(slideUpFadeRoute(
                      const ScheduleCancelPolicyScreen())),
                  child: Text(
                    s.schedCancelEditFree,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: _gold,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Next ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: pickupTime == null ? null : _onNext,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        s.next,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: active ? _gold : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.black : Colors.white54,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  String _dayLabel(int i, S s) {
    final d = _dayAt(i);
    if (i == 0) return s.schedToday;
    if (i == 1) return s.schedTomorrow;
    const wdEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const wdEs = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
    final wd = s.isSpanish ? wdEs[d.weekday - 1] : wdEn[d.weekday - 1];
    return '$wd ${d.month}/${d.day}';
  }

  Widget _wheel({
    Key? key,
    required FixedExtentScrollController controller,
    required double width,
    required int itemCount,
    required String Function(int) label,
    required ValueChanged<int> onChanged,
  }) {
    return SizedBox(
      key: key,
      width: width,
      child: CupertinoTheme(
        data: const CupertinoThemeData(brightness: Brightness.dark),
        child: CupertinoPicker.builder(
          scrollController: controller,
          itemExtent: 40,
          diameterRatio: 1.4,
          squeeze: 1.1,
          selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
            background: _gold.withValues(alpha: 0.10),
          ),
          onSelectedItemChanged: onChanged,
          childCount: itemCount,
          itemBuilder: (ctx, i) => Center(
            child: Text(
              label(i),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
