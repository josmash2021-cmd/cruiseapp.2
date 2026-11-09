import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/calendar_service.dart';
import '../widgets/feathered_image.dart';
import '../widgets/neu_style.dart';
import '../widgets/reservation_card.dart';
import 'ride_booking_confirmed_screen.dart';
import 'schedule_datetime_screen.dart';
import 'schedule_flow_entry.dart';

/// Schedule hub — the rider's "Trips" page (2026-08-22, Lyft-style clone in
/// navy/gold): "Schedule a ride" into the datetime page, the rider's
/// reservations ("Tus reservas", the shared [ReservationCard]; a tap opens
/// the reservation's page, where it is cancelled), then Smart planning tools
/// with the calendars card. With reservations they come first and the hero
/// photo + headline step aside (owner 2026-11-08) — the pitch is for a rider
/// who has none.
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
  // home uses for its next-scheduled-ride card. The last list is kept for
  // the next open, so the page does not show the pitch and then swap it
  // for the reservations a moment later — only for the same account: one
  // phone, several accounts, and another rider's trips must never show.
  static List<Map<String, dynamic>> _lastRides = const [];
  static int? _lastRidesUser;
  List<Map<String, dynamic>> _rides = const [];

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
      if (userId == _lastRidesUser && _rides.isEmpty && mounted) {
        setState(() => _rides = _lastRides);
      }
      final trips = await ApiService.getScheduledTrips(userId);
      const dismissed = {'completed', 'canceled', 'cancelled'};
      final rides = trips.where((t) {
        final status = (t['status'] as String? ?? '').toLowerCase();
        if (dismissed.contains(status)) return false;
        final sa = Reservation.parseAt(t['scheduled_at']);
        return sa != null && sa.isAfter(DateTime.now());
      }).toList();
      _lastRides = rides;
      _lastRidesUser = userId;
      if (mounted) setState(() => _rides = rides);
    } catch (_) {}
  }

  /// The reservation's page (map, who is coming, cancel). Back with `true`
  /// = cancelled there: the card fades out here.
  Future<void> _openRide(Map<String, dynamic> t) async {
    final r = Reservation.fromTrip(t);
    if (r == null) return;
    final cancelled = await Navigator.of(context).push<bool>(
      slideFromRightRoute(RideBookingConfirmedScreen.reservation(r)),
    );
    if (!mounted) return;
    final id = r.id;
    if (cancelled == true && id != null) {
      setState(() => _cancellingIds.add(id));
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() {
        _cancellingIds.remove(id);
        _rides = _rides
            .where((x) => (x['id'] as num?)?.toInt() != id)
            .toList();
        _lastRides = _rides;
      });
    }
    unawaited(_loadRides());
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

  /// Hub → Depart/Arrive wheels FIRST, then addresses (2026-08-29, user spec).
  /// The rider picks date/time before entering the address search; once the
  /// address pair is confirmed we continue to the shared booking tail.
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

    // 1) Date/time first — the wheels page has no addresses yet.
    final record = await Navigator.of(context)
        .push<(DateTime, Map<String, dynamic>?)>(
      slideUpFadeRoute(ScheduleDateTimeScreen(
        initialPickupLat: lat,
        initialPickupLng: lng,
        initialDateTime: prefill,
      )),
    );
    if (record == null || !mounted) return;
    final (scheduledAt, searchResult) = record;

    // 2) The wheels page either returns a complete searchResult (calendar
    //    shortcut or address-first chain) or it pushes the address search itself
    //    and pops the final pair — in both cases we just run the booking tail.
    if (searchResult != null) {
      await continueScheduleToBooking(
        context,
        scheduledAt: scheduledAt,
        searchResult: searchResult,
        fallbackPickupLat: lat,
        fallbackPickupLng: lng,
      );
    }
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
                SizedBox(height: _rides.isEmpty ? 22 : 18),

                // The pitch is for a rider with no reservations.
                if (_rides.isEmpty) ...[
                  // ── Hero: full-bleed photo with feathered edges (the same
                  // FeatheredImage every other hero wears — it dissolves into
                  // the navy ground instead of ending in a hard crop).
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: -24),
                    child: const FeatheredImage(
                      'assets/images/schedule_hero.jpg',
                      width: double.infinity,
                      height: 190,
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
                ],

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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.yourRidesTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${_rides.length}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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
    final r = Reservation.fromTrip(t);
    if (r == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ReservationCard(
        reservation: r,
        onTap: () => _openRide(t),
      ),
    );
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
              const Icon(Icons.calendar_month_rounded,
                  color: _gold, size: 30),
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
