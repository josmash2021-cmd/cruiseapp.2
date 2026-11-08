import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/airport_airlines.dart';
import '../services/api_service.dart';
import '../services/places_service.dart' show PlaceType;
import 'place_glyph.dart';

/// An airline's real mark (owner 2026-11-08: "deben ser los íconos de las
/// aerolíneas reales"): its square logo, served from the backend at
/// /static/airlines/{IATA}.png and cached on the phone. A charter, a name we
/// have no logo for, or a logo still loading / that can't load shows the
/// plane line mark instead.
class AirlineLogo extends StatelessWidget {
  const AirlineLogo(this.airline, {super.key, this.size = 38});

  final String airline;
  final double size;

  @visibleForTesting
  static ImageProvider Function(String url) providerFor =
      (url) => CachedNetworkImageProvider(url);

  /// Where [airline]'s logo lives, or null without one.
  static String? urlFor(String airline) {
    final code = airlineIataFor(airline);
    if (code == null) return null;
    return '${ApiService.publicBaseUrl}/static/airlines/$code.png';
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.3);
    final plane = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFE8C547).withValues(alpha: 0.12),
        borderRadius: radius,
      ),
      child: PlaceGlyph(PlaceType.airport, size: size * 0.55),
    );
    final url = urlFor(airline);
    if (url == null) return plane;
    return ClipRRect(
      borderRadius: radius,
      child: Image(
        image: providerFor(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: airline,
        frameBuilder: (_, child, frame, sync) =>
            frame == null && !sync ? plane : child,
        errorBuilder: (_, __, ___) => plane,
      ),
    );
  }
}
