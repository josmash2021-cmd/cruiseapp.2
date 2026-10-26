import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/services/resilient_position_stream.dart';

void main() {
  test('a moving stream gets a fast rebuild window', () {
    const base = Duration(seconds: 25);
    expect(
      ResilientPositionStream.staleAfterForSpeed(base, 8).inSeconds,
      8,
    );
    expect(
      ResilientPositionStream.staleAfterForSpeed(base, 1.2).inSeconds,
      8,
    );
  });

  test('stopped, slow or unknown speeds keep the long window', () {
    const base = Duration(seconds: 25);
    for (final speed in [0.0, 0.4, 1.19]) {
      expect(
        ResilientPositionStream.staleAfterForSpeed(base, speed),
        base,
      );
    }
  });

  test('the fast window never lengthens a shorter configured timeout', () {
    const base = Duration(seconds: 5);
    expect(ResilientPositionStream.staleAfterForSpeed(base, 8), base);
  });
}
