import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the camera-write coalescing (2026-10-23, owner ask "mucho más
/// smooth"): nearly-identical frames must NOT go to native — only a real
/// pose change (>0.3 m, >0.5°, >0.02 zoom) or 100 ms since the last write.
/// The arrow overlay keeps 60 fps; the native map stops re-rendering
/// identical frames (less GPU, less heat on long shifts).
void main() {
  final driver = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final chase = File('lib/map/tracking_map_camera.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the driver chase coalesces nearly-identical frames', () {
    expect(driver, contains('_lastCamWriteOpts'),
        reason: 'the last written pose is tracked');
    expect(driver, contains('dtMs < 100'),
        reason: '100 ms since the last write always lets one through');
    expect(driver, contains('dLatM < 0.3'));
    expect(driver, contains('dLngM < 0.3'));
    expect(driver, contains('dBrg.abs() < 0.5'),
        reason: 'bearing changes below 0.5° are coalesced');
    expect(driver, contains('dZoom.abs() < 0.02'),
        reason: 'zoom changes below 0.02 are coalesced');
    // The gate sits BEFORE the latest-wins pending write, so a skipped frame
    // never queues a redundant native call — and the newest pose still goes
    // out the moment it actually changed.
    final gateIdx = driver.indexOf('dtMs < 100');
    final pendingIdx = driver.indexOf('_pendingCamWrite = options;');
    expect(gateIdx, greaterThan(-1));
    expect(pendingIdx, greaterThan(gateIdx));
  });

  test('the rider chase coalesces nearly-identical frames', () {
    expect(chase, contains('_lastWrittenCenter'));
    expect(chase, contains('dtMs < 100'));
    expect(chase, contains('dLatM < 0.3'));
    expect(chase, contains('dLngM < 0.3'));
    expect(chase, contains('dBrg < 0.5'));
    expect(chase, contains('dZoom < 0.02'));
    expect(chase, contains('_lastWrittenAt = now;'));
    // The gate runs after the non-finite check and before the in-flight
    // write, so a dropped frame costs nothing and the next tick redraws.
    final gateIdx = chase.indexOf('dtMs < 100');
    final inFlightIdx = chase.lastIndexOf('_frameInFlight = true;');
    expect(gateIdx, greaterThan(-1));
    expect(inFlightIdx, greaterThan(gateIdx));
  });
}
