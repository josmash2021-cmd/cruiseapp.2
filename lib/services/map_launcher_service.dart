import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launches external map apps for turn-by-turn navigation,
/// respecting the user's preference in Settings → Navigation.
class MapLauncherService {
  MapLauncherService._();

  /// Open the user-preferred map app for navigation to [destLat],[destLng].
  /// Falls back to Google Maps if the preferred app can't open.
  static Future<void> navigate({
    required double destLat,
    required double destLng,
    String? destLabel,
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final preferred = prefs.getString('nav_default_map') ?? 'cruise';
    final tolls = prefs.getBool('nav_avoid_tolls') ?? false;
    final highways = prefs.getBool('nav_avoid_highways') ?? false;

    // 'cruise' means use in-app navigation — caller handles this
    if (preferred == 'cruise') return;

    final avoid = <String>[];
    if (avoidTolls || tolls) avoid.add('tolls');
    if (avoidHighways || highways) avoid.add('highways');

    Uri? uri;
    switch (preferred) {
      case 'google':
        uri = _googleMapsUri(destLat, destLng, avoid);
        break;
      case 'apple':
        uri = _appleMapsUri(destLat, destLng, avoid);
        break;
      case 'waze':
        uri = _wazeUri(destLat, destLng);
        break;
    }

    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      // Fallback to Google Maps web
      final fallback = _googleMapsUri(destLat, destLng, avoid);
      if (await canLaunchUrl(fallback)) {
        await launchUrl(fallback, mode: LaunchMode.externalApplication);
      }
    }
  }

  /// Returns true if the user prefers in-app (Cruise Maps) navigation.
  static Future<bool> prefersInApp() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('nav_default_map') ?? 'cruise') == 'cruise';
  }

  static Uri _googleMapsUri(double lat, double lng, List<String> avoid) {
    final avoidParam = avoid.isNotEmpty ? '&avoid=${avoid.join('|')}' : '';
    return Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving$avoidParam',
    );
  }

  static Uri _appleMapsUri(double lat, double lng, List<String> avoid) {
    // Apple Maps on iOS; opens browser on Android
    final dirflg = <String>[];
    if (avoid.contains('tolls')) dirflg.add('t');
    if (avoid.contains('highways')) dirflg.add('h');
    final flags = dirflg.isNotEmpty ? '&dirflg=${dirflg.join('')}' : '';
    return Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d$flags');
  }

  static Uri _wazeUri(double lat, double lng) {
    return Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');
  }
}
