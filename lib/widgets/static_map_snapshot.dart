import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';
import '../models/lat_lng.dart';

/// A still frame of the dark map centred on [center], drawn by Mapbox's
/// Static Images API — the same dark-v11 the live maps run, wearing the
/// same navy veil the route thumbnails wear.
///
/// Exists for the offline→online handoff (driver spec 2026-08-22): two
/// live Mapbox surfaces can never overlap (that is the iOS crash), so
/// while one screen's native map is down and the other's is still coming
/// up, this image stands in. The driver sees the same map the whole way
/// across — a brief still, not a black loading screen.
class StaticMapSnapshot extends StatelessWidget {
  const StaticMapSnapshot({super.key, required this.center, this.zoom = 16});

  final LatLng center;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The API caps a request at 1280 px per side, and rejects 0.
        final w = box.maxWidth.isFinite
            ? box.maxWidth.round().clamp(64, 1280)
            : 640;
        final h = box.maxHeight.isFinite
            ? box.maxHeight.round().clamp(64, 1280)
            : 960;
        const dark = ColoredBox(color: Color(0xFF07080D));
        final token = MapboxConfig.accessToken;
        if (token.isEmpty) return dark;
        String f(double v) => v.toStringAsFixed(6);
        final url =
            'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
            '${f(center.longitude)},${f(center.latitude)},$zoom,0/${w}x$h@2x'
            '?logo=false&attribution=false&access_token=$token';
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              url,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => dark,
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : dark,
            ),
            // The Static Images API cannot recolour layers — a factory
            // dark-v11 render comes back grey, and the app's live maps read
            // navy. Same veil StaticRoutePreview paints, same reason.
            IgnorePointer(
              child: ColoredBox(
                color: const Color(0xFF0A1128).withValues(alpha: 0.30),
              ),
            ),
          ],
        );
      },
    );
  }
}
