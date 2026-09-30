import 'package:flutter/material.dart';

/// Age in full years at [today] (defaults to the device's current date) —
/// the same birthday-not-yet arithmetic as backend `compute_age`.
int computeAge(DateTime dob, [DateTime? today]) {
  // Pure calendar dates vs the UTC date — the exact ruler the backend's
  // compute_age uses, so an 18th/25th birthday evening can't pass the app
  // gate and then bounce off the server's (local date behind UTC).
  final nowUtc = (today ?? DateTime.now()).toUtc();
  final dUtc = DateTime.utc(dob.year, dob.month, dob.day);
  var years = nowUtc.year - dUtc.year;
  if (nowUtc.month < dUtc.month ||
      (nowUtc.month == dUtc.month && nowUtc.day < dUtc.day)) {
    years--;
  }
  return years;
}

/// The shared registration date-of-birth picker (user spec 2026-09-27:
/// riders 18+, drivers 25+). Dark-themed Material date picker opening
/// exactly on the minimum-allowed birthday; future dates are not pickable.
/// Validation still happens on submit — the server re-gates every write.
Future<DateTime?> pickDateOfBirth(BuildContext context,
    {required int minAge, DateTime? initial}) {
  final now = DateTime.now();
  final minBirthday = DateTime(now.year - minAge, now.month, now.day);
  return showDatePicker(
    context: context,
    initialDate: initial ?? minBirthday,
    firstDate: DateTime(1920),
    lastDate: now,
    builder: (context, child) => Theme(
      data: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE8C547),
          onPrimary: Colors.black,
          surface: Color(0xFF1A1D24),
          onSurface: Colors.white,
        ),
      ),
      child: child!,
    ),
  );
}
