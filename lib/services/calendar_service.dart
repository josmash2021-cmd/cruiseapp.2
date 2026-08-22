import 'package:device_calendar_plus/device_calendar_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Apple Calendar read for the schedule hub's "Your calendars" card.
///
/// Thin wrapper over device_calendar_plus (the maintained fork — the
/// original device_calendar is abandoned and pinned to an old timezone
/// package). Read-only on purpose: Cruise suggests rides from upcoming
/// events, it never writes to the rider's calendar.
///
/// The "connected" state persists so the card survives restarts without
/// re-prompting; the OS grant itself is re-checked every open — a rider who
/// revoked access in Settings sees the card fall back to disconnected.
class CalendarService {
  CalendarService._();

  static const _connectedKey = 'calendar_connected_v1';

  static final DeviceCalendar _plugin = DeviceCalendar.instance;

  /// Last known grant from this install's own records.
  static Future<bool> isConnected() async {
    if (kIsWeb) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_connectedKey) == true;
    } catch (_) {
      return false;
    }
  }

  /// Ask for full calendar access (iOS 17 full tier, Android READ_CALENDAR).
  /// Returns true when granted. A grant is remembered; a denial is not, so
  /// the button can offer the Settings route instead.
  static Future<bool> connect() async {
    if (kIsWeb) return false;
    try {
      final status =
          await _plugin.requestPermissions(level: CalendarAccessLevel.full);
      final granted = status == CalendarPermissionStatus.granted;
      if (granted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_connectedKey, true);
      }
      return granted;
    } catch (e) {
      debugPrint('[Calendar] permission request failed: $e');
      return false;
    }
  }

  /// True when the OS grant is still in place, whatever our flag remembers.
  static Future<bool> hasSystemGrant() async {
    if (kIsWeb) return false;
    try {
      return await _plugin.hasPermissions() ==
          CalendarPermissionStatus.granted;
    } catch (_) {
      return false;
    }
  }

  /// Events in the next 7 days across every calendar, soonest first.
  /// Empty on web, on denial, or when the platform has none.
  static Future<List<Event>> upcomingEvents({int maxCount = 10}) async {
    if (kIsWeb) return const [];
    try {
      final now = DateTime.now();
      final events = await _plugin.listEvents(
        now,
        now.add(const Duration(days: 7)),
      );
      events.sort((a, b) => a.startDate.compareTo(b.startDate));
      if (events.length > maxCount) return events.sublist(0, maxCount);
      return events;
    } catch (e) {
      debugPrint('[Calendar] listEvents failed: $e');
      return const [];
    }
  }

  /// Forget the local flag (the OS grant itself is only revocable in
  /// Settings — nothing an app may do).
  static Future<void> disconnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_connectedKey);
    } catch (_) {}
  }
}
