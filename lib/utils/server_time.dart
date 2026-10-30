/// A server timestamp as LOCAL time — the only form any screen should
/// format or count down from.
///
/// Owner report 2026-10-30: a reservation for 1:40 PM Miami showed 5:40 PM
/// on the Miami driver's phone. The backend sends UTC ("...17:40:00+00:00");
/// `DateTime.parse` keeps it as a UTC DateTime and `DateFormat` prints its
/// UTC fields. A tz-naive string is UTC too (SQLite rows serialize without
/// an offset), never local time.
DateTime? parseServerTime(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  final dt = DateTime.tryParse(s);
  if (dt == null) return null;
  final utc = dt.isUtc
      ? dt
      : DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
          dt.millisecond, dt.microsecond);
  return utc.toLocal();
}
