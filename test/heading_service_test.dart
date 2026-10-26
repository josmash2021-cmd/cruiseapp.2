import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/services/heading_service.dart';

void main() {
  test('slow compass motion keeps emitting below the old half-degree gate',
      () async {
    final input = StreamController<double>.broadcast(sync: true);
    var now = DateTime.utc(2026, 1, 1);
    final service = HeadingService(
      compassReadings: input.stream,
      now: () => now,
    );
    final values = <double>[];
    final subscription = service.stream.listen(values.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await input.close();
    });

    service.start();
    input.add(0.0);
    for (var i = 1; i <= 12; i++) {
      now = now.add(const Duration(milliseconds: 60));
      input.add(i * 0.1);
    }
    await Future<void>.delayed(Duration.zero);

    expect(values.length, greaterThanOrEqualTo(3));
    expect(values.any((value) => value > 0 && value < 0.5), isTrue);
    expect(values.every((value) => value.isFinite), isTrue);
  });

  test('compass smoothing follows the shortest arc across north', () async {
    final input = StreamController<double>.broadcast(sync: true);
    var now = DateTime.utc(2026, 1, 1);
    final service = HeadingService(
      compassReadings: input.stream,
      now: () => now,
    );
    final values = <double>[];
    final subscription = service.stream.listen(values.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await input.close();
    });

    service.start();
    input.add(359.0);
    now = now.add(const Duration(milliseconds: 60));
    input.add(1.0);
    await Future<void>.delayed(Duration.zero);

    expect(values, hasLength(2));
    expect(values.last, greaterThan(359.0));
    expect(values.last, lessThan(360.0));
  });
}
