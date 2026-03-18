/// Mapbox configuration — token and style URLs.
class MapboxConfig {
  MapboxConfig._();

  static const String accessToken =
      'pk.eyJ1Ijoicm95YWxwdXJwbGVjb3JwIiwiYSI6ImNtbHk4cmpsNjExamwzZm9sOGFobXZoZTMifQ.YNkz-m3W7noKKDKbwn9y3w';

  // ── Style URLs ──
  static const String styleDark =
      'mapbox://styles/mapbox/navigation-night-v1';
  static const String styleLight =
      'mapbox://styles/mapbox/navigation-day-v1';
  static const String styleNavigation =
      'mapbox://styles/mapbox/navigation-night-v1';
  static const String styleGameNavigation =
      'asset://assets/mapbox/game-navigation-dark.json';
}
