import 'package:cruise_app/services/rider_heat_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Heat zones (owner 2026-11-05): a typed pickup / dropoff reaches the
/// server at once, never steps back down, and repeats are not spammed.
void main() {
  late List<String> sent;
  late List<Map<String, Object?>> payloads;
  late List<String> typed;
  late DateTime now;
  late bool foreground;

  RiderHeatReporter make({Duration heartbeat = const Duration(hours: 1)}) =>
      RiderHeatReporter(
        sender: ({
          required step,
          required lat,
          required lng,
          address,
          dropoffLat,
          dropoffLng,
          dropoffAddress,
        }) async {
          sent.add('$step@${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}');
          payloads.add({
            'step': step,
            'lat': lat,
            'lng': lng,
            'address': address,
            'dropoff_lat': dropoffLat,
            'dropoff_lng': dropoffLng,
            'dropoff_address': dropoffAddress,
          });
          return true;
        },
        typingSender: ({required field}) async {
          typed.add(field);
          return true;
        },
        clock: () => now,
        inForeground: () => foreground,
        heartbeat: heartbeat,
      );

  setUp(() {
    sent = [];
    payloads = [];
    typed = [];
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

  // Panel live list (owner 2026-11-07): the addresses the rider sees and
  // the chosen dropoff ride along with the heat signal.
  test('a "current location" placeholder is never sent as the address', () {
    for (final label in ['Ubicación actual', 'Current location', ' your location ']) {
      final r = make();
      r.pickup(33.4, -86.8, pickupAddress: label);
      expect(payloads.last['address'], isNull, reason: label);
      r.reset();
    }
  });

  test('pickup carries its address; dropoff carries the dropoff point', () {
    final r = make();
    r.pickup(33.4, -86.8, pickupAddress: ' 100 Main St ');
    expect(payloads.last['address'], '100 Main St');
    expect(payloads.last['dropoff_lat'], isNull);
    r.dropoff(33.4, -86.8,
        pickupAddress: '100 Main St',
        dropoffLat: 33.56,
        dropoffLng: -86.75,
        dropoffAddress: 'BHM Airport');
    expect(payloads.last, {
      'step': 'dropoff',
      'lat': 33.4,
      'lng': -86.8,
      'address': '100 Main St',
      'dropoff_lat': 33.56,
      'dropoff_lng': -86.75,
      'dropoff_address': 'BHM Airport',
    });
    r.reset();
  });

  test('dropoff point is both coordinates or neither', () {
    final r = make();
    r.dropoff(33.4, -86.8, dropoffLat: 33.56, dropoffAddress: 'Somewhere');
    expect(payloads.last['dropoff_lat'], isNull);
    expect(payloads.last['dropoff_lng'], isNull);
    expect(payloads.last['dropoff_address'], 'Somewhere');
    r.reset();
  });

  test('a new dropoff at the same pickup is sent at once', () {
    final r = make();
    r.dropoff(33.4, -86.8, dropoffLat: 33.56, dropoffLng: -86.75);
    r.dropoff(33.4, -86.8, dropoffLat: 33.50, dropoffLng: -86.70);
    expect(payloads.length, 2);
    expect(payloads.last['dropoff_lat'], 33.50);
    // Same everything again: dropped.
    r.dropoff(33.4, -86.8, dropoffLat: 33.50, dropoffLng: -86.70);
    expect(payloads.length, 2);
    r.reset();
  });

  test('a later pickup at step 3 keeps the chosen dropoff', () {
    final r = make();
    r.dropoff(33.4, -86.8,
        dropoffLat: 33.56, dropoffLng: -86.75, dropoffAddress: 'BHM Airport');
    r.pickup(33.42, -86.8, pickupAddress: '200 Oak Ave');
    expect(payloads.last['step'], 'dropoff');
    expect(payloads.last['address'], '200 Oak Ave');
    expect(payloads.last['dropoff_lat'], 33.56);
    expect(payloads.last['dropoff_address'], 'BHM Airport');
    r.reset();
  });

  test('addresses are capped at 300 characters', () {
    final r = make();
    r.pickup(33.4, -86.8, pickupAddress: 'x' * 400);
    expect((payloads.last['address']! as String).length, 300);
    r.reset();
  });

  test('the heartbeat re-sends the same full payload', () async {
    final r = make(heartbeat: const Duration(milliseconds: 30));
    r.dropoff(33.4, -86.8,
        pickupAddress: '100 Main St',
        dropoffLat: 33.56,
        dropoffLng: -86.75,
        dropoffAddress: 'BHM Airport');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(payloads.length, greaterThan(1));
    for (final p in payloads) {
      expect(p, payloads.first);
    }
    r.reset();
  });

  test('typing: once at once, then at most every 20 s per field', () {
    final r = make();
    r.typing('pickup', 'M');
    r.typing('pickup', 'Ma');
    expect(typed, ['pickup']);
    r.typing('dropoff', 'A');
    expect(typed, ['pickup', 'dropoff']);
    now = now.add(const Duration(seconds: 19));
    r.typing('pickup', 'Mai');
    expect(typed.length, 2);
    now = now.add(const Duration(seconds: 2));
    r.typing('pickup', 'Main');
    expect(typed, ['pickup', 'dropoff', 'pickup']);
  });

  test('typing: empty text and unknown fields send nothing', () {
    final r = make();
    r.typing('pickup', '   ');
    r.typing('stop', 'Main');
    expect(typed, isEmpty);
  });

  test('typing: a picked address ends the run, the next keystroke sends', () {
    final r = make();
    r.typing('dropoff', 'Ai');
    r.typingDone();
    r.typing('dropoff', 'Air');
    expect(typed, ['dropoff', 'dropoff']);
  });
}
