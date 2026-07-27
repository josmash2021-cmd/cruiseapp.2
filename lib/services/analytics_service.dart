import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Singleton analytics service wrapping Firebase Analytics.
///
/// Provides typed methods for all key app events so screens don't
/// need to know about Firebase directly.
///
/// Privacy: every event is gated behind the "Usage Analytics" toggle
/// (`privacy_analytics` in SharedPreferences) — when disabled, all
/// logging is a no-op and Firebase collection is turned off.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  late final FirebaseAnalytics _analytics;
  bool _initialized = false;
  bool _enabled = true;

  /// Initialize — call once from main.dart during startup.
  Future<void> init() async {
    if (_initialized) return;
    try {
      _analytics = FirebaseAnalytics.instance;
      _initialized = true;
      // Honor the persisted "Usage Analytics" privacy toggle so the
      // choice survives across sessions.
      try {
        final prefs = await SharedPreferences.getInstance();
        _enabled = prefs.getBool('privacy_analytics') ?? true;
        await _analytics.setAnalyticsCollectionEnabled(_enabled);
      } catch (_) {}
      debugPrint('[Analytics] Initialized');
    } catch (e) {
      debugPrint('[Analytics] Init failed: $e');
    }
  }

  /// Master switch for the "Usage Analytics" privacy toggle.
  /// Also forwards the flag to Firebase Analytics collection.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!_initialized) return;
    try {
      await _analytics.setAnalyticsCollectionEnabled(value);
    } catch (e) {
      debugPrint('[Analytics] setEnabled error: $e');
    }
  }

  /// Navigator observer for automatic screen tracking.
  /// Returns a no-op observer if analytics hasn't been initialized yet.
  NavigatorObserver get observer {
    if (!_initialized) return NavigatorObserver();
    return FirebaseAnalyticsObserver(analytics: _analytics);
  }

  // ── User identity ──────────────────────────────────────

  Future<void> setUserId(String? userId) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.setUserId(id: userId);
    } catch (e) {
      debugPrint('[Analytics] setUserId error: $e');
    }
  }

  Future<void> setUserType(String type) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.setUserProperty(name: 'user_type', value: type);
    } catch (e) {
      debugPrint('[Analytics] setUserType error: $e');
    }
  }

  Future<void> setCity(String city) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.setUserProperty(name: 'city', value: city);
    } catch (e) {
      debugPrint('[Analytics] setCity error: $e');
    }
  }

  Future<void> setPreferredVehicle(String vehicle) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.setUserProperty(name: 'preferred_vehicle', value: vehicle);
    } catch (e) {
      debugPrint('[Analytics] setPreferredVehicle error: $e');
    }
  }

  // ── Screen views ───────────────────────────────────────

  Future<void> logScreenView(String screenName) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logScreenView(screenName: screenName);
    } catch (e) {
      debugPrint('[Analytics] logScreenView error: $e');
    }
  }

  // ── Auth events ────────────────────────────────────────

  Future<void> logSignUp(String method) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logSignUp(signUpMethod: method);
    } catch (e) {
      debugPrint('[Analytics] logSignUp error: $e');
    }
  }

  Future<void> logLogin(String method) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logLogin(loginMethod: method);
    } catch (e) {
      debugPrint('[Analytics] logLogin error: $e');
    }
  }

  // ── Ride events ────────────────────────────────────────

  Future<void> logRideRequested(String vehicleType, double fare) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'ride_requested',
        parameters: {
          'vehicle_type': vehicleType,
          'fare': fare,
        },
      );
    } catch (e) {
      debugPrint('[Analytics] logRideRequested error: $e');
    }
  }

  Future<void> logRideCompleted(
    String vehicleType,
    double fare,
    double distance,
    int durationMinutes,
  ) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'ride_completed',
        parameters: {
          'vehicle_type': vehicleType,
          'fare': fare,
          'distance': distance,
          'duration_minutes': durationMinutes,
        },
      );
    } catch (e) {
      debugPrint('[Analytics] logRideCompleted error: $e');
    }
  }

  Future<void> logRideCancelled(String reason, bool byDriver) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'ride_cancelled',
        parameters: {
          'reason': reason,
          'by_driver': byDriver.toString(),
        },
      );
    } catch (e) {
      debugPrint('[Analytics] logRideCancelled error: $e');
    }
  }

  // ── Driver events ──────────────────────────────────────

  Future<void> logDriverOnline() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'driver_online');
    } catch (e) {
      debugPrint('[Analytics] logDriverOnline error: $e');
    }
  }

  Future<void> logDriverOffline() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'driver_offline');
    } catch (e) {
      debugPrint('[Analytics] logDriverOffline error: $e');
    }
  }

  Future<void> logRideOffered() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'ride_offered');
    } catch (e) {
      debugPrint('[Analytics] logRideOffered error: $e');
    }
  }

  Future<void> logRideAccepted() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'ride_accepted');
    } catch (e) {
      debugPrint('[Analytics] logRideAccepted error: $e');
    }
  }

  Future<void> logRideDeclined() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'ride_declined');
    } catch (e) {
      debugPrint('[Analytics] logRideDeclined error: $e');
    }
  }

  // ── Payment events ─────────────────────────────────────

  Future<void> logPaymentAdded(String method) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'payment_added',
        parameters: {'method': method},
      );
    } catch (e) {
      debugPrint('[Analytics] logPaymentAdded error: $e');
    }
  }

  // ── Promo events ───────────────────────────────────────

  Future<void> logPromoApplied(String code) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'promo_applied',
        parameters: {'code': code},
      );
    } catch (e) {
      debugPrint('[Analytics] logPromoApplied error: $e');
    }
  }

  // ── Error tracking ─────────────────────────────────────

  Future<void> logError(String errorType, String message) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'app_error',
        parameters: {
          'error_type': errorType,
          'message': message.length > 100 ? message.substring(0, 100) : message,
        },
      );
    } catch (e) {
      debugPrint('[Analytics] logError error: $e');
    }
  }

  // ── Background check ───────────────────────────────────

  Future<void> logBackgroundCheckInitiated() async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: 'background_check_initiated');
    } catch (e) {
      debugPrint('[Analytics] logBackgroundCheckInitiated error: $e');
    }
  }

  Future<void> logBackgroundCheckCompleted(String status) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(
        name: 'background_check_completed',
        parameters: {'status': status},
      );
    } catch (e) {
      debugPrint('[Analytics] logBackgroundCheckCompleted error: $e');
    }
  }

  // ── Generic event ──────────────────────────────────────

  Future<void> logEvent(String name, {Map<String, Object>? parameters}) async {
    if (!_initialized || !_enabled) return;
    try {
      await _analytics.logEvent(name: name, parameters: parameters);
    } catch (e) {
      debugPrint('[Analytics] logEvent($name) error: $e');
    }
  }
}
