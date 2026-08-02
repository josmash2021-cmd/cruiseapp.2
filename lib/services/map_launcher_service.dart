import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launches external map apps for turn-by-turn navigation,
/// respecting the user's preference in Settings → Navigation.
class MapLauncherService {
  MapLauncherService._();

  /// Open the driver's chosen map app for navigation to [destLat],[destLng].
  ///
  /// Returns true when an app was actually launched. False means the caller
  /// should do whatever it did before: either the driver prefers in-app
  /// navigation, or the chosen app is not installed and could not open.
  ///
  /// This used to return void and be called from one place, with no
  /// coordinates, so it never launched anything. Settings → Navigation was
  /// decorative: the default map app and both route preferences were saved
  /// and read by nobody.
  static Future<bool> navigate({
    required double destLat,
    required double destLng,
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final preferred = prefs.getString('nav_default_map') ?? 'cruise';

    // 'cruise' means in-app navigation — the caller owns that.
    if (preferred == 'cruise') return false;

    final avoid = <String>[];
    if (avoidTolls || (prefs.getBool('nav_avoid_tolls') ?? false)) {
      avoid.add('tolls');
    }
    if (avoidHighways || (prefs.getBool('nav_avoid_highways') ?? false)) {
      avoid.add('highways');
    }

    // Native scheme first, web URL second. The native scheme opens the
    // installed app directly; the web URL is what a phone without it can
    // still follow.
    for (final uri in _urisFor(preferred, destLat, destLng, avoid)) {
      try {
        if (await canLaunchUrl(uri)) {
          if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            return true;
          }
        }
      } catch (_) {
        // Try the next one rather than failing the whole navigation.
      }
    }
    return false;
  }

  /// Returns true if the user prefers in-app (Cruise Maps) navigation.
  static Future<bool> prefersInApp() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('nav_default_map') ?? 'cruise') == 'cruise';
  }

  static List<Uri> _urisFor(
    String app,
    double lat,
    double lng,
    List<String> avoid,
  ) {
    switch (app) {
      case 'google':
        return [
          // Android's turn-by-turn intent. It takes no avoid flags, so it
          // is second when the driver asked to avoid something and first
          // when they did not — a route that starts navigating beats a
          // route that only opens.
          if (avoid.isEmpty) Uri.parse('google.navigation:q=$lat,$lng&mode=d'),
          Uri.parse('comgooglemaps://?daddr=$lat,$lng&directionsmode=driving'),
          _googleMapsUri(lat, lng, avoid),
          if (avoid.isNotEmpty)
            Uri.parse('google.navigation:q=$lat,$lng&mode=d'),
        ];
      case 'apple':
        return [_appleMapsUri(lat, lng, avoid)];
      case 'waze':
        // Waze has no avoid parameters in its deep link at all. The
        // driver's toggles cannot reach it, and pretending otherwise by
        // appending something it ignores would be worse.
        return [
          Uri.parse('waze://?ll=$lat,$lng&navigate=yes'),
          Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes'),
        ];
      default:
        return [_googleMapsUri(lat, lng, avoid)];
    }
  }

  static Uri _googleMapsUri(double lat, double lng, List<String> avoid) {
    final avoidParam = avoid.isNotEmpty ? '&avoid=${avoid.join('|')}' : '';
    return Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving$avoidParam',
    );
  }

  static Uri _appleMapsUri(double lat, double lng, List<String> avoid) {
    // One dirflg, not two. This used to build `dirflg=d&dirflg=th`, and a
    // repeated parameter means Apple reads one of them and drops the
    // other — so either driving mode or the avoid flags were lost,
    // silently. The flags belong in the same value: `dirflg=dth`.
    final flags = StringBuffer('d');
    if (avoid.contains('tolls')) flags.write('t');
    if (avoid.contains('highways')) flags.write('h');
    return Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=$flags');
  }
}
