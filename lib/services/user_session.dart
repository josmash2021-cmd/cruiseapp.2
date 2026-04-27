import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb, debugPrint;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'local_data_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'security_service.dart';
import 'cache_service.dart';
import 'firebase_storage_service.dart';
import 'prefs_cache.dart';

/// Stores and retrieves the logged-in user's session.
///
/// Uses the backend API for authentication and PostgreSQL for persistence.
/// Keeps a local cache in SharedPreferences for offline/quick access.
class UserSession {
  static const _key = 'user_session_v1';
  static const _modeKey = 'cruise_app_mode'; // 'rider' or 'driver'
  // Legacy global keys (cleared on logout for migration)
  static const _photoKey = 'cruise_profile_photo_path';
  static const _photoUrlKey = 'cruise_profile_photo_url';

  /// UID-specific photo keys — isolate photos per account.
  static String _photoKeyForUid(String uid) => 'cruise_photo_path_$uid';
  static String _photoUrlKeyForUid(String uid) => 'cruise_photo_url_$uid';

  /// Global notifier for profile photo path changes.
  /// Screens can listen to this to update in real time.
  static final ValueNotifier<String> photoNotifier = ValueNotifier<String>('');

  /// Global notifier for the remote photo URL (Firebase Storage).
  /// Persists across devices — used by UserProfilePhoto widget.
  static final ValueNotifier<String> photoUrlNotifier = ValueNotifier<String>('');

  /// The current user's ID — populated on login, cleared on logout.
  static String _cachedUid = '';

  /// Public access to the current user's UID for photo cache keying.
  static String get currentUid => _cachedUid;

  /// Deep link to process (fare-split, referral, promo code)
  static Uri? currentDeepLink;

  // ── Save / Read local cache ─────────────────────────

