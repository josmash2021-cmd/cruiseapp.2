import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'security_service.dart';
import '../config/env.dart';

/// Communicates with the Cruise Ride backend (FastAPI + PostgreSQL).
///
/// The active server URL is loaded from SharedPreferences on startup so it
/// can be updated at runtime (e.g. after starting a new Cloudflare tunnel)
/// without rebuilding the app.  Use [setServerUrl] to persist a new URL and
/// [probeAndSetBestUrl] to auto-detect which endpoint is reachable.
class ApiService {
  // ── Known endpoints ────────────────────────────────────────────────────────

  /// Android emulator loopback — maps to host machine localhost.
  static const String _localUrl = 'http://10.0.2.2:8000';

  /// Physical device via ADB reverse — maps to host machine localhost.
  static const String _adbUrl = 'http://localhost:8000';

  /// Local network URL — works for physical devices on same WiFi network
  static const String _localNetworkUrl = 'http://172.20.11.24:8000';

  /// Default Cloudflare Tunnel URL.  Free tunnels change every restart;
  /// update via the in-app Settings → "Server URL" dialog instead of rebuilding.
  static const String _defaultTunnelUrl =
      'https://jaida-intervarsity-tashina.ngrok-free.dev';

  static const String _serverUrlPrefKey = 'cruise_server_url';

  /// In-memory active URL.  Populated by [init]; defaults to tunnel so the
  /// first call before [init] completes still reaches *something*.
  static String _activeUrl = _defaultTunnelUrl;

  /// Returns the URL currently in use by all API calls.
  static String get activeServerUrl => _activeUrl;

