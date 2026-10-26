import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/map_gesture_guard.dart';

void main() {
  test('a tap and a tiny move never release follow', () {
    final guard = MapGestureGuard();
    expect(guard.pointerDown(const Offset(20, 20), 1), isFalse);
    expect(guard.pointerMove(const Offset(23, 24), 1), isFalse);
    guard.pointerUp(0);
    expect(guard.isActive, isFalse);
  });

  test('a real drag activates once until the last finger is lifted', () {
    final guard = MapGestureGuard();
    guard.pointerDown(const Offset(20, 20), 1);
    expect(guard.pointerMove(const Offset(30, 30), 1), isTrue);
    expect(guard.isActive, isTrue);
    expect(guard.pointerMove(const Offset(40, 40), 1), isFalse);
    guard.pointerUp(0);
    expect(guard.isActive, isFalse);
    expect(guard.pointerMove(const Offset(50, 50), 1), isFalse);
  });

  test('a second finger activates pinch and cancel resets the guard', () {
    final guard = MapGestureGuard();
    expect(guard.pointerDown(const Offset(20, 20), 2), isTrue);
    expect(guard.pointerDown(const Offset(40, 40), 2), isFalse);
    guard.reset();
    expect(guard.isActive, isFalse);
  });
}
