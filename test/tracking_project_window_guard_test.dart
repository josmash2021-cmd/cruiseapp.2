import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guardian for the iOS 1.1.2(727) crash reported by the
/// Crashlytics stability alert (2026-10-11, 16 crashes / 1 rider):
///
///   FlutterError — RangeError (length): Invalid value: Not in inclusive…
///   package:cruise_app/widgets/tracking/tracking_map_view.dart
///
/// `_projectInSegRange` clamped `to` to `n` (the POINT count) instead of
/// `n - 1` (the last SEGMENT bound), so with a projection hint near the
/// route's end the loop read `_routePts[n]` and killed the tracking screen.
void main() {
  final src = File('lib/widgets/tracking/tracking_map_view.dart')
      .readAsStringSync();

  test('the segment window never clamps past the last segment', () {
    // CRLF-agnostic needles (the file is CRLF).
    expect(src, contains('from = from.clamp(0, n - 2);'),
        reason: 'segment indices run 0..n-2');
    expect(src, contains('to = to.clamp(from + 1, n - 1);'),
        reason: '`to` is exclusive → n-1, never n (n read _routePts[n] and '
            'crashed the rider tracking screen)');
    expect(src, contains('if (n < 2) return (0, double.infinity, 0.0);'),
        reason: 'single-point routes short-circuit before any index math');
    expect(src.contains('to = to.clamp(from + 1, n);'), isFalse,
        reason: 'the old clamp to n is the crash — it must stay dead');
  });
}
