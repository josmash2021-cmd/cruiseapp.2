import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

/// Stores and retrieves the logged-in user's session.
///
/// Uses the backend API for authentication and PostgreSQL for persistence.
/// Keeps a local cache in SharedPreferences for offline/quick access.
class UserSession {
  static const _key = 'user_session_v1';
  static const _modeKey = 'cruise_app_mode'; // 'rider' or 'driver'
  static const _photoKey = 'cruise_profile_photo_path'; // survives logout

  /// Global notifier for profile photo path changes.
  /// Screens can listen to this to update in real time.
  static final ValueNotifier<String> photoNotifier = ValueNotifier<String>('');

  // ── Save / Read local cache ─────────────────────────

  /// Save user data locally (cache after API call).
  static Future<void> saveUser({
    required String firstName,
    required String lastName,
    required String email,
    String? phone,
    String? photoPath,
    String? gender,
    String? paymentMethod,
    String? password,
    int? userId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'userId': userId?.toString() ?? '',
        'firstName': firstName,
        'lastName': lastName,
        'email': email,
        'phone': phone ?? '',
        'photoPath': photoPath ?? '',
        'gender': gender ?? '',
        'paymentMethod': paymentMethod ?? '',
        'password': password ?? '',
        'createdAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// Get the locally cached user, or null if not logged in.
  static Future<Map<String, String>?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;

    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return map.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } catch (_) {
      return null;
    }
  }

  /// Check if a user is logged in (has a valid JWT token).
  /// Resilient: keeps session alive even when backend is unreachable.
  static Future<bool> isLoggedIn() async {
    final token = await ApiService.getToken();
    if (token == null) return false;

    // Token exists — session is active.
    // Try to refresh profile from backend, but always stay logged in
    // regardless of backend response. Only explicit sign-out ends session.
    try {
      final profile = await ApiService.getMe();
      if (profile != null) return true;
    } catch (_) {
      // ignore
    }
    // Backend unavailable or returned error — trust local cache
    final user = await getUser();
    return user != null && (user['firstName']?.isNotEmpty ?? false);
  }

  /// Update a single field locally.
  static Future<void> updateField(String key, String value) async {
    final user = await getUser();
    if (user == null) return;
    user[key] = value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(user));
  }

  // ── Mode persistence (rider / driver) ────────────

  /// Save the current app mode ('rider' or 'driver').
  static Future<void> saveMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode);
  }

  /// Get the saved app mode. Defaults to 'rider'.
  static Future<String> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modeKey) ?? 'rider';
  }

  /// Log out — clear saved session, mode, and JWT token.
  /// Profile photo path is preserved so it survives sign-out/sign-in.
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_modeKey);
    await prefs.remove('pending_password');
    await ApiService.clearToken();
    ApiService.clearUserCache();
    photoNotifier.value = '';
  }

  /// Temporarily save a password during registration flow.
  static Future<void> savePendingPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_password', password);
  }

  /// Get the temporarily saved password.
  static Future<String?> getPendingPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pending_password');
  }

  /// Copy a picked image to the app’s permanent documents directory.
  /// Returns the permanent path. On web, returns the original path as-is.
  static Future<String> saveProfilePhoto(String tempPath) async {
    if (kIsWeb) {
      photoNotifier.value = tempPath;
      return tempPath;
    }
    final dir = await getApplicationDocumentsDirectory();
    final ext = tempPath.contains('.') ? tempPath.split('.').last : 'jpg';
    final permanent = File('${dir.path}/profile_photo.$ext');
    // Delete old photo if exists
    if (await permanent.exists()) {
      await permanent.delete();
    }
    await File(tempPath).copy(permanent.path);
    // Update session + persistent photo key
    await updateField('photoPath', permanent.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoKey, permanent.path);
    // Notify all listeners immediately
    photoNotifier.value = permanent.path;
    return permanent.path;
  }

  /// Initialize the photo notifier from stored session (call once at startup)
  static Future<void> initPhotoNotifier() async {
    final user = await getUser();
    final path = user?['photoPath'] ?? '';
    if (path.isNotEmpty) {
      photoNotifier.value = path;
      return;
    }
    // Fallback: check persistent photo key (survives logout)
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_photoKey) ?? '';
    if (saved.isNotEmpty && !kIsWeb && await File(saved).exists()) {
      photoNotifier.value = saved;
      // Also restore into session
      await updateField('photoPath', saved);
    }
  }

  /// Get the persisted photo path (survives logout).
  static Future<String> getPersistedPhotoPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoKey) ?? '';
  }
}
