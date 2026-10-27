import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class DriverShiftClock {
  static const stateTimezones = <String, String>{
    'AL': 'America/Chicago',
    'AK': 'America/Anchorage',
    'AZ': 'America/Phoenix',
    'AR': 'America/Chicago',
    'CA': 'America/Los_Angeles',
    'CO': 'America/Denver',
    'CT': 'America/New_York',
    'DE': 'America/New_York',
    'DC': 'America/New_York',
    'FL': 'America/New_York',
    'GA': 'America/New_York',
    'HI': 'Pacific/Honolulu',
    'ID': 'America/Boise',
    'IL': 'America/Chicago',
    'IN': 'America/Indiana/Indianapolis',
    'IA': 'America/Chicago',
    'KS': 'America/Chicago',
    'KY': 'America/New_York',
    'LA': 'America/Chicago',
    'ME': 'America/New_York',
    'MD': 'America/New_York',
    'MA': 'America/New_York',
    'MI': 'America/Detroit',
    'MN': 'America/Chicago',
    'MS': 'America/Chicago',
    'MO': 'America/Chicago',
    'MT': 'America/Denver',
    'NE': 'America/Chicago',
    'NV': 'America/Los_Angeles',
    'NH': 'America/New_York',
    'NJ': 'America/New_York',
    'NM': 'America/Denver',
    'NY': 'America/New_York',
    'NC': 'America/New_York',
    'ND': 'America/Chicago',
    'OH': 'America/New_York',
    'OK': 'America/Chicago',
    'OR': 'America/Los_Angeles',
    'PA': 'America/New_York',
    'RI': 'America/New_York',
    'SC': 'America/New_York',
    'SD': 'America/Chicago',
    'TN': 'America/Chicago',
    'TX': 'America/Chicago',
    'UT': 'America/Denver',
    'VT': 'America/New_York',
    'VA': 'America/New_York',
    'WA': 'America/Los_Angeles',
    'WV': 'America/New_York',
    'WI': 'America/Chicago',
    'WY': 'America/Denver',
    'PR': 'America/Puerto_Rico',
    'VI': 'America/Puerto_Rico',
    'GU': 'Pacific/Guam',
    'AS': 'Pacific/Pago_Pago',
    'MP': 'Pacific/Guam',
  };

  static bool _initialized = false;

  static void _ensureTimezones() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  static DateTime? localMidnightUtc(DateTime now, String? stateCode) {
    final zoneName = stateTimezones[(stateCode ?? '').trim().toUpperCase()];
    if (zoneName == null) return null;
    _ensureTimezones();
    final location = tz.getLocation(zoneName);
    final localNow = tz.TZDateTime.from(now.toUtc(), location);
    return tz.TZDateTime(
      location,
      localNow.year,
      localNow.month,
      localNow.day,
    ).toUtc();
  }

  static DateTime effectiveShiftStart(
    DateTime onlineSince,
    DateTime now,
    String? stateCode,
  ) {
    final start = onlineSince.toUtc();
    final midnight = localMidnightUtc(now, stateCode);
    if (midnight != null && midnight.isAfter(start)) return midnight;
    return start;
  }
}
