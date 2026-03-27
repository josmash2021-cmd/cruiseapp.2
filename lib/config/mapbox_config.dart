/// Mapbox configuration — token and style URLs.
class MapboxConfig {
  MapboxConfig._();

  static const String accessToken = String.fromEnvironment(
    'MAPBOX_TOKEN',
    defaultValue: 'pk.eyJ1Ijoicm95YWxwdXJwbGVjb3JwIiwiYSI6ImNtbHk4cmpsNjExamwzZm9sOGFobXZoZTMifQ.YNkz-m3W7noKKDKbwn9y3w',
  );

  // ── Style URLs — dark-v11 uses standard layer IDs compatible with our navy/gold theme ──
  static const String _darkV11 = 'mapbox://styles/mapbox/dark-v11';

  static const String styleDark        = _darkV11;
  static const String styleLight       = _darkV11;
  static const String styleNavigation  = _darkV11;
  static const String styleGameNavigation = _darkV11;
}
