import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/places_service.dart';
import '../../widgets/neu_style.dart';
import 'pickup_dropoff_search_screen.dart';
import 'schedule_cancel_policy_screen.dart';

/// "Schedule a ride" — Depart/Arrive date-time page (2026-08-22).
///
/// Cupertino wheels (day / hour / minute / AM-PM) over the dark neu ground.
/// Earliest bookable: now + 30 min; latest: +30 days. On Next the page
/// pushes the pickup/dropoff search ON TOP of itself (back returns to the
/// wheels, same contract as the legacy time screen) and pops with
/// `(scheduledAt, searchResult)` once the rider confirms addresses.
///
/// [estimatedMinutes] is the pickup→dropoff drive time when the caller
/// already knows it — the "Estimated ride time" / Drop-off / Pickup lines
/// render only then (at this point in the flow addresses come later, so
/// the hub passes null and the lines stay out).
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
  /// the record and into the booking notes ("Stop: …").
  final String? prefilledStopAddress;

  @override
  State<ScheduleDateTimeScreen> createState() =>
      _ScheduleDateTimeScreenState();
}

class _ScheduleDateTimeScreenState extends State<ScheduleDateTimeScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _minLeadMinutes = 30;
  static const _maxDays = 30;

  /// false = Depart (rider picks the pickup time), true = Arrive (rider
  /// picks the drop-off time; pickup is derived when the estimate exists).
  bool _arriveMode = false;

  late DateTime _selected;

  late final FixedExtentScrollController _dayCtrl;
  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minCtrl;
  late final FixedExtentScrollController _ampmCtrl;

  /// Days offered: today .. today+30d.
  late final DateTime _day0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _day0 = DateTime(now.year, now.month, now.day);
    final minTime = now.add(const Duration(minutes: _minLeadMinutes));
    final seed = widget.initialDateTime;
    _selected = seed != null && seed.isAfter(minTime) ? seed : minTime;

    _dayCtrl = FixedExtentScrollController(
        initialItem: _selected.difference(_day0).inDays);
    _hourCtrl =
        FixedExtentScrollController(initialItem: _hour12Index(_selected));
    _minCtrl = FixedExtentScrollController(
        initialItem: (_selected.minute / 5).floor());
    _ampmCtrl =
        FixedExtentScrollController(initialItem: _selected.hour >= 12 ? 1 : 0);
  }

  @override
  void dispose() {
    _dayCtrl.dispose();
    _hourCtrl.dispose();
    _minCtrl.dispose();
    _ampmCtrl.dispose();
    super.dispose();
  }

  int _hour12Index(DateTime d) {
    final h = d.hour % 12;
    return h == 0 ? 11 : h - 1; // wheel order: 12,1,2,...,11
  }

  DateTime _compose(int dayIdx, int hourIdx, int minIdx, int ampmIdx) {
    final day = _day0.add(Duration(days: dayIdx));
    var hour = hourIdx == 0 ? 12 : hourIdx + 1; // wheel 0 shows "12"
    if (ampmIdx == 1 && hour != 12) hour += 12;
    if (ampmIdx == 0 && hour == 12) hour = 0;
    return DateTime(day.year, day.month, day.day, hour, minIdx * 5);
  }

  void _onWheelChange() {
    setState(() {
      _selected = _compose(
        _dayCtrl.selectedItem,
        _hourCtrl.selectedItem,
        _minCtrl.selectedItem,
        _ampmCtrl.selectedItem,
      );
    });
  }

  /// The booking time for the backend: the PICKUP time. In Arrive mode the
  /// rider's choice is the drop-off time — subtract the drive estimate when
  /// we have one; without one (addresses not chosen yet) the chosen time is
  /// the pickup time itself.
  DateTime get _scheduledForBooking {
    if (!_arriveMode) return _selected;
    final est = widget.estimatedMinutes;
    if (est == null) return _selected;
    return _selected.subtract(Duration(minutes: est));
  }

  String _fmtTime(DateTime d) {
    final h24 = d.hour;
    final pm = h24 >= 12;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h12:$mm ${pm ? 'PM' : 'AM'}';
  }

  Future<void> _onNext() async {
    // Clamp into the bookable window instead of erroring — the wheels can
    // sit on "today, 25 min from now".
    final minTime =
        DateTime.now().add(const Duration(minutes: _minLeadMinutes));
    var scheduledAt = _scheduledForBooking;
    if (scheduledAt.isBefore(minTime)) scheduledAt = minTime;
    final maxTime = DateTime.now().add(const Duration(days: _maxDays));
    if (scheduledAt.isAfter(maxTime)) scheduledAt = maxTime;

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
    final est = widget.estimatedMinutes;
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
                            () => setState(() => _arriveMode = false)),
                        _tab(s.schedArrive, _arriveMode,
                            () => setState(() => _arriveMode = true)),
                      ],
                    ),
                  ),
                ),

                // ── Wheels ──
                Expanded(
                  child: Center(
                    child: SizedBox(
                      height: 220,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _wheel(
                            controller: _dayCtrl,
                            width: 128,
                            itemCount: _maxDays + 1,
                            label: (i) => _dayLabel(i, s),
                          ),
                          _wheel(
                            controller: _hourCtrl,
                            width: 62,
                            itemCount: 12,
                            label: (i) => i == 0 ? '12' : '$i',
                          ),
                            _wheel(
                              controller: _minCtrl,
                              width: 62,
                              itemCount: 12,
                              label: (i) =>
                                  (i * 5).toString().padLeft(2, '0'),
                            ),
                          _wheel(
                            controller: _ampmCtrl,
                            width: 66,
                            itemCount: 2,
                            label: (i) => i == 0 ? 'AM' : 'PM',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Estimate block (only with a known route time) ──
                if (est != null) ...[
                  Text(
                    s.schedEstimatedRideTime(est),
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _arriveMode
                        ? s.schedPickupAt(_fmtTime(_selected
                            .subtract(Duration(minutes: est))))
                        : s.schedDropoffAt(
                            _fmtTime(_selected.add(Duration(minutes: est)))),
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
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
                      onPressed: _onNext,
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
    final d = _day0.add(Duration(days: i));
    if (i == 0) return s.schedToday;
    if (i == 1) return s.schedTomorrow;
    const wdEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const wdEs = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
    final wd = s.isSpanish ? wdEs[d.weekday - 1] : wdEn[d.weekday - 1];
    return '$wd ${d.month}/${d.day}';
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required double width,
    required int itemCount,
    required String Function(int) label,
  }) {
    return SizedBox(
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
          onSelectedItemChanged: (_) => _onWheelChange(),
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
