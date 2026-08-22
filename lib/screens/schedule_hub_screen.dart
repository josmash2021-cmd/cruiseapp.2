import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/calendar_service.dart';
import '../widgets/neu_style.dart';
import 'pickup_dropoff_search_screen.dart';

/// Schedule hub — the rider's "Trips" page (2026-08-22, Lyft-style clone in
/// navy/gold): hero + "Schedule a ride" into the datetime page, then Smart
/// planning tools with the calendars card. There is intentionally no
/// price-lock card — pricing promises need a product decision first.
class ScheduleHubScreen extends StatefulWidget {
  const ScheduleHubScreen({super.key});

  @override
  State<ScheduleHubScreen> createState() => _ScheduleHubScreenState();
}

class _ScheduleHubScreenState extends State<ScheduleHubScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF0A1128);

  bool _calendarConnected = false;
  bool _calendarDenied = false;
  bool _calendarBusy = false;
  List<dynamic> _events = const []; // device_calendar_plus Event

  @override
  void initState() {
    super.initState();
    _restoreCalendarState();
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
            child: ListView(
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

                // ── Hero: gradient + calendar glyph (no generated art) ──
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 34),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_navy, Color(0xFF16244D)],
                    ),
                    border: Border.all(
                        color: _gold.withValues(alpha: 0.22), width: 1),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Soft gold bloom behind the glyph.
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              _gold.withValues(alpha: 0.30),
                              _gold.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                      const Icon(Icons.calendar_month_rounded,
                          color: _gold, size: 84),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  s.scheduleHubHeadline,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
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
        ],
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
