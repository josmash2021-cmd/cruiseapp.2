import 'package:cruise_app/services/rider_heat_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Heat zones (owner 2026-11-05): a typed pickup / dropoff reaches the
/// server at once, never steps back down, and repeats are not spammed.
void main() {
  late List<String> sent;
  late DateTime now;
  late bool foreground;

  RiderHeatReporter make({Duration heartbeat = const Duration(hours: 1)}) =>
      RiderHeatReporter(
        sender: ({required step, required lat, required lng}) async {
          sent.add('$step@${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}');
          return true;
        },
        clock: () => now,
        inForeground: () => foreground,
        heartbeat: heartbeat,
      );

  setUp(() {
    sent = [];
    now = DateTime(2026, 11, 5, 9);
    foreground = true;
  });

  test('pickup then dropoff: two reports, both at the pickup', () {
    final r = make();
    r.pickup(33.4000, -86.8000);
    r.dropoff(33.4000, -86.8000);
    expect(sent, ['pickup@33.4000,-86.8000', 'dropoff@33.4000,-86.8000']);
    r.reset();
  });

  test('the same step at the same place within 25 s is dropped', () {
    final r = make();
    r.pickup(33.4, -86.8);
    now = now.add(const Duration(seconds: 10));
    r.pickup(33.40001, -86.80001);
    expect(sent.length, 1);
    now = now.add(const Duration(seconds: 20));
    r.pickup(33.4, -86.8);
    expect(sent.length, 2);
    r.reset();
  });

  test('a new pickup place is sent at once', () {
    final r = make();
    r.pickup(33.4, -86.8);
    r.pickup(33.41, -86.8);
    expect(sent.last, 'pickup@33.4100,-86.8000');
    r.reset();
  });

  test('never steps back down while planning', () {
    final r = make();
    r.dropoff(33.4, -86.8);
    r.pickup(33.42, -86.8);
    expect(r.step, 3);
    expect(sent.last, 'dropoff@33.4200,-86.8000');
    r.reset();
    expect(r.step, 0);
  });

  test('bad coordinates are ignored', () {
    final r = make();
    r.pickup(double.nan, -86.8);
    r.pickup(0, 0);
    expect(sent, isEmpty);
  });

  test('heartbeat re-sends in front, not in the background, and stops '
      'after the planning window', () async {
    final r = make(heartbeat: const Duration(milliseconds: 30));
    r.pickup(33.4, -86.8);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final inFront = sent.length;
    expect(inFront, greaterThan(1));
    foreground = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(sent.length, inFront);
    foreground = true;
    now = now.add(const Duration(minutes: 16));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(sent.length, inFront);
    expect(r.step, 0);
  });
}
