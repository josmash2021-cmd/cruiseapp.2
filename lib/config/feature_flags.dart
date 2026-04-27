/// Feature flags for A/B testing and gradual rollouts.
///
/// Flags can be overridden at runtime for testing:
///   FeatureFlags.setSocketIOOverride(true);
///
/// In production, these should be driven by Firebase Remote Config
/// or a similar remote flag system.
class FeatureFlags {
  static bool? _socketIOOverride;

  /// Whether to use Socket.io as the primary real-time channel.
  /// When false, the app falls back to Firebase RTDB + HTTP polling.
  static bool get useSocketIO => _socketIOOverride ?? _defaultSocketIO;

  /// Default value — false until Socket.io is fully validated.
  static bool _defaultSocketIO = false;

  /// Override for testing (e.g. in dev builds or beta tester groups).
  static void setSocketIOOverride(bool enabled) {
    _socketIOOverride = enabled;
  }

  /// Reset override to default.
  static void clearSocketIOOverride() {
    _socketIOOverride = null;
  }
}
