/// Mapbox configuration — token and style URLs.
class MapboxConfig {
  MapboxConfig._();

  static const String accessToken =
      'pk.eyJ1Ijoicm95YWxwdXJwbGVjb3JwIiwiYSI6ImNtbHk4cmpsNjExamwzZm9sOGFobXZoZTMifQ.YNkz-m3W7noKKDKbwn9y3w';

  // ── Style URLs — todos usan el mismo estilo oscuro tipo Google Maps ──
  static const String _nightNav = 'mapbox://styles/mapbox/navigation-night-v1';

  static const String styleDark        = _nightNav;
  static const String styleLight       = _nightNav;
  static const String styleNavigation  = _nightNav;
  static const String styleGameNavigation = _nightNav;
}
