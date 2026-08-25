import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/calendar_service.dart';
import '../widgets/neu_style.dart';
import 'pickup_dropoff_search_screen.dart';
import 'schedule_cancel_policy_screen.dart';

/// Schedule hub — the rider's "Trips" page (2026-08-22, Lyft-style clone in
/// navy/gold): hero + "Schedule a ride" into the datetime page, the rider's
/// active reservations ("Your rides", hidden when empty, with detail sheet +
/// fee-aware cancel), then Smart planning tools with the calendars card.
/// There is intentionally no price-lock card — pricing promises need a
/// product decision first.
class ScheduleHubScreen extends StatefulWidget {
  const ScheduleHubScreen({super.key});

  @override
  State<ScheduleHubScreen> createState() => _ScheduleHubScreenState();
}

class _ScheduleHubScreenState extends State<ScheduleHubScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _calendarConnected = false;
  bool _calendarDenied = false;
  bool _calendarBusy = false;
  List<dynamic> _events = const []; // device_calendar_plus Event

  // "Your rides": the rider's active reservations, from the same endpoint
  // home uses for its next-scheduled-ride card.
  List<Map<String, dynamic>> _rides = const [];
  bool _ridesBusy = false;

  /// Ids currently fading out after a confirmed cancel (2026-08-25): the
  /// card collapses and dissolves in place instead of vanishing on reload.
  final Set<int> _cancellingIds = {};

  @override
  void initState() {
    super.initState();
    _restoreCalendarState();
    _loadRides();
  }

  /// Active reservations = not terminal and still in the future (same
  /// filter HomeScreen._loadNextScheduledRide applies to this endpoint).
  Future<void> _loadRides() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null) return;
      final trips = await ApiService.getScheduledTrips(userId);
      const dismissed = {'completed', 'canceled', 'cancelled'};
      final rides = trips.where((t) {
        final status = (t['status'] as String? ?? '').toLowerCase();
        if (dismissed.contains(status)) return false;
        final sa = _parseSchedAt(t);
        return sa != null && sa.isAfter(DateTime.now());
      }).toList();
      if (mounted) setState(() => _rides = rides);
    } catch (_) {}
  }

  /// Backend stores UTC; SQLite rows serialize tz-naive, so a naive
  /// timestamp must be read as UTC, not as local time.
  static DateTime? _parseSchedAt(Map<String, dynamic> t) {
    final raw = t['scheduled_at']?.toString();
    if (raw == null || raw.isEmpty) return null;
    final dt = DateTime.tryParse(raw);
    if (dt == null) return null;
    return dt.isUtc
        ? dt
        : DateTime.utc(
            dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
  }

  static String _tierLabel(dynamic vehicleType) {
    final raw = (vehicleType as String? ?? '').trim();
    if (raw.isEmpty) return 'Standard';
    return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
  }

  /// App-side mirror of `_scheduled_cancel_fee` in backend/routers/trips.py:
  /// free with no driver or more than 60 min out, otherwise the tier fee
  /// (kScheduledCancelFeesUsd, the same table the policy page shows) capped
  /// by the upfront fare. The dialog is an estimate — the backend's number
  /// is the one actually captured.
  static double _estimatedCancelFee(Map<String, dynamic> t) {
    if (t['driver_id'] == null) return 0;
    final sa = _parseSchedAt(t);
    if (sa != null && sa.difference(DateTime.now()).inMinutes > 60) return 0;
    final fee =
        (kScheduledCancelFeesUsd[_tierLabel(t['vehicle_type'])] ?? 15)
            .toDouble();
    final fare = (t['fare'] as num?)?.toDouble() ?? 0;
    return fare > 0 && fare < fee ? fare : fee;
  }

  /// The card reads "connected" from our flag AND the live OS grant — a
  /// rider who revoked access in Settings sees it fall back to disconnected.
  Future<void> _restoreCalendarState() async {
    final connected = await CalendarService.isConnected();
    final granted = await CalendarService.hasSystemGrant();
    if (!mounted) return;
    if (connected && granted) {
      setState(() => _calendarConnected = true);
      _loadEvents();
    }
  }

  Future<void> _connectCalendar() async {
    if (_calendarBusy) return;
    setState(() {
      _calendarBusy = true;
      _calendarDenied = false;
    });
    try {
      final granted = await CalendarService.connect();
      if (!mounted) return;
      if (granted) {
        setState(() => _calendarConnected = true);
        await _loadEvents();
      } else {
        // Denied (or iOS limited-but-not-full): the card offers Settings —
        // re-asking in-app is a dead tap on iOS.
        setState(() => _calendarDenied = true);
      }
    } finally {
      if (mounted) setState(() => _calendarBusy = false);
    }
  }

  Future<void> _loadEvents() async {
    final events = await CalendarService.upcomingEvents();
    if (mounted) setState(() => _events = events);
  }

  /// Hub → addresses page (schedule chain mode) → the page itself drives
  /// the Depart/Arrive wheels (with the real route estimate) and the
  /// booking tail. Nothing to continue here — the chain owns itself.
  Future<void> _openScheduleFlow({DateTime? prefill}) async {
    double? lat;
    double? lng;
    try {
      final pos = await Geolocator.getLastKnownPosition()
          .timeout(const Duration(milliseconds: 400), onTimeout: () => null);
      lat = pos?.latitude;
      lng = pos?.longitude;
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context).push(
      slideUpFadeRoute(PickupDropoffSearchScreen(
        initialPickupLat: lat,
        initialPickupLng: lng,
        scheduleChain: true,
        schedulePrefill: prefill,
      )),
    );
  }

  /// Month table instead of DateFormat: the project never calls
  /// initializeDateFormatting, so DateFormat(pattern, 'es') throws.
  String _eventWhen(DateTime dt, bool isEs) {
    const monthsEn = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const monthsEs = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    final m = isEs ? monthsEs[dt.month - 1] : monthsEn[dt.month - 1];
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return isEs
        ? '${dt.day} $m · $h12:$mm $ampm'
        : '$m ${dt.day} · $h12:$mm $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
            child: RefreshIndicator(
              color: _gold,
              backgroundColor: neuSurface,
              onRefresh: _onRefresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              children: [
                // ── Centered title + close ──
                Padding(
                  padding: const EdgeInsets.only(top: 10),
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
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 20),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            s.scheduleHubTitle,
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
                const SizedBox(height: 22),

                // ── Hero: full-bleed photo (edge-to-edge, breaks the
                // ListView's 24px padding), title sits BELOW the photo.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: -24),
                  child: Image.asset(
                    'assets/images/schedule_hero.jpg',
                    width: double.infinity,
                    height: 190,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  s.scheduleHubHeadline,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  s.scheduleHubSubtext,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),

                // ── Schedule a ride ──
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: () => _openScheduleFlow(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      s.scheduleARide,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // ── Your rides (active reservations; hidden when none) ──
                if (_rides.isNotEmpty) ...[
                  Text(
                    s.yourRidesTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Cards animate in (staggered fade+rise) and a cancelled
                  // one fades/collapses out (2026-08-25).
                  ..._rides.asMap().entries.map(
                      (e) => _animatedRideCard(e.key, e.value)),
                  const SizedBox(height: 18),
                ],

                // ── Smart planning tools ──
                Text(
                  s.scheduleHubToolsTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                _calendarCard(s),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _loadRides();
    if (_calendarConnected) await _loadEvents();
  }

  /// One reservation card with its two lifecycle animations: a staggered
  /// fade+rise when the list appears (a fresh booking lands with motion,
  /// not a pop), and a fade+collapse when the rider cancels it.
  Widget _animatedRideCard(int index, Map<String, dynamic> t) {
    final id = (t['id'] as num?)?.toInt() ?? -index - 1;
    final cancelling = _cancellingIds.contains(id);
    return TweenAnimationBuilder<double>(
      key: ValueKey('ride_card_$id'),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + (index * 70).clamp(0, 350)),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - v)),
          child: child,
        ),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: cancelling ? 0.0 : 1.0,
          child: cancelling
              ? const SizedBox(width: double.infinity)
              : _rideCard(t),
        ),
      ),
    );
  }

  Widget _rideCard(Map<String, dynamic> t) {
    final s = S.of(context);
    final sa = _parseSchedAt(t)?.toLocal();
    final pickup = (t['pickup_address'] as String? ?? '').trim();
    final dropoff = (t['dropoff_address'] as String? ?? '').trim();
    final hasDriver = t['driver_id'] != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _showRideDetail(t),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: neuBox(radius: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sa != null ? _eventWhen(sa, s.isSpanish) : '',
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: hasDriver
                          ? _gold
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      hasDriver ? s.driverAssignedLabel : s.findingDriverLabel,
                      style: TextStyle(
                        color: hasDriver ? Colors.black : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _addressRow(Icons.trip_origin_rounded, pickup),
              const SizedBox(height: 4),
              _addressRow(Icons.location_on_rounded, dropoff),
              const SizedBox(height: 6),
              Text(
                _tierLabel(t['vehicle_type']),
                style:
                    const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressRow(IconData icon, String address) {
    return Row(
      children: [
        Icon(icon, color: _gold, size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            address,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// Reservation detail sheet: full data + policy link + Cancel ride.
  Future<void> _showRideDetail(Map<String, dynamic> t) async {
    final s = S.of(context);
    final sa = _parseSchedAt(t)?.toLocal();
    final fare = (t['fare'] as num?)?.toDouble();
    final hasDriver = t['driver_id'] != null;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: neuSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 18, 24, 24 + MediaQuery.of(sheetCtx).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              sa != null ? _eventWhen(sa, s.isSpanish) : '',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_tierLabel(t['vehicle_type'])} · '
              '${hasDriver ? s.driverAssignedLabel : s.findingDriverLabel}'
              '${fare != null && fare > 0 ? ' · \$${fare.toStringAsFixed(2)}' : ''}',
              style: const TextStyle(color: _gold, fontSize: 13.5),
            ),
            const SizedBox(height: 16),
            _addressRow(Icons.trip_origin_rounded,
                (t['pickup_address'] as String? ?? '').trim()),
            const SizedBox(height: 6),
            _addressRow(Icons.location_on_rounded,
                (t['dropoff_address'] as String? ?? '').trim()),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () => Navigator.of(sheetCtx).push(slideUpFadeRoute(
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
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _ridesBusy
                    ? null
                    : () {
                        Navigator.of(sheetCtx).pop();
                        _confirmCancelRide(t);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3A1C22),
                  foregroundColor: const Color(0xFFFF6B6B),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                        color: const Color(0xFFFF6B6B)
                            .withValues(alpha: 0.45)),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  s.cancelRide,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirmation shows the fee for THIS reservation's window/tier (the
  /// backend applies the same rule and returns the captured fee).
  Future<void> _confirmCancelRide(Map<String, dynamic> t) async {
    final s = S.of(context);
    final fee = _estimatedCancelFee(t);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: neuSurface,
        title: Text(s.cancelRideQuestion,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800)),
        content: Text(
          '${s.cancelRideConfirm}\n\n'
          '${fee <= 0 ? s.rideCancelFreeNote : s.rideCancelFeeNote(fee.toStringAsFixed(0))}',
          style: const TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(false),
            child: Text(s.keep,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop(true),
            child: Text(s.cancelRide,
                style: const TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _ridesBusy = true);
    final id = t['id'] as int;
    // Fade+collapse the card right away; the API call runs under the
    // animation. On failure the card comes back.
    setState(() => _cancellingIds.add(id));
    try {
      final resFuture = ApiService.cancelTrip(id);
      // Let the exit animation play before the row leaves the list.
      final res = await resFuture.timeout(const Duration(seconds: 15));
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() {
        _cancellingIds.remove(id);
        _rides = _rides
            .where((r) => (r['id'] as num?)?.toInt() != id)
            .toList();
      });
      final charged = (res['cancellation_fee'] as num?)?.toDouble() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(charged > 0
            ? s.rideCancelledFee(charged.toStringAsFixed(2))
            : s.rideCancelled),
      ));
    } catch (_) {
      if (mounted) {
        setState(() => _cancellingIds.remove(id)); // restore the card
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.somethingWentWrong)));
      }
    } finally {
      if (mounted) setState(() => _ridesBusy = false);
      _loadRides();
    }
  }

  Widget _calendarCard(S s) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: neuBox(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.event_note_rounded,
                    color: _gold, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.calendarCardTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.calendarCardSubtitle,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_calendarConnected) ...[
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _calendarBusy ? null : _connectCalendar,
                icon: const Icon(Icons.apple_rounded, size: 20),
                label: Text(
                  s.calendarConnectButton,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13)),
                  elevation: 0,
                ),
              ),
            ),
            if (_calendarDenied) ...[
              const SizedBox(height: 12),
              Text(
                s.calendarDeniedBody,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => openAppSettings(),
                child: Text(
                  s.openSettings,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                    decorationColor: _gold,
                  ),
                ),
              ),
            ],
          ] else ...[
            if (_events.isEmpty)
              Text(
                s.calendarNoEvents,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12.5),
              )
            else
              ..._events.map((e) => _eventRow(e, s)),
          ],
        ],
      ),
    );
  }

  Widget _eventRow(dynamic e, S s) {
    final title = (e.title as String?)?.trim() ?? '';
    final location = (e.location as String?)?.trim() ?? '';
    final start = e.startDate as DateTime;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: neuBox(radius: 14, pressed: true),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? s.calendarUntitledEvent : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _eventWhen(start.toLocal(), s.isSpanish),
                    style: const TextStyle(color: _gold, fontSize: 12.5),
                  ),
                  if (location.isNotEmpty)
                    Text(
                      location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // The shortcut pre-fills the wheels with the event's start.
            GestureDetector(
              onTap: () => _openScheduleFlow(prefill: start.toLocal()),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  s.calendarScheduleRide,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
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