  /// Save user data locally (cache after API call).
  /// SECURITY: Passwords are NEVER stored. Sensitive fields are encrypted.
  static Future<void> saveUser({
    required String firstName,
    required String lastName,
    required String email,
    String? phone,
    String? photoPath,
    String? photoUrl,
    String? gender,
    String? paymentMethod,
    String? password, // Accepted but NEVER persisted
    int? userId,
    String? role,
  }) async {
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
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
        'photoUrl': photoUrl ?? '',
        'gender': gender ?? '',
        'paymentMethod': paymentMethod ?? '',
        // password is INTENTIONALLY omitted — never persisted (L7)
        'role': role ?? 'rider',
        'createdAt': DateTime.now().toIso8601String(),
        '_encrypted': 'true', // marker for decrypt logic
      }),
    );
    SecurityService.logSecurityEvent('user_saved', details: 'userId=$userId');
    // Keep cached UID in sync
    if (userId != null) _cachedUid = userId.toString();
    
    // Save photo URL to persistent cache (never disappears)
    if (photoUrl != null && photoUrl.isNotEmpty) {
      await CacheService.savePhotoUrl(photoUrl);
    }
  }

  /// Get the locally cached user, or null if not logged in.
  /// Automatically decrypts encrypted fields (L6).
  static Future<Map<String, String>?> getUser() async {
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
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
    final stopwatch = Stopwatch()..start();
    final token = await ApiService.getToken();
    debugPrint('[Perf] Token fetch: ${stopwatch.elapsedMilliseconds}ms');
    if (token == null) return false;

    // Token exists — session is active.
    // Try to refresh profile from backend, but always stay logged in
    // regardless of backend response. Only explicit sign-out ends session.
    try {
      final profile = await ApiService.getMe();
      debugPrint('[Perf] Profile fetch: ${stopwatch.elapsedMilliseconds}ms');
      if (profile != null) {
        final profileUid = profile['id']?.toString() ?? '';
        if (profileUid.isNotEmpty) _cachedUid = profileUid;
        // Use existing cached photo path immediately — don't block on download
        final existingUser = await getUser();
        final prefs0 = PrefsCache.instanceSync ?? await PrefsCache.instance;
        String cachedPhotoPath = existingUser?['photoPath'] ?? '';
        // Verify the file still exists on disk (iOS UUID change / OS cleanup)
        if (cachedPhotoPath.isNotEmpty && !kIsWeb) {
          if (!await File(cachedPhotoPath).exists()) {
            // Try UID-specific key as fallback
            final alt = profileUid.isNotEmpty
                ? (prefs0.getString(_photoKeyForUid(profileUid)) ?? '')
                : '';
            cachedPhotoPath = (alt.isNotEmpty && await File(alt).exists()) ? alt : '';
          }
        }
        // If no cached path from user session, try UID-specific key
        if (cachedPhotoPath.isEmpty && !kIsWeb && profileUid.isNotEmpty) {
          final persistedPath = prefs0.getString(_photoKeyForUid(profileUid)) ?? '';
          cachedPhotoPath = (persistedPath.isNotEmpty && await File(persistedPath).exists()) 
              ? persistedPath 
              : '';
        }
        // Repopulate local cache right away with cached photo
        final serverPhotoUrl = profile['photo_url']?.toString() ?? '';
        final uidUrl = profileUid.isNotEmpty
            ? (prefs0.getString(_photoUrlKeyForUid(profileUid)) ?? '')
            : '';
        final cachedUrl = uidUrl.isNotEmpty ? uidUrl : (existingUser?['photoUrl'] ?? '');
        final resolvedUrl = serverPhotoUrl.isNotEmpty ? serverPhotoUrl : cachedUrl;
        // Preserve existing cached name/photo if server returns empty
        final sFirstName = profile['first_name']?.toString() ?? '';
        final sLastName = profile['last_name']?.toString() ?? '';
        final firstName = sFirstName.isNotEmpty ? sFirstName : (existingUser?['firstName'] ?? '');
        final lastName = sLastName.isNotEmpty ? sLastName : (existingUser?['lastName'] ?? '');
        final resolvedPhotoPath = cachedPhotoPath.isNotEmpty ? cachedPhotoPath : (existingUser?['photoPath'] ?? '');
        await saveUser(
          firstName: firstName,
          lastName: lastName,
          email: profile['email']?.toString() ?? '',
          phone: profile['phone']?.toString() ?? '',
          photoPath: resolvedPhotoPath,
          photoUrl: resolvedUrl,
          gender: profile['gender']?.toString() ?? '',
          userId: int.tryParse(profileUid),
          role: profile['role']?.toString() ?? 'rider',
        );
        if (cachedPhotoPath.isNotEmpty) {
          photoNotifier.value = cachedPhotoPath;
        }
        // Broadcast remote URL immediately — CachedNetworkImage handles caching
        if (resolvedUrl.isNotEmpty) {
          photoUrlNotifier.value = resolvedUrl;
          if (profileUid.isNotEmpty) {
            await prefs0.setString(_photoUrlKeyForUid(profileUid), resolvedUrl);
          }
          // Sync photo URL to Firestore so it's available on all devices.
          // This ensures cross-device photo recovery works even after logout/login.
          final userId = int.tryParse(profileUid);
          if (userId != null && userId > 0) {
            final role = profile['role']?.toString() ?? 'rider';
            unawaited(FirebaseStorageService.updateFirestorePhotoUrl(userId, resolvedUrl, role));
          }
        }
        // Fire photo download in background — does not block navigation
        if (serverPhotoUrl.isNotEmpty) {
          unawaited(
            ApiService.downloadPhoto(serverPhotoUrl).then((path) async {
              if (path.isNotEmpty) {
                final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
                if (profileUid.isNotEmpty) {
                  await prefs.setString(_photoKeyForUid(profileUid), path);
                }
                await saveUser(
                  firstName: firstName,
                  lastName: lastName,
                  email: profile['email']?.toString() ?? '',
                  phone: profile['phone']?.toString() ?? '',
                  photoPath: path,
                  photoUrl: serverPhotoUrl,
                  gender: profile['gender']?.toString() ?? '',
                  userId: int.tryParse(profileUid),
                  role: profile['role']?.toString() ?? 'rider',
                );
                photoNotifier.value = path;
              }
            }).catchError((_) {}),
          );
        }
        return true;
      }
    } catch (_) {
      // ignore
    }
    // Backend unavailable or returned error — trust local cache
    final user = await getUser();
    return user != null && (user['firstName']?.isNotEmpty ?? false);
  }

  /// Fast local-only auth check — no network calls.
  /// Returns true if a JWT token AND a cached user session exist locally.
  /// Used by splash screen for instant navigation without waiting for backend.
  static Future<bool> isLoggedInLocal() async {
    final token = await ApiService.getToken();
    if (token == null) return false;
    final user = await getUser();
    return user != null && (user['firstName']?.isNotEmpty ?? false);
  }

  /// Update a single field locally.
  static Future<void> updateField(String key, String value) async {
    final user = await getUser();
    if (user == null) return;
    user[key] = value;

    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    await prefs.setString(_key, jsonEncode(user));
  }

  // ── Role persistence (rider / driver) ────────────

  /// Save the current app mode ('rider' or 'driver').
  /// Clears image cache on switch so the correct photo loads fresh.
  static Future<void> saveMode(String mode) async {
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    await prefs.setString(_modeKey, mode);
    await updateField('role', mode);
    // Clear image cache on role switch so stale photos don't persist
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
  }

  /// Set the active account on successful login.
  /// Clears image memory cache to prevent previous user's photo from showing.
  /// Called from auth flows (Google, Apple, Email) when login completes.
  static Future<void> setActiveAccount({
    required String uid,
    required String role,
  }) async {
    // Reset photo notifiers immediately so previous user's photo
    // never shows during the login transition
    photoNotifier.value = '';
    photoUrlNotifier.value = '';

    // Clear in-memory image cache from any previous account
    // Disk cache stays intact (keyed by URL, safe across accounts)
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}

    // Store active account markers for recovery chain validation
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    await prefs.setString('cruise_active_uid', uid);
    await prefs.setString('cruise_active_role', role);

    // Update cached UID for quick access
    _cachedUid = uid;

    debugPrint('[UserSession] Active account set: uid=$uid, role=$role');
  }

  /// Get the saved role. Reads from user session first, falls back to mode key.
  static Future<String> getMode() async {
    final user = await getUser();
    final role = user?['role'];
    if (role != null && role.isNotEmpty) return role;
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    return prefs.getString(_modeKey) ?? 'rider';
  }

  /// Log out — clear saved session, mode, JWT token, and ALL photo caches.
  /// Ensures complete isolation between accounts on the same device.
  /// Photos will be re-downloaded from server on next sign-in.
  static Future<void> logout() async {
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);

    // Grab UID before clearing session so we can clean up UID-specific data
    final uid = _cachedUid.isNotEmpty ? _cachedUid : ((await getUser())?['userId'] ?? '');

    await prefs.remove(_key);
    await prefs.remove(_modeKey);
    await prefs.remove('pending_password');

    // Clear local file path keys — the file is deleted below.
    // KEEP the photo URL keys so the photo loads instantly on next sign-in
    // (URLs are permanent Firebase Storage links, not sensitive data).
    if (uid.isNotEmpty) {
      await prefs.remove(_photoKeyForUid(uid));
    }
    await prefs.remove(_photoKey);

    // Delete the local photo file from the documents directory
    try {
      if (!kIsWeb && uid.isNotEmpty) {
        final dir = await getApplicationDocumentsDirectory();
        final candidates = await dir.list().toList();
        for (final entity in candidates) {
          if (entity is File && entity.path.contains('user_$uid.')) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}

    await ApiService.clearToken();
    ApiService.clearUserCache();
    await LocalDataService.clearAllUserData();

    // Clear in-memory image cache only (not disk cache — photos should
    // survive logout so they load instantly on next sign-in).
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}

    photoNotifier.value = '';
    photoUrlNotifier.value = '';
    _cachedUid = '';
  }

  /// Temporarily save a password during registration flow (encrypted at rest).
  static Future<void> savePendingPassword(String password) async {
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    final encrypted = SecurityService.encryptForPrefs(password, 'pending_pw');
    await prefs.setString('pending_password', encrypted);
  }

  /// Get the temporarily saved password (decrypted).
  static Future<String?> getPendingPassword() async {
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    final raw = prefs.getString('pending_password');
    if (raw == null || raw.isEmpty) return null;
    return SecurityService.decryptFromPrefs(raw, 'pending_pw') ?? raw;
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
    final userId = user?['userId'] ?? 'unknown'; // key is 'userId' not 'id'
    final permanent = File('${dir.path}/user_$userId.$ext');
    // Delete old photo if exists
    if (await permanent.exists()) {
      await permanent.delete();
    }
    await File(tempPath).copy(permanent.path);
    // Update session + persistent photo key (UID-specific)
    await updateField('photoPath', permanent.path);
    final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
    await prefs.setString(_photoKeyForUid(userId), permanent.path);
    // Notify all listeners immediately
    photoNotifier.value = permanent.path;
    return permanent.path;
  }

  /// Tries to recover a stale absolute path after an iOS app update.
  /// iOS can change the sandbox container UUID on update, making stored
  /// absolute paths invalid even though the file exists under the same
  /// filename in the new documents directory.
  static Future<String> _healStalePath(String stalePath) async {
    if (stalePath.isEmpty || kIsWeb) return '';
    final filename = stalePath.split('/').last;
    if (filename.isEmpty) return '';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final healed = File('${dir.path}/$filename');
      return await healed.exists() ? healed.path : '';
    } catch (_) {
      return '';
    }
  }

  /// Initialize the photo notifier from stored session (call once at startup).
  /// Phase 1 (sync-ish): loads from local cache — instant, never blocks UI.
  /// Phase 2 (async): fetches from network in background if local cache is empty.
  static Future<void> initPhotoNotifier() async {
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;

    final user = await getUser();
    final uid = user?['userId'] ?? '';
    if (uid.isNotEmpty) _cachedUid = uid;

    // ── Phase 1: Local cache (instant) ──
    // Resolve remote URL from local cache
    final uidUrl = uid.isNotEmpty ? (prefs.getString(_photoUrlKeyForUid(uid)) ?? '') : '';
    final cachedUrl = uidUrl.isNotEmpty ? uidUrl : (user?['photoUrl'] ?? '');
    if (cachedUrl.isNotEmpty) {
      photoUrlNotifier.value = cachedUrl;
    }

    // Resolve local file path from cache
    bool foundLocal = false;
    Future<bool> tryPath(String p) async {
      if (p.isEmpty || kIsWeb) return false;
      if (await File(p).exists()) {
        photoNotifier.value = p;
        if (uid.isNotEmpty) await prefs.setString(_photoKeyForUid(uid), p);
        return true;
      }
      final healed = await _healStalePath(p);
      if (healed.isNotEmpty) {
        photoNotifier.value = healed;
        if (uid.isNotEmpty) await prefs.setString(_photoKeyForUid(uid), healed);
        return true;
      }
      return false;
    }

    if (uid.isNotEmpty && await tryPath(prefs.getString(_photoKeyForUid(uid)) ?? '')) {
      foundLocal = true;
    } else if (await tryPath(user?['photoPath'] ?? '')) {
      foundLocal = true;
    }

    // Always fire network fetch — never blocks UI.
    // URL alone is enough for CachedNetworkImage to render the photo instantly.
    // Always fetch from network to recover photos lost during app updates.
    unawaited(_fetchPhotoFromNetwork(uid, prefs, cachedUrl.isEmpty));
  }

  /// Fetch photo URL from network — fast, parallel, never blocks UI.
  /// Once we have a URL, CachedNetworkImage handles rendering + disk cache.
  static Future<void> _fetchPhotoFromNetwork(
    String uid,
    SharedPreferences prefs,
    bool needsUrl,
  ) async {
    final userId = int.tryParse(uid);
    if (userId == null || userId <= 0) return;

    try {
      // Race Firestore and backend API in parallel — use whichever responds first
      String? resolvedUrl;
      final results = await Future.wait<String?>([
        FirebaseStorageService.fetchPhotoUrl(userId).catchError((_) => null),
        ApiService.getMe().then((me) => me?['photo_url']?.toString()).catchError((_) => null),
      ]).timeout(const Duration(seconds: 4), onTimeout: () => [null, null]);

      // Prefer Firestore URL (Firebase Storage permanent link)
      final firestoreUrl = results[0];
      final backendUrl = results[1];
      if (firestoreUrl != null && firestoreUrl.isNotEmpty) {
        resolvedUrl = firestoreUrl;
      } else if (backendUrl != null && backendUrl.isNotEmpty) {
        resolvedUrl = backendUrl;
      }

      if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
        photoUrlNotifier.value = resolvedUrl;
        if (uid.isNotEmpty) await prefs.setString(_photoUrlKeyForUid(uid), resolvedUrl);
        unawaited(updateField('photoUrl', resolvedUrl));
        // Download local copy in background — non-blocking
        unawaited(ApiService.downloadPhoto(resolvedUrl).then((path) async {
          if (path.isNotEmpty) {
            photoNotifier.value = path;
            if (uid.isNotEmpty) await prefs.setString(_photoKeyForUid(uid), path);
            unawaited(updateField('photoPath', path));
          }
        }).catchError((_) {}));
      }
    } catch (_) {
      // Network unreachable — skip silently
    }
  }

  /// Get the persisted photo path for the current user.
  static Future<String> getPersistedPhotoPath() async {
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final uid = _cachedUid.isNotEmpty ? _cachedUid : ((await getUser())?['userId'] ?? '');
    if (uid.isNotEmpty) return prefs.getString(_photoKeyForUid(uid)) ?? '';
    return '';
  }

  /// Get the persisted remote photo URL for the current user.
  static Future<String> getPersistedPhotoUrl() async {
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final uid = _cachedUid.isNotEmpty ? _cachedUid : ((await getUser())?['userId'] ?? '');
    if (uid.isNotEmpty) return prefs.getString(_photoUrlKeyForUid(uid)) ?? '';
    return '';
  }

  /// Save a remote photo URL after upload. Call this after uploading
  /// to Firebase Storage so other devices can load it immediately.
  static Future<void> savePhotoUrl(String url) async {
    if (url.isEmpty) return;
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final uid = _cachedUid.isNotEmpty ? _cachedUid : ((await getUser())?['userId'] ?? '');
    if (uid.isNotEmpty) await prefs.setString(_photoUrlKeyForUid(uid), url);
    await updateField('photoUrl', url);
    photoUrlNotifier.value = url;
  }
}
