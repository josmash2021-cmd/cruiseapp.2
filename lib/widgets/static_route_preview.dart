import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';

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
    this.borderRadius = 0,
  });

  final double pickupLat;
  final double pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
  final double borderRadius;

  bool get _hasDropoff => dropoffLat != null && dropoffLng != null;

  /// Gold pickup pin, white dropoff pin, bounds fitted to both.
  String _url(int w, int h) {
    final token = MapboxConfig.accessToken;
    String f(double v) => v.toStringAsFixed(5);
    final pickup = 'pin-s+E8C547(${f(pickupLng)},${f(pickupLat)})';
    final overlay = _hasDropoff
        ? '$pickup,pin-s+FFFFFF(${f(dropoffLng!)},${f(dropoffLat!)})'
        : pickup;
    // "auto" frames both pins. With a single pin it has nothing to frame, so
    // an explicit centre and zoom are required or Mapbox returns a 422.
    final view = _hasDropoff
        ? 'auto'
        : '${f(pickupLng)},${f(pickupLat)},13,0';
    return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '$overlay/$view/${w}x$h@2x'
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