  /// Load persisted server URL from SharedPreferences.
  /// Call once in main() before runApp().
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_serverUrlPrefKey);
    if (saved != null && saved.isNotEmpty) {
      _activeUrl = saved;
    }
    debugPrint('[ApiService] active URL: $_activeUrl');
    // Probe to find a working URL before the app starts making requests
    try {
      final url = await probeAndSetBestUrl(timeout: const Duration(seconds: 3));
      if (url != null) {
        debugPrint('[ApiService] probe found reachable URL: $url');
      } else {
        debugPrint('[ApiService] probe: no reachable URL found');
      }
    } catch (_) {}
  }

  /// Persist a new server URL and update all subsequent requests immediately.
  static Future<void> setServerUrl(String url) async {
    _activeUrl = url.trimRight().replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlPrefKey, _activeUrl);
    debugPrint('[ApiService] server URL updated → $_activeUrl');
  }

  /// Try each candidate URL with a lightweight health-check (`GET /health`).
  /// Keeps the first one that responds 200 within [timeout] and persists it.
  /// If the hard-coded tunnel fails, queries the local-network endpoint for
  /// the latest tunnel URL written by cruise_service.ps1.
  static Future<String?> probeAndSetBestUrl({
    List<String>? candidates,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final urls =
        candidates ??
        [_activeUrl, _localNetworkUrl, _defaultTunnelUrl, _adbUrl, _localUrl];

    for (final url in urls) {
      try {
        final response = await http
            .get(
              Uri.parse('$url/health'),
              headers: {'Accept': 'application/json', 'ngrok-skip-browser-warning': 'true'},
            )
            .timeout(timeout);
        if (response.statusCode == 200) {
          await setServerUrl(url);
          return url;
        }
      } catch (_) {
        // This endpoint not reachable — try next
      }
    }

    // None of the known URLs worked — try discovering the latest tunnel URL
    // via the local-network backend (only reachable on the same WiFi).
    for (final base in [_localNetworkUrl, _localUrl]) {
      try {
        final disc = await http
            .get(
              Uri.parse('$base/tunnel-url'),
              headers: {'Accept': 'application/json', 'ngrok-skip-browser-warning': 'true'},
            )
            .timeout(timeout);
        if (disc.statusCode == 200) {
          final body = jsonDecode(disc.body);
          final tunnelUrl = body['tunnel_url'] as String?;
          if (tunnelUrl != null && tunnelUrl.isNotEmpty) {
            // Verify the discovered tunnel URL actually works
            final check = await http
                .get(
                  Uri.parse('$tunnelUrl/health'),
                  headers: {'Accept': 'application/json', 'ngrok-skip-browser-warning': 'true'},
                )
                .timeout(timeout);
            if (check.statusCode == 200) {
              await setServerUrl(tunnelUrl);
              debugPrint('[ApiService] Discovered new tunnel URL: $tunnelUrl');
              return tunnelUrl;
            }
          }
        }
      } catch (_) {
        // Discovery endpoint not reachable — try next
      }
    }

    return null; // No reachable endpoint found
  }

  // ── Internal helper ────────────────────────────────────────────────────────

  static String get _baseUrl => _activeUrl;
  static String get publicBaseUrl => _activeUrl;

  /// API Key — must match the server's API_KEY in .env
  static const String _apiKey = Env.apiKey;

  /// HMAC Signing Secret — signs every request to prevent spoofing.
  static const String _hmacSecret = Env.hmacSecret;

  // ── Token persistence (encrypted via Keystore/Keychain) ──

  static const String _tokenKey = 'cruise_jwt_token';
  static const String _refreshTokenKey = 'cruise_refresh_token';
  static String? _cachedToken;
  static String? _cachedRefreshToken;
  static bool _isRefreshing = false;

  static Future<void> _saveToken(String token) async {
    _cachedToken = token;
    await SecurityService.storeCredential('jwt', token);
    final fp = SecurityService.createTokenFingerprint(token);
    await SecurityService.storeCredential('token_fp', fp);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    SecurityService.logSecurityEvent('token_stored');
  }

  static Future<void> _saveRefreshToken(String token) async {
    _cachedRefreshToken = token;
    await SecurityService.storeCredential('refresh_jwt', token);
  }

  static Future<String?> getToken() async {
    if (_cachedToken != null) return _cachedToken;
    final secureToken = await SecurityService.readCredential('jwt');
    if (secureToken != null && secureToken.isNotEmpty) {
      _cachedToken = secureToken;
      return _cachedToken;
    }
    final prefs = await SharedPreferences.getInstance();
    _cachedToken = prefs.getString(_tokenKey);
    if (_cachedToken != null) {
      await SecurityService.storeCredential('jwt', _cachedToken!);
    }
    return _cachedToken;
  }

  static Future<String?> _getRefreshToken() async {
    if (_cachedRefreshToken != null) return _cachedRefreshToken;
    _cachedRefreshToken = await SecurityService.readCredential('refresh_jwt');
    return _cachedRefreshToken;
  }

  /// Attempt to refresh the access token using the refresh token.
  /// Returns true if successful, false otherwise.
  static Future<bool> refreshAccessToken() async {
    if (_isRefreshing) return false;
    _isRefreshing = true;
    try {
      final refreshToken = await _getRefreshToken();
      if (refreshToken == null) return false;
      final res = await http
          .post(
            Uri.parse('$_baseUrl/auth/refresh'),
            headers: _jsonHeaders(refreshToken),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        await _saveToken(data['access_token'] as String);
        if (data['refresh_token'] != null) {
          await _saveRefreshToken(data['refresh_token'] as String);
        }
        SecurityService.logSecurityEvent('token_refreshed');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  static Future<void> clearToken() async {
    _cachedToken = null;
    _cachedRefreshToken = null;
    await SecurityService.deleteCredential('jwt');
    await SecurityService.deleteCredential('token_fp');
    await SecurityService.deleteCredential('refresh_jwt');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    SecurityService.logSecurityEvent('token_cleared');
  }

  // ── Helpers ──────────────────────────────────────────

  /// Generate a cryptographically secure 32-char hex nonce (L2: anti-replay).
  static String _generateNonce() => SecurityService.generateNonce();

  /// Compute HMAC-SHA256 signature: HMAC(secret, "{apiKey}:{timestamp}:{nonce}:{fingerprint}")
  /// Uses the truncated fingerprint (first 16 chars) to match X-Device-FP header.
  static String _computeSignature(String timestamp, String nonce) {
    final key = utf8.encode(_hmacSecret);
    final fp = SecurityService.deviceFingerprint;
    final truncatedFp = fp.length >= 16 ? fp.substring(0, 16) : fp;
    final data = utf8.encode('$_apiKey:$timestamp:$nonce:$truncatedFp');
    final hmacSha256 = Hmac(sha256, key);
    return hmacSha256.convert(data).toString();
  }

  static Map<String, String> _jsonHeaders([String? token]) {
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .toString();
    final nonce = _generateNonce();
    final signature = _computeSignature(timestamp, nonce);
    return {
      'Content-Type': 'application/json',
      'X-API-Key': _apiKey,
      'X-Timestamp': timestamp,
      'X-Nonce': nonce,
      'X-Signature': signature,
      'X-Device-FP': SecurityService.deviceFingerprint.length >= 16
          ? SecurityService.deviceFingerprint.substring(0, 16)
          : SecurityService.deviceFingerprint,
      'X-Client-Version': '1.0.0',
      'ngrok-skip-browser-warning': 'true',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Headers with the current JWT attached (for authenticated endpoints).
  static Future<Map<String, String>> _authHeaders() async {
    final token = await getToken();
    return _jsonHeaders(token);
  }

  /// Parse response — returns decoded JSON map.
  /// Throws [ApiException] on non-2xx.
  /// Verifies response integrity via X-Checksum header (L8).
  static Map<String, dynamic> _parse(http.Response res) {
    // L8: Verify response integrity if checksum header present
    final checksum = res.headers['x-response-checksum'];
    if (checksum != null &&
        !SecurityService.verifyResponseIntegrity(res.body, checksum)) {
      SecurityService.logSecurityEvent(
        'integrity_violation',
        details: 'Response tampered: ${res.request?.url.path}',
      );
      throw const ApiException(0, 'Response integrity check failed');
    }

    // Guard against non-JSON responses (e.g. Cloudflare HTML error pages)
    dynamic body;
    try {
      body = jsonDecode(res.body);
    } on FormatException {
      debugPrint(
        '[ApiService] Non-JSON response (${res.statusCode}): ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}',
      );
      throw ApiException(
        res.statusCode,
        'Server unreachable (error ${res.statusCode})',
      );
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body is Map<String, dynamic> ? body : {'data': body};
    }
    final detail = body is Map ? body['detail'] ?? 'Unknown error' : body;
    throw ApiException(res.statusCode, detail.toString());
  }

  // ═══════════════════════════════════════════════════════
  //  AUTH  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Register a new account.
  /// Returns `{ access_token, token_type, user: { id, first_name, … } }`.
  static Future<Map<String, dynamic>> register({
    required String firstName,
    required String lastName,
    String? email,
    String? phone,
    required String password,
    String? photoUrl,
    String role = 'rider',
  }) async {
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/register'),
          headers: _jsonHeaders(),
          body: jsonEncode({
            'first_name': firstName,
            'last_name': lastName,
            if (email != null && email.isNotEmpty) 'email': email,
            if (phone != null && phone.isNotEmpty) 'phone': phone,
            'password': password,
            // ignore: use_null_aware_elements
            if (photoUrl != null) 'photo_url': photoUrl,
            'role': role,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final data = _parse(res);

    // Persist session token
    final token = data['access_token'] as String;
    await _saveToken(token);

    debugPrint('✅ Registered user ${data['user']?['id']}');
    return data;
  }

  /// Check whether an email or phone is already registered.
  /// Returns `true` if the account exists.
  static Future<bool> checkExists(String identifier, {String? role}) async {
    try {
      final payload = <String, dynamic>{'identifier': identifier.trim()};
      if (role != null) payload['role'] = role;
      final res = await http.post(
        Uri.parse('$_baseUrl/auth/check-exists'),
        headers: _jsonHeaders(),
        body: jsonEncode(payload),
      );
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        return body['exists'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️  checkExists failed: $e');
      return false; // Fail open — let the user continue
    }
  }

  /// Validate email-or-phone + password.
  /// Returns `{ login_token, method, email, phone }`.
  static Future<Map<String, dynamic>> login({
    required String identifier,
    required String password,
    String? role,
  }) async {
    final body = <String, dynamic>{
      'identifier': identifier,
      'password': password,
    };
    if (role != null) body['role'] = role;
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/login'),
          headers: _jsonHeaders(),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Exchange the temporary login_token for a full JWT.
  /// Call this after the verification code has been confirmed.
  /// Returns `{ access_token, token_type, user: { … } }`.
  static Future<Map<String, dynamic>> completeLogin({
    required String loginToken,
  }) async {
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/complete-login'),
          headers: _jsonHeaders(),
          body: jsonEncode({'login_token': loginToken}),
        )
        .timeout(const Duration(seconds: 10));

    final data = _parse(res);
    final token = data['access_token'] as String;
    await _saveToken(token);
    if (data['refresh_token'] != null) {
      await _saveRefreshToken(data['refresh_token'] as String);
    }
    // Clear stale user cache so getCurrentUserId fetches fresh data
    _cachedUser = data['user'] as Map<String, dynamic>?;
    debugPrint('✅ Login complete — user ${data['user']?['id']}');
    return data;
  }

  /// Get the current user's profile (requires valid JWT).
  /// Returns user map or `null` if the token is invalid/expired.
  static Future<Map<String, dynamic>?> getMe() async {
    final token = await getToken();
    if (token == null) return null;

    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/auth/me'), headers: _jsonHeaders(token))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return jsonDecode(res.body);
      // Auto-refresh on 401
      if (res.statusCode == 401) {
        final refreshed = await refreshAccessToken();
        if (refreshed) {
          final newToken = await getToken();
          final retry = await http
              .get(
                Uri.parse('$_baseUrl/auth/me'),
                headers: _jsonHeaders(newToken),
              )
              .timeout(const Duration(seconds: 5));
          if (retry.statusCode == 200) return jsonDecode(retry.body);
        }
      }
      return null;
    } catch (e) {
      debugPrint('\u26a0\ufe0f  getMe failed (offline?): $e');
      return null;
    }
  }

  /// Update profile fields (e.g. photo_url, first_name, …).
  static Future<Map<String, dynamic>> updateMe(
    Map<String, dynamic> updates,
  ) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    final res = await http
        .patch(
          Uri.parse('$_baseUrl/auth/me'),
          headers: _jsonHeaders(token),
          body: jsonEncode(updates),
        )
        .timeout(const Duration(seconds: 10));
    final data = _parse(res);
    // Update cached user so subsequent reads see the fresh data
    _cachedUser = data;
    return data;
  }

  /// Delete the current user's account.
  static Future<void> deleteAccount() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .delete(Uri.parse('$_baseUrl/auth/me'), headers: _jsonHeaders(token))
        .timeout(const Duration(seconds: 10));
    _parse(res);
    _cachedUser = null;
  }

  /// Mark user as offline (called when app goes to background).
  static Future<void> goOffline() async {
    final token = await getToken();
    if (token == null) return;
    try {
      await http
          .post(
            Uri.parse('$_baseUrl/auth/offline'),
            headers: _jsonHeaders(token),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best-effort, don't block app lifecycle
    }
  }

  // ═══════════════════════════════════════════════════════
  //  SUPPORT CHAT
  // ═══════════════════════════════════════════════════════

  /// Create or get existing open support chat.
  static Future<Map<String, dynamic>> createSupportChat({
    String subject = '',
    String locale = 'en',
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .post(
          Uri.parse('$_baseUrl/support/chats'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'subject': subject, 'locale': locale}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// List all support chats for the current user.
  static Future<List<Map<String, dynamic>>> getSupportChats() async {
    final token = await getToken();
    if (token == null) return [];
    final res = await http
        .get(Uri.parse('$_baseUrl/support/chats'), headers: _jsonHeaders(token))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(res.body);
      if (data is List) return List<Map<String, dynamic>>.from(data);
    }
    return [];
  }

  /// Get support chat messages.
  static Future<List<dynamic>> getSupportMessages(int chatId) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .get(
          Uri.parse('$_baseUrl/support/chats/$chatId/messages'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 10));
    final data = _parse(res);
    final list = data['data'];
    return list is List ? List<dynamic>.from(list) : [];
  }

  /// Send a support chat message.
  static Future<Map<String, dynamic>> sendSupportMessage(
    int chatId,
    String message,
  ) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .post(
          Uri.parse('$_baseUrl/support/chats/$chatId/messages'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Close a support chat (user-facing).
  static Future<void> closeSupportChat(int chatId) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    await http
        .patch(
          Uri.parse('$_baseUrl/support/chats/$chatId/close-user'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 10));
  }

  /// Get the support voice call phone number.
  static Future<String?> getSupportPhoneNumber() async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/voice/phone-number'))
          .timeout(const Duration(seconds: 10));
      final data = _parse(res);
      final phone = data['phone_number'] as String?;
      return (phone != null && phone.isNotEmpty) ? phone : null;
    } catch (_) {
      return null;
    }
  }

  /// Submit identity verification for dispatch review.
  static Future<Map<String, dynamic>> submitVerification(
    Map<String, dynamic> data,
  ) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/verify-request'),
          headers: _jsonHeaders(token),
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 60));
    return _parse(res);
  }

  /// Check verification status (dispatch may have approved/rejected).
  static Future<Map<String, dynamic>> getVerificationStatus() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .get(
          Uri.parse('$_baseUrl/auth/verification-status'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Driver approval status from dispatch (pending/approved/rejected).
  static Future<Map<String, dynamic>> getDriverApprovalStatus() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .get(
          Uri.parse('$_baseUrl/auth/driver-approval-status'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 5));
    return _parse(res);
  }

  /// Check account status (dispatch may have blocked/deleted).
  static Future<String> getAccountStatus() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await http
        .get(
          Uri.parse('$_baseUrl/auth/account-status'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 5));
    final data = _parse(res);
    return data['status'] as String? ?? 'active';
  }

  // ═══════════════════════════════════════════════════════
  //  PHOTO  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Upload a profile photo (base64) to the server.
  /// Returns the server-side photo URL path (e.g. "/photos/user_1.jpg").
  static Future<String> uploadPhoto(String filePath) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final bytes = await File(filePath).readAsBytes();
    final b64 = base64Encode(bytes);
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/photo'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'photo': b64}),
        )
        .timeout(const Duration(seconds: 30));
    final data = _parse(res);
    return data['photo_url'] as String? ?? '';
  }

  /// Download a profile photo from the server and save to local file.
  /// [photoUrl] is the relative path like "/photos/user_1.jpg".
  /// Returns the local file path, or empty string on failure.
  static Future<String> downloadPhoto(String photoUrl) async {
    try {
      final url = '$_baseUrl$photoUrl';
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return '';
      final dir = await getApplicationDocumentsDirectory();
      final ext = photoUrl.endsWith('.png') ? 'png' : 'jpg';
      // Use the server filename (user_ID.ext) to isolate photos per user
      final serverFilename = photoUrl.split('/').last;
      final filename = serverFilename.isNotEmpty
          ? serverFilename
          : 'profile_photo.$ext';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(res.bodyBytes);
      return file.path;
    } catch (e) {
      debugPrint('[ApiService] downloadPhoto failed: $e');
      return '';
    }
  }

  // ═══════════════════════════════════════════════════════
  //  TRIP  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Rider creates a new trip request.
  /// Returns the created trip (status: requested or scheduled).
  static Future<Map<String, dynamic>> createTrip({
    required int riderId,
    required String pickupAddress,
    required String dropoffAddress,
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    double? fare,
    String? vehicleType,
    DateTime? scheduledAt,
    bool isAirport = false,
    String? airportCode,
    String? terminal,
    String? pickupZone,
    String? notes,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/trips'),
          headers: h,
          body: jsonEncode({
            'rider_id': riderId,
            'pickup_address': pickupAddress,
            'dropoff_address': dropoffAddress,
            'pickup_lat': pickupLat,
            'pickup_lng': pickupLng,
            'dropoff_lat': dropoffLat,
            'dropoff_lng': dropoffLng,
            if (fare != null) 'fare': fare,
            if (vehicleType != null) 'vehicle_type': vehicleType,
            if (scheduledAt != null)
              'scheduled_at': scheduledAt.toUtc().toIso8601String(),
            'is_airport': isAirport,
            if (airportCode != null) 'airport_code': airportCode,
            if (terminal != null) 'terminal': terminal,
            if (pickupZone != null) 'pickup_zone': pickupZone,
            if (notes != null) 'notes': notes,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Get scheduled trips for a rider.
  static Future<List<Map<String, dynamic>>> getScheduledTrips(
    int riderId,
  ) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/trips/scheduled/rider/$riderId'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'Failed to load scheduled trips');
  }

  /// Get scheduled trips assigned to a driver.
  static Future<List<Map<String, dynamic>>> getDriverScheduledTrips(
    int driverId,
  ) async {
    final h = await _authHeaders();
    final res = await http
        .get(
          Uri.parse('$_baseUrl/trips/scheduled/driver/$driverId'),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'Failed to load scheduled trips');
  }

  /// Cancel a trip (scheduled or active).
  static Future<Map<String, dynamic>> cancelTrip(int tripId) async {
    final h = await _authHeaders();
    final res = await http
        .post(Uri.parse('$_baseUrl/trips/$tripId/cancel'), headers: h)
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Get a trip by ID (for polling status).
  static Future<Map<String, dynamic>> getTrip(int tripId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/trips/$tripId'), headers: h)
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Driver polls for available ride requests near their location.
  static Future<List<Map<String, dynamic>>> getAvailableTrips({
    required double lat,
    required double lng,
    double radiusKm = 15.0,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .get(
          Uri.parse(
            '$_baseUrl/trips/available?lat=$lat&lng=$lng&radius_km=$radiusKm',
          ),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Driver accepts a trip request.
  static Future<Map<String, dynamic>> acceptTrip({
    required int tripId,
    required int driverId,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/accept'),
          headers: h,
          body: jsonEncode({'driver_id': driverId}),
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Update trip status (driver_en_route, arrived, in_trip, completed, canceled).
  static Future<Map<String, dynamic>> updateTripStatus({
    required int tripId,
    required String status,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .patch(
          Uri.parse('$_baseUrl/trips/$tripId/status?status=$status'),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Update driver's location and online status.
  static Future<Map<String, dynamic>> updateDriverLocation({
    required int driverId,
    required double lat,
    required double lng,
    bool isOnline = true,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .patch(
          Uri.parse('$_baseUrl/drivers/$driverId/location'),
          headers: h,
          body: jsonEncode({'lat': lat, 'lng': lng, 'is_online': isOnline}),
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Get rider's trip history.
  static Future<List<Map<String, dynamic>>> getRiderTrips(int riderId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/riders/$riderId/trips'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Get driver's trip history.
  static Future<List<Map<String, dynamic>>> getDriverTrips(int driverId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/drivers/$driverId/trips'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Get driver stats (acceptance rate, on-time rate, etc.) from backend.
  static Future<Map<String, dynamic>> getDriverStats(int driverId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/drivers/$driverId/stats'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    return {};
  }

  // ═══════════════════════════════════════════════════════
  //  USER ID HELPERS
  // ═══════════════════════════════════════════════════════

  /// Cache for current user data.
  static Map<String, dynamic>? _cachedUser;

  /// Get the current logged-in user's ID (from cache or API).
  static Future<int?> getCurrentUserId() async {
    if (_cachedUser != null) return _cachedUser!['id'] as int?;
    final me = await getMe();
    if (me != null) {
      _cachedUser = me;
      return me['id'] as int?;
    }
    return null;
  }

  /// Get the current user profile (cached).
  static Future<Map<String, dynamic>?> getCurrentUser() async {
    if (_cachedUser != null) return _cachedUser;
    final me = await getMe();
    if (me != null) _cachedUser = me;
    return me;
  }

  /// Clear the user cache (on logout).
  static void clearUserCache() {
    _cachedUser = null;
  }

  // ═══════════════════════════════════════════════════════
  //  DRIVER EARNINGS  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Get driver earnings summary for a period (today, week, month).
  static Future<Map<String, dynamic>> getDriverEarnings({
    String period = 'week',
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    final res = await http
        .get(
          Uri.parse('$_baseUrl/drivers/earnings?period=$period'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    // Return empty data on error instead of crashing
    return {
      'total': 0.0,
      'trips_count': 0,
      'online_hours': 0.0,
      'tips_total': 0.0,
      'daily_earnings': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      'day_labels': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
      'transactions': [],
    };
  }

  /// Request a cashout of driver earnings.
  static Future<Map<String, dynamic>> requestCashout({
    required double amount,
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    final res = await http
        .post(
          Uri.parse('$_baseUrl/drivers/cashout'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'amount': amount}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Get list of driver's cashout history.
  static Future<List<Map<String, dynamic>>> getDriverCashouts() async {
    final token = await getToken();
    if (token == null) return [];

    final res = await http
        .get(
          Uri.parse('$_baseUrl/drivers/cashouts'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 8));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Get driver's payout methods.
  static Future<List<Map<String, dynamic>>> getPayoutMethods() async {
    final token = await getToken();
    if (token == null) return [];

    final res = await http
        .get(
          Uri.parse('$_baseUrl/drivers/payout-methods'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 8));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Add a payout method for the driver.
  static Future<Map<String, dynamic>> addPayoutMethod({
    required String methodType,
    required String displayName,
    bool setDefault = false,
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    final res = await http
        .post(
          Uri.parse('$_baseUrl/drivers/payout-methods'),
          headers: _jsonHeaders(token),
          body: jsonEncode({
            'method_type': methodType,
            'display_name': displayName,
            'set_default': setDefault,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Delete a payout method.
  static Future<void> deletePayoutMethod(int payoutId) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    await http
        .delete(
          Uri.parse('$_baseUrl/drivers/payout-methods/$payoutId'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 8));
  }

  // ═══════════════════════════════════════════════════════
  //  PLAID BANK LINKING
  // ═══════════════════════════════════════════════════════

  /// Create a Plaid Link token (backend calls Plaid API).
  static Future<String> createPlaidLinkToken() async {
    final h = await _authHeaders();
    final res = await http
        .post(Uri.parse('$_baseUrl/plaid/create-link-token'), headers: h)
        .timeout(const Duration(seconds: 15));
    final data = _parse(res);
    return data['link_token'] as String;
  }

  /// Exchange Plaid public token for access token and save linked account.
  static Future<Map<String, dynamic>> exchangePlaidPublicToken({
    required String publicToken,
    String? accountId,
    String? institutionName,
    String? accountMask,
    String? accountSubtype,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/plaid/exchange-token'),
          headers: h,
          body: jsonEncode({
            'public_token': publicToken,
            'account_id': accountId,
            'institution_name': institutionName ?? 'Bank',
            'account_mask': accountMask ?? '',
            'account_subtype': accountSubtype ?? 'checking',
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  RIDE DISPATCH — Uber-style cascading driver assignment
  // ═══════════════════════════════════════════════════════

  /// Rider creates a ride and the system auto-dispatches to closest driver.
  static Future<Map<String, dynamic>> dispatchRideRequest({
    required int riderId,
    required String pickupAddress,
    required String dropoffAddress,
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    double? fare,
    String? vehicleType,
    DateTime? scheduledAt,
    bool isAirport = false,
    String? airportCode,
    String? terminal,
    String? pickupZone,
    String? notes,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/dispatch/request'),
          headers: h,
          body: jsonEncode({
            'rider_id': riderId,
            'pickup_address': pickupAddress,
            'dropoff_address': dropoffAddress,
            'pickup_lat': pickupLat,
            'pickup_lng': pickupLng,
            'dropoff_lat': dropoffLat,
            'dropoff_lng': dropoffLng,
            if (fare != null) 'fare': fare,
            if (vehicleType != null) 'vehicle_type': vehicleType,
            if (scheduledAt != null)
              'scheduled_at': scheduledAt.toUtc().toIso8601String(),
            'is_airport': isAirport,
            if (airportCode != null) 'airport_code': airportCode,
            if (terminal != null) 'terminal': terminal,
            if (pickupZone != null) 'pickup_zone': pickupZone,
            if (notes != null) 'notes': notes,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Driver polls for their pending ride offers (returns a LIST now).
  static Future<List<Map<String, dynamic>>> getDriverPendingOffers(
    int driverId,
  ) async {
    final h = await _authHeaders();
    final res = await http
        .get(
          Uri.parse('$_baseUrl/dispatch/driver/pending?driver_id=$driverId'),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final body = jsonDecode(res.body);
      if (body is List) {
        return body.cast<Map<String, dynamic>>();
      }
      // Legacy: if backend returns a single map, wrap it
      if (body is Map<String, dynamic> && body.isNotEmpty) {
        return [body];
      }
    }
    return [];
  }

  /// Driver accepts a ride offer.
  static Future<Map<String, dynamic>> acceptRideOffer({
    required int offerId,
    required int driverId,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse(
            '$_baseUrl/dispatch/driver/accept?offer_id=$offerId&driver_id=$driverId',
          ),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Driver rejects a ride offer (cascades to next driver).
  static Future<Map<String, dynamic>> rejectRideOffer({
    required int offerId,
    required int driverId,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse(
            '$_baseUrl/dispatch/driver/reject?offer_id=$offerId&driver_id=$driverId',
          ),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Rider polls dispatch status to see if a driver accepted.
  static Future<Map<String, dynamic>> getDispatchStatus(int tripId) async {
    final h = await _authHeaders();
    final res = await http
        .get(
          Uri.parse('$_baseUrl/dispatch/trip/status?trip_id=$tripId'),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    return {'status': 'error'};
  }

  /// Get a route from Google Directions API (or OSRM fallback).
  /// Returns a list of LatLng points for the route polyline, or null on failure.
  static Future<Map<String, dynamic>?> getDirectionsRoute({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    // Try Google Directions API
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
            'origin': '$originLat,$originLng',
            'destination': '$destLat,$destLng',
            'key': Env.googleMapsKey,
            'mode': 'driving',
          });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          return data as Map<String, dynamic>;
        }
      }
    } catch (_) {}

    // Fallback: OSRM
    try {
      final path = '/route/v1/driving/$originLng,$originLat;$destLng,$destLat';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        return {'source': 'osrm', ...data};
      }
    } catch (_) {}

    return null;
  }

  /// Check if any drivers are online near a given location.
  /// Returns the count of online drivers. Falls back to 0 on error.
  static Future<int> getNearbyDriversCount({
    required double lat,
    required double lng,
    double radiusKm = 15.0,
  }) async {
    try {
      final h = await _authHeaders();
      final res = await http
          .get(
            Uri.parse(
              '$_baseUrl/drivers/nearby?lat=$lat&lng=$lng&radius_km=$radiusKm',
            ),
            headers: h,
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is List) return body.length;
        if (body is Map && body.containsKey('count')) {
          return body['count'] as int;
        }
        return 0;
      }
    } catch (_) {}
    return 0;
  }

  // ═══════════════════════════════════════════════════════
  //  VEHICLE  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Get the driver's vehicle info.
  static Future<Map<String, dynamic>?> getVehicle() async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/drivers/vehicle'), headers: h)
        .timeout(const Duration(seconds: 8));
    final data = _parse(res);
    return data['vehicle'] as Map<String, dynamic>?;
  }

  /// Create or update the driver's vehicle.
  static Future<Map<String, dynamic>> saveVehicle({
    required String make,
    required String model,
    required int year,
    String? color,
    required String plate,
    String? vin,
    String? vehicleType,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/drivers/vehicle'),
          headers: h,
          body: jsonEncode({
            'make': make,
            'model': model,
            'year': year,
            if (color != null) 'color': color,
            'plate': plate,
            if (vin != null) 'vin': vin,
            if (vehicleType != null) 'vehicle_type': vehicleType,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  DOCUMENT  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Get all driver documents.
  static Future<List<Map<String, dynamic>>> getDocuments() async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/drivers/documents'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Upload a document (base64 photo).
  static Future<Map<String, dynamic>> uploadDocument({
    required String docType,
    String? photoBase64,
    String? docNumber,
    String? expiryDate,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/drivers/documents'),
          headers: h,
          body: jsonEncode({
            'doc_type': docType,
            if (photoBase64 != null) 'photo': photoBase64,
            if (docNumber != null) 'doc_number': docNumber,
            if (expiryDate != null) 'expiry_date': expiryDate,
          }),
        )
        .timeout(const Duration(seconds: 30));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  RATING  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Submit a rating for a trip.
  static Future<Map<String, dynamic>> rateTrip({
    required int tripId,
    required int stars,
    String? comment,
    double tipAmount = 0.0,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/rate'),
          headers: h,
          body: jsonEncode({
            'stars': stars,
            if (comment != null) 'comment': comment,
            'tip_amount': tipAmount,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Get ratings for a user.
  static Future<Map<String, dynamic>> getUserRatings(int userId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/users/$userId/ratings'), headers: h)
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  CHAT  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Send a chat message during a trip.
  static Future<Map<String, dynamic>> sendChatMessage({
    required int tripId,
    required String message,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/chat'),
          headers: h,
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Get chat messages for a trip.
  static Future<List<Map<String, dynamic>>> getChatMessages(int tripId) async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/trips/$tripId/chat'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // ═══════════════════════════════════════════════════════
  //  NOTIFICATION  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Get user notifications.
  static Future<List<Map<String, dynamic>>> getNotifications() async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/notifications'), headers: h)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Mark a notification as read.
  static Future<void> markNotificationRead(int notifId) async {
    final h = await _authHeaders();
    await http
        .patch(Uri.parse('$_baseUrl/notifications/$notifId/read'), headers: h)
        .timeout(const Duration(seconds: 5));
  }

  /// Mark all notifications as read.
  static Future<void> markAllNotificationsRead() async {
    final h = await _authHeaders();
    await http
        .post(Uri.parse('$_baseUrl/notifications/read-all'), headers: h)
        .timeout(const Duration(seconds: 5));
  }

  // ═══════════════════════════════════════════════════════
  //  FORGOT PASSWORD
  // ═══════════════════════════════════════════════════════

  /// Request a password reset code.
  static Future<Map<String, dynamic>> forgotPassword(String identifier) async {
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/forgot-password'),
          headers: _jsonHeaders(),
          body: jsonEncode({'identifier': identifier}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Reset password with the code received.
  static Future<Map<String, dynamic>> resetPassword({
    required String code,
    required String newPassword,
  }) async {
    final res = await http
        .post(
          Uri.parse('$_baseUrl/auth/reset-password'),
          headers: _jsonHeaders(),
          body: jsonEncode({'code': code, 'new_password': newPassword}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  PROMO CODE
  // ═══════════════════════════════════════════════════════

  /// Validate and redeem a promo code.
  /// Returns `{"code": "...", "discount_percent": 15, "message": "..."}`.
  static Future<Map<String, dynamic>> validatePromoCode(String code) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/promo/validate'),
          headers: h,
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Create a PayPal order via backend proxy.
  static Future<Map<String, dynamic>> createPayPalOrder({
    required String amount,
    required String currency,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/payments/paypal/create-order'),
          headers: h,
          body: jsonEncode({'amount': amount, 'currency': currency}),
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  /// Capture a PayPal order after user approval.
  static Future<Map<String, dynamic>> capturePayPalOrder(String orderId) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/payments/paypal/capture-order'),
          headers: h,
          body: jsonEncode({'order_id': orderId}),
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  RIDER PAYMENT METHODS (server-synced)
  // ═══════════════════════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getRiderPaymentMethods() async {
    final h = await _authHeaders();
    final res = await http
        .get(Uri.parse('$_baseUrl/riders/payment-methods'), headers: h)
        .timeout(const Duration(seconds: 10));
    final body = _parse(res);
    if (body is List) return (body as List).cast<Map<String, dynamic>>();
    return [];
  }

  static Future<Map<String, dynamic>> addRiderPaymentMethod({
    required String methodType,
    required String displayName,
    String? stripePmId,
    bool setDefault = false,
  }) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/riders/payment-methods'),
          headers: h,
          body: jsonEncode({
            'method_type': methodType,
            'display_name': displayName,
            if (stripePmId != null) 'stripe_pm_id': stripePmId,
            'set_default': setDefault,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  static Future<void> deleteRiderPaymentMethod(int pmId) async {
    final h = await _authHeaders();
    await http
        .delete(Uri.parse('$_baseUrl/riders/payment-methods/$pmId'), headers: h)
        .timeout(const Duration(seconds: 10));
  }

  static Future<void> setDefaultRiderPaymentMethod(int pmId) async {
    final h = await _authHeaders();
    await http
        .patch(
          Uri.parse('$_baseUrl/riders/payment-methods/$pmId/default'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
  }

  // ═══════════════════════════════════════════════════════
  //  TRIP CHARGE
  // ═══════════════════════════════════════════════════════

  /// Charge the rider's saved default card for a completed trip.
  /// Returns the charge result: {status, payment_intent_id, amount, error?}
  static Future<Map<String, dynamic>> chargeTrip(int tripId) async {
    final h = await _authHeaders();
    final res = await http
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/charge'),
          headers: h,
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }
}

/// Simple exception with HTTP status code.
class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}
