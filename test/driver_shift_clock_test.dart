import 'package:cruise_app/utils/driver_shift_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('midnight resets the shift instead of carrying yesterday', () {
    final now = DateTime.utc(2026, 10, 27, 4, 30);
    final onlineSince = DateTime.utc(2026, 10, 26, 20);

    final start = DriverShiftClock.effectiveShiftStart(onlineSince, now, 'FL');

    expect(start, DateTime.utc(2026, 10, 27, 4));
    expect(now.difference(start), const Duration(minutes: 30));
  });

  test('Florida and Alabama have independent midnights', () {
    final onlineSince = DateTime.utc(2026, 10, 26, 20);
    final atFlMidnight = DateTime.utc(2026, 10, 27, 4, 30);

    expect(
      DriverShiftClock.effectiveShiftStart(onlineSince, atFlMidnight, 'FL'),
      DateTime.utc(2026, 10, 27, 4),
    );
    expect(
      DriverShiftClock.effectiveShiftStart(onlineSince, atFlMidnight, 'AL'),
      onlineSince,
    );

    final atAlMidnight = DateTime.utc(2026, 10, 27, 5, 30);
    expect(
      DriverShiftClock.effectiveShiftStart(onlineSince, atAlMidnight, 'AL'),
      DateTime.utc(2026, 10, 27, 5),
    );
  });

  test('local midnight follows DST rules', () {
    expect(
      DriverShiftClock.localMidnightUtc(DateTime.utc(2026, 3, 8, 9, 30), 'FL'),
      DateTime.utc(2026, 3, 8, 5),
    );
    expect(
      DriverShiftClock.localMidnightUtc(DateTime.utc(2026, 11, 1, 9, 30), 'FL'),
      DateTime.utc(2026, 11, 1, 4),
    );
  });

  test('unknown state keeps the legacy clock', () {
    final now = DateTime.utc(2026, 10, 27, 4, 30);
    final onlineSince = DateTime.utc(2026, 10, 26, 20);
    expect(
      DriverShiftClock.effectiveShiftStart(onlineSince, now, null),
      onlineSince,
    );
  });
}
