import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03 ("arma todo"): each tier's "in X min" is the real wait
/// for that tier — from the nearest driver of it (DriverWaitEstimate) — not
/// the trip's own duration plus 2-3 minutes, which is what RideOption's
/// etaMinutes carries.
void main() {
  final src = File('lib/screens/ride_request_widgets.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the tier row shows the tier\'s real range', () {
    expect(src, contains(': _gridWaitRangeText(_tierKeyForOption(opt));'));
    expect(src, isNot(contains('? S.of(context).inMinEta(opt.etaMinutes)')));
  });

  test('the selected card line too, with when the car would be there', () {
    final i = src.indexOf('String _tierEtaLine(RideOption opt) {');
    final body = src.substring(i, i + 1200);
    expect(body, contains('DriverWaitEstimate.cached(pickup.lat, pickup.lng,'));
    expect(body, contains("return '\${est.rangeLabel} · \${_fmtClock(eta)}';"));
    expect(body, isNot(contains('opt.etaMinutes')));
  });
}
