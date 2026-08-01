import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/widgets/static_route_preview.dart';

/// The encoder feeds a URL, and a wrong URL fails as a broken image rather
/// than as an error anyone would notice. So it is checked against Google's
/// own published example — the same one DirectionsService's decoder is
/// checked against, run the other way.
void main() {
  group('polyline encoding', () {
    // https://developers.google.com/maps/documentation/utilities/polylinealgorithm
    const canonical = r'_p~iF~ps|U_ulLnnqC_mqNvxq`@';
    final points = <LatLng>[
      LatLng(38.5, -120.2),
      LatLng(40.7, -120.95),
      LatLng(43.252, -126.453),
    ];

    test('matches the published example', () {
      expect(StaticRoutePreview.debugEncode(points), canonical);
    });

    test('a negative delta is not encoded as an unsigned one', () {
      // The bug this guards: `~v` is an unsigned 32-bit operation on the web,
      // so a southbound or westbound leg encodes to garbage there while
      // looking correct on a phone. Every leg below goes negative.
      final south = <LatLng>[
        LatLng(43.252, -126.453),
        LatLng(40.7, -120.95),
        LatLng(38.5, -120.2),
      ];
      final encoded = StaticRoutePreview.debugEncode(south);
      // Round-trips back to where it started, within the format's precision.
      final back = StaticRoutePreview.debugDecode(encoded);
      expect(back.length, south.length);
      for (var i = 0; i < south.length; i++) {
        expect(back[i].latitude, closeTo(south[i].latitude, 1e-5));
        expect(back[i].longitude, closeTo(south[i].longitude, 1e-5));
      }
    });

    test('an empty route encodes to nothing', () {
      expect(StaticRoutePreview.debugEncode(const <LatLng>[]), isEmpty);
    });
  });

  group('route simplification', () {
    test('leaves a short route alone', () {
      final pts = List.generate(12, (i) => LatLng(33.3 + i * 1e-4, -86.7));
      expect(StaticRoutePreview.debugSimplify(pts).length, 12);
    });

    test('caps a long one and keeps both ends', () {
      // A cross-town route really is this many points, and all of them in a
      // GET is a URL no server will accept.
      final pts = List.generate(2000, (i) => LatLng(33.3 + i * 1e-5, -86.7));
      final out = StaticRoutePreview.debugSimplify(pts);

      expect(out.length, lessThanOrEqualTo(60));
      expect(out.first.latitude, closeTo(pts.first.latitude, 1e-9),
          reason: 'the line must still start at the pickup pin');
      expect(out.last.latitude, closeTo(pts.last.latitude, 1e-9),
          reason: 'and end at the dropoff pin');
    });

    test('keeps the points in order', () {
      final pts = List.generate(500, (i) => LatLng(33.3 + i * 1e-5, -86.7));
      final out = StaticRoutePreview.debugSimplify(pts);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].latitude, greaterThan(out[i - 1].latitude));
      }
    });
  });
}
