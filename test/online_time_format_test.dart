import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_onlineTimeText` in driver_home_screen.dart.
///
/// The formatter is private to a 3000-line State class, so it cannot be
/// imported. Kept here because the rules are easy to break by accident —
/// rounding 0.999 h to "1h 0min", or printing "0min" for a shift that has
/// not started — and the driver reads this number every time they open the
/// panel.
String onlineTimeText(double hours) {
  if (!hours.isFinite || hours <= 0) return '0h';
  final totalMinutes = (hours * 60).round();
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  if (h == 0) return '${m}min';
  if (m == 0) return '${h}h';
  return '${h}h ${m}min';
}

void main() {
  test('nothing yet reads as hours, not as zero minutes', () {
    expect(onlineTimeText(0), '0h');
    expect(onlineTimeText(-1), '0h');
    expect(onlineTimeText(double.nan), '0h');
    expect(onlineTimeText(double.infinity), '0h');
  });

  test('under an hour reads in minutes', () {
    expect(onlineTimeText(0.5), '30min');
    expect(onlineTimeText(0.25), '15min');
    expect(onlineTimeText(0.9), '54min');
    // A single minute still shows, rather than rounding away to "0h".
    expect(onlineTimeText(1 / 60), '1min');
  });

  test('whole hours drop the minutes', () {
    expect(onlineTimeText(1), '1h');
    expect(onlineTimeText(8), '8h');
  });

  test('hours and minutes together', () {
    expect(onlineTimeText(2.25), '2h 15min');
    expect(onlineTimeText(1.5), '1h 30min');
  });

  test('rounding never produces a 60-minute remainder', () {
    // 0.9999 h is 59.99 min — rounds to 60, which must carry into the hour
    // rather than printing "0h 60min".
    expect(onlineTimeText(0.9999), '1h');
    expect(onlineTimeText(3.9999), '4h');
  });
}
