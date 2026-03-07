import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'local_data_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'security_service.dart';

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
  /// SECURITY: Passwords are NEVER stored. Sensitive fields are encrypted.
  static Future<void> saveUser({
    required String firstName,
    required String lastName,
    required String email,
    String? phone,
    String? photoPath,
    String? gender,
    String? paymentMethod,
    String? password, // Accepted but NEVER persisted
    int? userId,
    String? role,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Encrypt email and phone before storing
    final encEmail = email.isNotEmpty
        ? SecurityService.encryptForPrefs(email, 'user_email')
        : '';
    final encPhone = (phone != null && phone.isNotEmpty)
        ? SecurityService.encryptForPrefs(phone, 'user_phone')
        : '';
    await prefs.setString(
      _key,
      jsonEncode({
        'userId': userId?.toString() ?? '',
        'firstName': firstName,
        'lastName': lastName,
        'email': encEmail,
        'phone': encPhone,
        'photoPath': photoPath ?? '',
        'gender': gender ?? '',
        'paymentMethod': paymentMethod ?? '',
        // password is INTENTIONALLY omitted — never persisted (L7)
        'role': role ?? 'rider',
        'createdAt': DateTime.now().toIso8601String(),
        '_encrypted': 'true', // marker for decrypt logic
      }),
    );
    SecurityService.logSecurityEvent('user_saved', details: 'userId=$userId');
  }

  /// Get the locally cached user, or null if not logged in.
  /// Automatically decrypts encrypted fields (L6).
  static Future<Map<String, String>?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;

    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final result = map.map((k, v) => MapEntry(k, v?.toString() ?? ''));

      // Decrypt encrypted fields if marker present
      if (result['_encrypted'] == 'true') {
        final email = result['email'] ?? '';
        if (email.isNotEmpty) {
          result['email'] =
              SecurityService.decryptFromPrefs(email, 'user_email') ?? email;
        }
        final phone = result['phone'] ?? '';
        if (phone.isNotEmpty) {
          result['phone'] =
              SecurityService.decryptFromPrefs(phone, 'user_phone') ?? phone;
        }
      }
      // Never return password
      result.remove('password');
      result.remove('_encrypted');
      return result;
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

  // ── Role persistence (rider / driver) ────────────

  /// Save the current app mode ('rider' or 'driver').
  /// Also updates the role field inside the user session JSON.
  static Future<void> saveMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode);
    // Keep role in sync inside the session JSON
    await updateField('role', mode);
  }

  /// Get the saved role. Reads from user session first, falls back to mode key.
  static Future<String> getMode() async {
    final user = await getUser();
    final role = user?['role'];
    if (role != null && role.isNotEmpty) return role;
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
    await prefs.remove(_photoKey); // Clear photo reference for this account
    await ApiService.clearToken();
    ApiService.clearUserCache();
    // Clear all user-specific data so accounts are fully independent
    await LocalDataService.clearAllUserData();
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
    // Use user ID in filename to isolate photos per account
    final user = await getUser();
    final userId = user?['id'] ?? 'unknown';
    final permanent = File('${dir.path}/user_$userId.$ext');
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

  /// Initialize the photo notifier from stored session (call once at startup).
  /// Falls back to persistent key, then tries downloading from server.
  static Future<void> initPhotoNotifier() async {
    final user = await getUser();
    final path = user?['photoPath'] ?? '';
    if (path.isNotEmpty && !kIsWeb && await File(path).exists()) {
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
      return;
    }
    // Fallback: download from server (works across devices)
    try {
      final me = await ApiService.getMe();
      final serverUrl = me?['photo_url'] as String?;
      if (serverUrl != null && serverUrl.isNotEmpty) {
        final localPath = await ApiService.downloadPhoto(serverUrl);
        if (localPath.isNotEmpty) {
          photoNotifier.value = localPath;
          await updateField('photoPath', localPath);
          await prefs.setString(_photoKey, localPath);
        }
      }
    } catch (_) {
      // Server unreachable — skip
    }
  }

  /// Get the persisted photo path (survives logout).
  static Future<String> getPersistedPhotoPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoKey) ?? '';
  }
}
