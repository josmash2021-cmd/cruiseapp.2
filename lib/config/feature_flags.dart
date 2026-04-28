import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Feature flags for A/B testing and gradual rollouts.
///
/// Priority (highest to lowest):
///   1. Runtime override (setSocketIOOverride) — for dev/testing
///   2. Firebase Remote Config — for gradual rollout in production
///   3. Default value — safe fallback
///
/// Usage:
///   if (FeatureFlags.useSocketIO) { ... }
///
/// To force enable for testing:
///   FeatureFlags.setSocketIOOverride(true);
class FeatureFlags {
  static bool? _socketIOOverride;
  static bool? _remoteConfigSocketIO;
  static bool _remoteConfigInitialized = false;

  /// Whether to use Socket.io as the primary real-time channel.
  /// When false, the app falls back to Firebase RTDB + HTTP polling.
  static bool get useSocketIO {
    // 1. Runtime override (highest priority)
    if (_socketIOOverride != null) return _socketIOOverride!;
    // 2. Firebase Remote Config
    if (_remoteConfigInitialized && _remoteConfigSocketIO != null) {
      return _remoteConfigSocketIO!;
    }
    // 3. Default value
    return _defaultSocketIO;
  }

  /// Default value — true for production (Socket.io is the primary
  /// real-time channel, much faster than Firebase RTDB + HTTP polling).
  static final bool _defaultSocketIO = true;

  /// Runtime override for testing (e.g. in dev builds or beta tester groups).
  static void setSocketIOOverride(bool enabled) {
    _socketIOOverride = enabled;
    debugPrint('[FeatureFlags] Socket.io override set to: $enabled');
  }

  /// Reset override to default.
  static void clearSocketIOOverride() {
    _socketIOOverride = null;
  }

  /// Initialize Firebase Remote Config.
  /// Call this after Firebase is initialized.
  static Future<void> initRemoteConfig() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      await remoteConfig.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(hours: 1),
      ));
      await remoteConfig.setDefaults(const {
        'use_socket_io': false,
        'socket_io_rollout_percentage': 0,
      });
      await remoteConfig.fetchAndActivate();

      final boolValue = remoteConfig.getBool('use_socket_io');
      final rolloutPct = remoteConfig.getInt('socket_io_rollout_percentage');

      _remoteConfigSocketIO = boolValue || rolloutPct > 0;
      _remoteConfigInitialized = true;

      debugPrint(
        '[FeatureFlags] Remote Config: use_socket_io=$boolValue, '
        'rollout_percentage=$rolloutPct',
      );
    } catch (e) {
      debugPrint('[FeatureFlags] Remote Config init failed: $e');
      _remoteConfigInitialized = false;
    }
  }

  /// Force refresh Remote Config values.
  static Future<void> refresh() async {
    if (!_remoteConfigInitialized) {
      await initRemoteConfig();
      return;
    }
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      final updated = await remoteConfig.fetchAndActivate();
      if (updated) {
        final boolValue = remoteConfig.getBool('use_socket_io');
        _remoteConfigSocketIO = boolValue;
        debugPrint('[FeatureFlags] Remote Config refreshed: use_socket_io=$boolValue');
      }
    } catch (e) {
      debugPrint('[FeatureFlags] Remote Config refresh failed: $e');
    }
  }
}
