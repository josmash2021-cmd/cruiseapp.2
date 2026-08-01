import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';
import '../models/lat_lng.dart';

/// A non-interactive route thumbnail, drawn by Mapbox's Static Images API.
///
/// This exists because a list may show many of them at once. The live
/// `MapWidget` it replaces is a native PlatformView, and every card that
/// mounted one added another live Mapbox surface — three scheduled rides on
/// screen meant three of them, which is the iOS crash where the app simply
/// closes. An image has no such limit.
///
/// Only use this where the map is a preview. Anything the driver or rider
/// pans, zooms or watches a car move on still needs a real map — and that
/// one must claim [MapSurfaceCoordinator] so only one is ever alive.
class StaticRoutePreview extends StatelessWidget {
  const StaticRoutePreview({
    super.key,
    required this.pickupLat,
    required this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
    this.route = const <LatLng>[],
    this.borderRadius = 0,
  });

  final double pickupLat;
  final double pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;

  /// The driving route, if it has been fetched. Drawn as the same gold line
  /// the live map used to draw. Empty means pins only.
  final List<LatLng> route;

  final double borderRadius;

  bool get _hasDropoff => dropoffLat != null && dropoffLng != null;

  /// The most points we will put in the URL.
  ///
  /// A static-image request is a GET, and a cross-town route can be a couple
  /// of thousand points — well past what a URL can carry. Sixty is enough
  /// that the line still traces the roads at thumbnail size, and it is a
  /// hard ceiling rather than a hope: whatever comes in is sampled down to
  /// it. See [_simplify].
  static const int _maxRoutePoints = 60;

  /// Evenly sample [pts] down to at most [_maxRoutePoints], always keeping
  /// the first and last so the line still starts and ends at the pins.
  static List<LatLng> _simplify(List<LatLng> pts) {
    if (pts.length <= _maxRoutePoints) return pts;
    final step = (pts.length - 1) / (_maxRoutePoints - 1);
    return <LatLng>[
      for (var i = 0; i < _maxRoutePoints - 1; i++) pts[(i * step).floor()],
      pts.last,
    ];
  }

  /// Google's polyline algorithm, precision 5 — what Mapbox's `path` overlay
  /// expects.
  ///
  /// The counterpart of `DirectionsService._decodePolyline`, and it carries
  /// the same warning: on the web a Dart `int` is a double and `~` is an
  /// *unsigned* 32-bit operation, so `~v` there is 4294967295 - v rather
  /// than -(v + 1). This uses arithmetic that means the same thing on both.
  static String _encodePolyline(List<LatLng> pts) {
    final out = StringBuffer();
    var prevLat = 0, prevLng = 0;

    void chunk(int value) {
      // Negative numbers are inverted after the shift, which is the step the
      // web breaks on if written with ~.
      var v = value < 0 ? -(value * 2) - 1 : value * 2;
      while (v >= 0x20) {
        out.writeCharCode(((0x20 | (v & 0x1f)) + 63));
        v >>= 5;
      }
      out.writeCharCode(v + 63);
    }

    for (final p in pts) {
      final lat = (p.latitude * 1e5).round();
      final lng = (p.longitude * 1e5).round();
      chunk(lat - prevLat);
      chunk(lng - prevLng);
      prevLat = lat;
      prevLng = lng;
    }
    return out.toString();
  }

  /// Both halves of the URL arithmetic, for the tests. A wrong encoding
  /// fails as a broken image and nothing else, so it is checked against
  /// Google's published example rather than by looking at it.
  @visibleForTesting
  static String debugEncode(List<LatLng> pts) => _encodePolyline(pts);

  @visibleForTesting
  static List<LatLng> debugSimplify(List<LatLng> pts) => _simplify(pts);

  /// Decodes what [_encodePolyline] produced, so the round trip can be
  /// asserted. Only the tests need this — the app never reads these back.
  @visibleForTesting
  static List<LatLng> debugDecode(String poly) {
    final out = <LatLng>[];
    var i = 0, lat = 0, lng = 0;
    while (i < poly.length) {
      int shift = 0, result = 0, b;
      do {
        b = poly.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      // -(n + 1) rather than ~n — see _encodePolyline.
      lat += ((result & 1) != 0) ? -((result >> 1) + 1) : (result >> 1);

      shift = 0;
      result = 0;
      do {
        b = poly.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((result & 1) != 0) ? -((result >> 1) + 1) : (result >> 1);

      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  /// Gold pickup pin, white dropoff pin, the route between them, bounds
  /// fitted to whatever is present.
  String _url(int w, int h) {
    final token = MapboxConfig.accessToken;
    String f(double v) => v.toStringAsFixed(5);

    final parts = <String>[];
    // Drawn first so the pins sit on top of it rather than under.
    final line = route.length >= 2 ? _simplify(route) : const <LatLng>[];
    if (line.isNotEmpty) {
      // Escaped: an encoded polyline contains ?, #, & and \ — every one of
      // which ends or reinterprets the URL if it goes in raw.
      final encoded = Uri.encodeComponent(_encodePolyline(line));
      parts.add('path-4+E8C547-0.9($encoded)');
    }
    parts.add('pin-s+E8C547(${f(pickupLng)},${f(pickupLat)})');
    if (_hasDropoff) {
      parts.add('pin-s+FFFFFF(${f(dropoffLng!)},${f(dropoffLat!)})');
    }

    // "auto" frames everything in the overlay. With a single pin it has
    // nothing to frame, so an explicit centre and zoom are required or
    // Mapbox returns a 422.
    final view = (_hasDropoff || line.isNotEmpty)
        ? 'auto'
        : '${f(pickupLng)},${f(pickupLat)},13,0';

    return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '${parts.join(",")}/$view/${w}x$h@2x'
        '?padding=30&logo=false&attribution=false&access_token=$token';
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return ClipRRect(
      borderRadius: radius,
      child: LayoutBuilder(
        builder: (context, box) {
          // The API caps a request at 1280 px per side, and rejects 0.
          final w = box.maxWidth.isFinite
              ? box.maxWidth.round().clamp(64, 1280)
              : 640;
          final h =
              box.maxHeight.isFinite ? box.maxHeight.round().clamp(64, 1280) : 240;

          // No token injected at build time — show the placeholder rather
          // than a broken image.
          if (MapboxConfig.accessToken.isEmpty) return _placeholder();

          return Image.network(
            _url(w, h),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _placeholder(),
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : _placeholder(),
          );
        },
      ),
    );
  }

  Widget _placeholder() => const ColoredBox(
        color: Color(0xFF14141A),
        child: Center(
          child: Icon(
            Icons.route_rounded,
            color: Color(0x33E8C547),
            size: 28,
          ),
        ),
      );
}
