import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/io_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'security_service.dart';
import 'firebase_storage_service.dart';
import 'photo_recovery_service.dart';
import 'user_session.dart';
import '../config/env.dart';

/// Simple in-memory cache entry with TTL
class _CacheEntry {
  final dynamic data;
  final DateTime timestamp;
  final Duration ttl;
  
  _CacheEntry(this.data, this.ttl) : timestamp = DateTime.now();
  
  bool get isExpired => DateTime.now().difference(timestamp) > ttl;
}

/// Communicates with the Cruise Ride backend (FastAPI + PostgreSQL).
///
/// The active server URL is loaded from SharedPreferences on startup so it
/// can be updated at runtime (e.g. after starting a new Cloudflare tunnel)
/// without rebuilding the app.  Use [setServerUrl] to persist a new URL and
/// [probeAndSetBestUrl] to auto-detect which endpoint is reachable.
class ApiService {
  // ── Known endpoints ────────────────────────────────────────────────────────

  /// Production Railway URL — works from any network (cellular, WiFi, etc.)
  static const String _productionUrl = 'https://cruiseapp2-production.up.railway.app';

  static const String _serverUrlPrefKey = 'cruise_server_url';

  // ── In-memory response cache for GET requests ────────────────────────
  static final Map<String, _CacheEntry> _responseCache = {};
  static final Map<String, Future<http.Response>> _inFlightRequests = {};
  
  /// Clear the response cache - call when user logs out or data changes
  static void clearCache() {
    _responseCache.clear();
    _inFlightRequests.clear();
    debugPrint('[ApiService] Response cache cleared');
  }
  
  /// Cache GET responses for a short time to reduce server load
  static Future<http.Response> _cachedGet(
    Uri url, {
    Map<String, String>? headers,
    Duration cacheTtl = const Duration(seconds: 5),
    bool useCache = true,
  }) async {
    final cacheKey = url.toString();
    
    // Check cache first
    if (useCache && _responseCache.containsKey(cacheKey)) {
      final entry = _responseCache[cacheKey]!;
      if (!entry.isExpired) {
        return entry.data as http.Response;
      }
      _responseCache.remove(cacheKey);
    }
    
    // Deduplicate concurrent requests for the same URL
    if (_inFlightRequests.containsKey(cacheKey)) {
      return await _inFlightRequests[cacheKey]!;
    }
    
    // Make the request and track it
    final requestFuture = _client.get(url, headers: headers).timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _inFlightRequests.remove(cacheKey);
        throw TimeoutException('Request to \${url.path} timed out');
      },
    );
    
    _inFlightRequests[cacheKey] = requestFuture;
    
    try {
      final response = await requestFuture;
      
      // Cache successful GET responses
      if (useCache && response.statusCode == 200) {
        _responseCache[cacheKey] = _CacheEntry(response, cacheTtl);
      }
      
      return response;
    } finally {
      _inFlightRequests.remove(cacheKey);
    }
  }

  /// Persistent IOClient backed by a tuned HttpClient.
  /// - autoUncompress: auto-decompresses gzip/deflate responses
  /// - connectionTimeout: 8 s — fail fast instead of hanging
  /// - idleTimeout: 60 s — keep TCP/TLS alive between calls
  /// - maxConnectionsPerHost: 10 — increased for parallel API calls
  static final http.Client _client = () {
    final inner = HttpClient()
      ..autoUncompress = true
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 60)
      ..maxConnectionsPerHost = 10;
    return IOClient(inner);
  }();

  /// In-memory active URL. Always Railway.
  static String _activeUrl = _productionUrl;

  /// Returns the URL currently in use by all API calls.
  static String get activeServerUrl => _activeUrl;

  /// Pre-resolve DNS for all API domains to eliminate lookup latency on first request.
  static Future<void> preResolveDns() async {
    await Future.wait([
      InternetAddress.lookup('cruiseapp2-production.up.railway.app').catchError((_) => <InternetAddress>[]),
      InternetAddress.lookup('api.mapbox.com').catchError((_) => <InternetAddress>[]),
      InternetAddress.lookup('maps.googleapis.com').catchError((_) => <InternetAddress>[]),
      InternetAddress.lookup('router.project-osrm.org').catchError((_) => <InternetAddress>[]),
    ]).timeout(const Duration(seconds: 3), onTimeout: () => []);
    debugPrint('[ApiService] DNS pre-resolution complete');
  }

  /// Lightweight connectivity check — pings DNS without adding dependencies.
  /// Uses dart:io InternetAddress.lookup with a 3-second timeout.
  static Future<bool> isOnline() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Returns true if [url] is a private/local network address that only
  /// works on the same WiFi — these must not be used on cellular.
  static bool _isLocalUrl(String url) {
    return url.startsWith('http://10.') ||
        url.startsWith('http://172.') ||
        url.startsWith('http://192.168.') ||
        url.startsWith('http://localhost') ||
        url.startsWith('http://127.');
  }

  /// Load persisted server URL from SharedPreferences, then check Firestore
  /// for a dynamically-updated tunnel URL.
  /// Call once in main() before runApp().
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_serverUrlPrefKey);
    if (saved != null && _isLocalUrl(saved)) {
      await prefs.remove(_serverUrlPrefKey);
    }
    if (saved != null && saved.isNotEmpty && !_isLocalUrl(saved)) {
      _activeUrl = saved;
    } else {
      _activeUrl = _productionUrl;
    }

    // Try to read the latest tunnel URL from Firestore (written by startup
    // script).  Cache-first for instant reads, then refresh from server.
    try {
      // Try cache first (instant, no network)
      DocumentSnapshot<Map<String, dynamic>>? doc;
      try {
        doc = await FirebaseFirestore.instance
            .collection('config')
            .doc('server')
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 1));
      } catch (_) {}

      // Then try server for freshest data
      try {
        doc = await FirebaseFirestore.instance
            .collection('config')
            .doc('server')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        // Cache version is fine
      }

      if (doc != null && doc.exists) {
        final raw = doc.data()?['tunnel_url'] as String? ??
                    doc.data()?['url'] as String?;
        if (raw != null && raw.isNotEmpty && raw.startsWith('http')) {
          _dynamicTunnelUrl = raw;
          _activeUrl = raw.trimRight().replaceAll(RegExp(r'/+$'), '');
          debugPrint('[ApiService] Firestore active URL: $_activeUrl');
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Firestore config read failed: $e');
    }

    debugPrint('[ApiService] active URL: $_activeUrl');
  }

  /// Dynamic tunnel URL fetched from Firestore at init.
  static String? _dynamicTunnelUrl;

  /// Update the active server URL.
  /// Local/private-network URLs are kept in memory only — never persisted —
  /// so the app always boots with the production URL on the next launch.
  static Future<void> setServerUrl(String url) async {
    _activeUrl = url.trimRight().replaceAll(RegExp(r'/+$'), '');
    if (!_isLocalUrl(_activeUrl)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_serverUrlPrefKey, _activeUrl);
    }
    debugPrint('[ApiService] server URL updated → $_activeUrl (persisted: ${!_isLocalUrl(_activeUrl)})');
  }

  /// Try each candidate URL with a lightweight health-check (`GET /health`).
  ///
  /// Strategy: probe ALL URLs in parallel — first 200 wins.
  /// This avoids the 5-second wait when production is down (cellular users
  /// hit the tunnel URL in <1 s instead of waiting for production to timeout).
  static Future<String?> probeAndSetBestUrl({
    List<String>? candidates,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    const probeHeaders = {
      'Accept': 'application/json',
      'ngrok-skip-browser-warning': 'true',
    };

    // Build the full list of URLs to try — all at once, in parallel.
    // When Firestore has a dynamic URL, skip Railway so the configured
    // backend always wins (Railway health returns 200 even when broken).
    final allCandidates = candidates ?? (_dynamicTunnelUrl != null
        ? [_dynamicTunnelUrl!]
        : [_productionUrl, _activeUrl]);
    final urls = allCandidates
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();

    if (urls.isNotEmpty) {
      final completer = Completer<String?>();
      var pending = urls.length;

      for (final url in urls) {
        _client
            .get(Uri.parse('$url/health'), headers: probeHeaders)
            .timeout(timeout)
            .then((res) {
              if (!completer.isCompleted && res.statusCode == 200) {
                completer.complete(url);
              }
            })
            .catchError((_) {})
            .whenComplete(() {
              pending--;
              if (pending == 0 && !completer.isCompleted) {
                completer.complete(null);
              }
            });
      }

      final winner = await completer.future
          .timeout(timeout + const Duration(seconds: 1), onTimeout: () => null);

      if (winner != null) {
        await setServerUrl(winner);
        debugPrint('[ApiService] probe → $winner');
        return winner;
      }
    }

    // Last resort: use production URL
    await setServerUrl(_productionUrl);
    debugPrint('[ApiService] probe → fallback to $_productionUrl');
    return _productionUrl;
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
  static bool _isHandlingUnauthorized = false;
  static bool _loginInProgress = false;

  /// M2: Set this callback to navigate to login when JWT expires and refresh fails.
  static void Function()? onUnauthorized;

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

  /// M2: Called on 401 — attempts refresh, clears token and fires [onUnauthorized] if refresh fails.
  /// Suppressed during login flow to prevent false logout on auth-related 401s.
  static Future<void> _handleUnauthorized() async {
    if (_isHandlingUnauthorized || _loginInProgress) return;
    _isHandlingUnauthorized = true;
    try {
      final refreshed = await refreshAccessToken();
      if (!refreshed) {
        await clearToken();
        onUnauthorized?.call();
      }
    } finally {
      _isHandlingUnauthorized = false;
    }
  }

  /// Attempt to refresh the access token using the refresh token.
  /// Returns true if successful, false otherwise.
  static Future<bool> refreshAccessToken() async {
    if (_isRefreshing) return false;
    _isRefreshing = true;
    try {
      final refreshToken = await _getRefreshToken();
      if (refreshToken == null) return false;
      final res = await _client
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
    // Clear all caches on logout
    clearCache();
    clearUserCache();
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
    // Enable compression and keep-alive for all requests
    final requestHeaders = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Encoding': 'gzip, deflate',
      'Connection': 'keep-alive',
      if (token != null) 'Authorization': 'Bearer $token',
      'X-API-Key': _apiKey,
      'X-Timestamp': timestamp,
      'X-Nonce': nonce,
      'X-Signature': signature,
      'X-Device-FP': SecurityService.deviceFingerprint.length >= 16
          ? SecurityService.deviceFingerprint.substring(0, 16)
          : SecurityService.deviceFingerprint,
      'X-Client-Version': '1.0.0',
      'ngrok-skip-browser-warning': 'true',
    };
    return requestHeaders;
  }

  /// Headers with the current JWT attached (for authenticated endpoints).
  static Future<Map<String, String>> _authHeaders() async {
    final token = await getToken();
    return _jsonHeaders(token);
  }

  // ── Retry + auto-reconnect ────────────────────────────────────────────────

  static int _consecutiveFailures = 0;

  /// Wraps an HTTP call with exponential backoff (up to [maxAttempts]).
  /// On connection errors, triggers [probeAndSetBestUrl] to find a live server.
  static Future<http.Response> _withRetry(
    Future<http.Response> Function() request, {
    int maxAttempts = 3,
    Duration baseDelay = const Duration(seconds: 1),
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final res = await request();
        _consecutiveFailures = 0;
        return res;
      } on SocketException catch (e) {
        _consecutiveFailures++;
        debugPrint('[ApiService] SocketException attempt $attempt/$maxAttempts: $e');
        if (attempt < maxAttempts) {
          if (_consecutiveFailures >= 2) {
            debugPrint('[ApiService] Probing for best URL...');
            await probeAndSetBestUrl();
          }
          await Future.delayed(baseDelay * pow(2, attempt - 1).toInt());
        } else {
          rethrow;
        }
      } on TimeoutException catch (e) {
        _consecutiveFailures++;
        debugPrint('[ApiService] Timeout attempt $attempt/$maxAttempts: $e');
        if (attempt < maxAttempts) {
          await probeAndSetBestUrl();
          await Future.delayed(baseDelay * pow(2, attempt - 1).toInt());
        } else {
          rethrow;
        }
      } on HandshakeException catch (e) {
        debugPrint('[ApiService] TLS error: $e');
        rethrow;
      }
    }
    throw ApiException(503, 'Server unreachable after $maxAttempts attempts');
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
    // M2: on 401, attempt token refresh in background; signal logout if refresh fails
    if (res.statusCode == 401) {
      _handleUnauthorized().ignore();
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
    final res = await _client
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

  /// Send OTP verification code via backend (supports both email and phone).
  /// Returns `{ ok, method, code? }` — `code` is present when email/SMS fails
  /// and the backend returns the code directly for display.
  static Future<Map<String, dynamic>> sendOtp({
    String? email,
    String? phone,
  }) async {
    final body = <String, dynamic>{};
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (phone != null && phone.isNotEmpty) body['phone'] = phone;
    try {
      final res = await _client
          .post(
            Uri.parse('$_baseUrl/auth/send-otp'),
            headers: _jsonHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return {'ok': false};
    } catch (e) {
      debugPrint('⚠️  sendOtp failed: $e');
      return {'ok': false};
    }
  }

  /// Verify OTP code submitted by user.
  /// Returns `{ valid: true/false }`.
  static Future<bool> verifyOtp({String? email, String? phone, required String code}) async {
    final body = <String, dynamic>{'code': code};
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (phone != null && phone.isNotEmpty) body['phone'] = phone;
    try {
      final res = await _client
          .post(
            Uri.parse('$_baseUrl/auth/verify-otp'),
            headers: _jsonHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['valid'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('⚠️  verifyOtp failed: $e');
      return false;
    }
  }

  /// Resend email verification code for the current user.
  static Future<Map<String, dynamic>> resendEmailVerification() async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/resend-email-verification'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Verify email with a code.
  static Future<Map<String, dynamic>> verifyEmail(String code) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/verify-email'),
          headers: h,
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ── Saved Addresses CRUD ──

  /// ✅ QUICK WIN #3: Added 30s cache to reduce redundant API calls
  /// Saved addresses rarely change, safe to cache for UI responsiveness
  static Future<List<dynamic>> getSavedAddresses() async {
    final h = await _authHeaders();
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/favorites'),
      headers: h,
      cacheTtl: const Duration(seconds: 30),
      useCache: true,
    );
    final parsed = _parse(res);
    if (parsed['list'] != null) return parsed['list'] as List;
    // The endpoint returns a JSON array directly
    return jsonDecode(res.body) as List? ?? [];
  }

  static Future<Map<String, dynamic>> addSavedAddress({
    required String label,
    required String address,
    required double lat,
    required double lng,
    String icon = 'star',
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/favorites'),
          headers: h,
          body: jsonEncode({'label': label, 'address': address, 'lat': lat, 'lng': lng, 'icon': icon}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  static Future<Map<String, dynamic>> updateSavedAddress({
    required int id,
    String? label,
    String? address,
    double? lat,
    double? lng,
    String? icon,
  }) async {
    final h = await _authHeaders();
    final body = <String, dynamic>{};
    if (label != null) body['label'] = label;
    if (address != null) body['address'] = address;
    if (lat != null) body['lat'] = lat;
    if (lng != null) body['lng'] = lng;
    if (icon != null) body['icon'] = icon;
    final res = await _client
        .put(
          Uri.parse('$_baseUrl/favorites/$id'),
          headers: h,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  static Future<Map<String, dynamic>> deleteSavedAddress(int id) async {
    final h = await _authHeaders();
    final res = await _client
        .delete(Uri.parse('$_baseUrl/favorites/$id'), headers: h)
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ── Wait Time for Drivers ──

  /// Start wait timer when driver arrives at pickup.
  static Future<Map<String, dynamic>> startWaitTime(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
        .post(Uri.parse('$_baseUrl/trips/$tripId/wait-time/start'), headers: h)
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// End wait timer and calculate charges.
  static Future<Map<String, dynamic>> endWaitTime(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
        .post(Uri.parse('$_baseUrl/trips/$tripId/wait-time/end'), headers: h)
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Check whether an email or phone is already registered.
  /// Returns `true` if the account exists.
  static Future<bool> checkExists(String identifier, {String? role}) async {
    try {
      final payload = <String, dynamic>{'identifier': identifier.trim()};
      if (role != null) payload['role'] = role;
      final res = await _client.post(
        Uri.parse('$_baseUrl/auth/check-exists'),
        headers: _jsonHeaders(),
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 8));
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
    _loginInProgress = true;
    try {
      final body = <String, dynamic>{
        'identifier': identifier,
        'password': password,
      };
      if (role != null) body['role'] = role;
      final res = await _client
          .post(
            Uri.parse('$_baseUrl/auth/login'),
            headers: _jsonHeaders(),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      return _parse(res);
    } catch (e) {
      _loginInProgress = false; // clear on failure so flag doesn't stick
      rethrow;
    }
  }

  /// Exchange the temporary login_token for a full JWT.
  /// Call this after the verification code has been confirmed.
  /// Returns `{ access_token, token_type, user: { … } }`.
  static Future<Map<String, dynamic>> completeLogin({
    required String loginToken,
  }) async {
    try {
      final res = await _client
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
    } finally {
      _loginInProgress = false;
    }
  }

  /// Authenticate via Google or Apple OAuth token.
  static Future<Map<String, dynamic>> socialAuth({
    required String provider,
    required String idToken,
    String? firstName,
    String? lastName,
    String? photoUrl,
    String role = 'rider',
  }) async {
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/social'),
          headers: _jsonHeaders(),
          body: jsonEncode({
            'provider': provider,
            'id_token': idToken,
            if (firstName != null) 'first_name': firstName,
            if (lastName != null) 'last_name': lastName,
            if (photoUrl != null) 'photo_url': photoUrl,
            'role': role,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final data = _parse(res);
    final token = data['access_token'] as String;
    await _saveToken(token);
    if (data['refresh_token'] != null) {
      await _saveRefreshToken(data['refresh_token'] as String);
    }
    _cachedUser = data['user'] as Map<String, dynamic>?;
    return data;
  }

  /// Get the current user's profile (requires valid JWT).
  /// Returns user map or `null` if the token is invalid/expired.
  static Future<Map<String, dynamic>?> getMe() async {
    final token = await getToken();
    if (token == null) return null;

    try {
      // Use cached GET for better performance - cache for 2 seconds
      final res = await _cachedGet(
        Uri.parse('$_baseUrl/auth/me'),
        headers: _jsonHeaders(token),
        cacheTtl: const Duration(seconds: 2),
        useCache: true,
      );
      if (res.statusCode == 200) return jsonDecode(res.body);
      // Auto-refresh on 401
      if (res.statusCode == 401) {
        final refreshed = await refreshAccessToken();
        if (refreshed) {
          final newToken = await getToken();
          final retry = await _client
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

    final res = await _client
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
    final res = await _client
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
      await _client
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
  /// Uses retry logic to survive transient failures.
  static Future<Map<String, dynamic>> createSupportChat({
    String subject = '',
    String locale = 'en',
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await _withRetry(
      () => _client
          .post(
            Uri.parse('$_baseUrl/support/chats'),
            headers: _jsonHeaders(token),
            body: jsonEncode({'subject': subject, 'locale': locale}),
          )
          .timeout(const Duration(seconds: 12)),
      maxAttempts: 3,
    );
    return _parse(res);
  }

  /// List all support chats for the current user.
  static Future<List<Map<String, dynamic>>> getSupportChats() async {
    final token = await getToken();
    if (token == null) return [];
    final res = await _withRetry(
      () => _client
          .get(Uri.parse('$_baseUrl/support/chats'), headers: _jsonHeaders(token))
          .timeout(const Duration(seconds: 10)),
      maxAttempts: 2,
    );
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
    final res = await _withRetry(
      () => _client
          .get(
            Uri.parse('$_baseUrl/support/chats/$chatId/messages'),
            headers: _jsonHeaders(token),
          )
          .timeout(const Duration(seconds: 10)),
      maxAttempts: 2,
    );
    final data = _parse(res);
    final list = data['data'];
    return list is List ? List<dynamic>.from(list) : [];
  }

  /// Send a support chat message.
  /// Uses retry logic so messages are not lost on transient failures.
  static Future<Map<String, dynamic>> sendSupportMessage(
    int chatId,
    String message,
  ) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await _withRetry(
      () => _client
          .post(
            Uri.parse('$_baseUrl/support/chats/$chatId/messages'),
            headers: _jsonHeaders(token),
            body: jsonEncode({'message': message}),
          )
          .timeout(const Duration(seconds: 12)),
      maxAttempts: 3,
    );
    return _parse(res);
  }

  /// Close a support chat (user-facing).
  static Future<void> closeSupportChat(int chatId) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    await _withRetry(
      () => _client
          .patch(
            Uri.parse('$_baseUrl/support/chats/$chatId/close-user'),
            headers: _jsonHeaders(token),
          )
          .timeout(const Duration(seconds: 10)),
      maxAttempts: 2,
    );
  }

  /// Set typing status for a support chat.
  static Future<void> setSupportTypingStatus(int chatId, bool typing) async {
    final token = await getToken();
    if (token == null) return;
    try {
      await _client
          .post(
            Uri.parse('$_baseUrl/support/chats/$chatId/typing'),
            headers: _jsonHeaders(token),
            body: jsonEncode({'typing': typing}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Non-critical — ignore errors
    }
  }

  /// Get the support voice call phone number.
  static Future<String?> getSupportPhoneNumber() async {
    try {
      final res = await _client
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
    final res = await _client
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
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/auth/verification-status'),
      headers: _jsonHeaders(token),
      cacheTtl: const Duration(seconds: 60),
    );
    return _parse(res);
  }

  /// Driver approval status from dispatch (pending/approved/rejected).
  static Future<Map<String, dynamic>> getDriverApprovalStatus() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/auth/driver-approval-status'),
      headers: _jsonHeaders(token),
      cacheTtl: const Duration(seconds: 60),
    );
    return _parse(res);
  }

  /// Check account status (dispatch may have blocked/deleted).
  /// ✅ QUICK WIN #3: Added 10s cache - called every 30s in background
  /// Reduces unnecessary API calls while keeping reasonable freshness
  static Future<String> getAccountStatus() async {
    final token = await getToken();
    if (token == null) return 'active'; // no token yet — assume active, don't trigger logout
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/auth/account-status'),
      headers: _jsonHeaders(token),
      cacheTtl: const Duration(seconds: 10),
      useCache: true,
    );
    // Handle 401 gracefully — attempt refresh but don't trigger global logout
    // from a background poll. The main _parse 401 handler is too aggressive here.
    if (res.statusCode == 401) {
      final refreshed = await refreshAccessToken();
      if (refreshed) {
        final newToken = await getToken();
        final retry = await _cachedGet(
          Uri.parse('$_baseUrl/auth/account-status'),
          headers: _jsonHeaders(newToken),
          cacheTtl: const Duration(seconds: 10),
        );
        if (retry.statusCode == 200) {
          final d = jsonDecode(retry.body);
          return (d is Map ? d['status'] as String? : null) ?? 'active';
        }
      }
      return 'active'; // refresh failed — don't logout from background poll
    }
    final data = _parse(res);
    return data['status'] as String? ?? 'active';
  }

  // ═══════════════════════════════════════════════════════
  //  PHOTO  ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Upload a profile photo to Firebase Storage (permanent URL).
  /// Falls back to base64 backend upload if Firebase Storage fails.
  static Future<String> uploadPhoto(String filePath) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    // Primary: Firebase Storage — permanent URL, survives server restarts
    try {
      final me = await getMe();
      final userId = int.tryParse(me?['id']?.toString() ?? '') ?? 0;
      final userUid = FirebaseAuth.instance.currentUser?.uid ?? userId.toString();
      final role = (me?['role']?.toString() ?? 'rider').toLowerCase();
      final url =
          await FirebaseStorageService.uploadProfilePhoto(filePath, userId, role);
      
      // Update Firestore so Dispatch shows the photo immediately
      unawaited(
        FirebaseStorageService.updateFirestorePhotoUrl(userId, url, role),
      );
      
      // Also update Firebase Auth photoURL for cross-device consistency
      unawaited(Future(() async {
        try {
          await FirebaseAuth.instance.currentUser?.updatePhotoURL(url);
        } catch (_) {}
      }));
      
      // Sync URL back to backend DB so /auth/me returns the correct photo_url
      unawaited(_syncPhotoUrlToBackend(url, token));
      
      // Save to all 4 tiers: SharedPreferences, Firebase Auth, Firestore, Storage
      // This ensures photos survive logouts, app updates, and device changes
      // Include role to prevent rider/driver photo cross-contamination
      unawaited(PhotoRecoveryService.savePhotoEveryWhere(userUid, role, url));
      
      // Legacy: also save through UserSession
      unawaited(UserSession.savePhotoUrl(url));
      
      return url;
    } catch (e) {
      debugPrint('[ApiService] Firebase Storage upload failed, using backend: $e');
    }

    // Fallback: base64 upload to backend
    final bytes = await File(filePath).readAsBytes();
    final b64 = base64Encode(bytes);
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/photo'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'photo': b64}),
        )
        .timeout(const Duration(seconds: 30));
    final data = _parse(res);
    return data['photo_url'] as String? ?? '';
  }

  /// Notify the backend of a Firebase Storage photo URL so the DB stays in sync.
  static Future<void> _syncPhotoUrlToBackend(String url, String token) async {
    try {
      await _client
          .post(
            Uri.parse('$_baseUrl/auth/photo-url'),
            headers: _jsonHeaders(token),
            body: jsonEncode({'photo_url': url}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[ApiService] _syncPhotoUrlToBackend failed (non-fatal): $e');
    }
  }

  /// Download a profile photo from the server and save to local file.
  /// [photoUrl] may be a relative path like "/photos/user_1.jpg" or a full URL
  /// like "https://firebasestorage.googleapis.com/...".
  /// Returns the local file path, or empty string on failure.
  static Future<String> downloadPhoto(String photoUrl) async {
    try {
      final url = photoUrl.startsWith('http') ? photoUrl : '$_baseUrl$photoUrl';
      final res = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return '';
      final dir = await getApplicationDocumentsDirectory();
      // Use Uri.parse so pathSegments strips query params automatically,
      // then URL-decode (handles Firebase Storage %2F-encoded paths).
      final segments = Uri.parse(url).pathSegments;
      String rawName = segments.isNotEmpty ? segments.last : 'profile_photo';
      rawName = Uri.decodeComponent(rawName);
      // Sanitize: keep only safe filename chars (alphanumeric, dot, underscore, hyphen)
      final safeName = rawName.replaceAll(RegExp(r'[^\w.\-]'), '_');
      final ext = safeName.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final filename = safeName.isNotEmpty ? safeName : 'profile_photo.$ext';
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
        .post(Uri.parse('$_baseUrl/trips/$tripId/cancel'), headers: h)
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Get a trip by ID (for polling status).
  static Future<Map<String, dynamic>> getTrip(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/drivers/$driverId/stats'),
      headers: h,
      cacheTtl: const Duration(seconds: 30),
    );
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

    final res = await _cachedGet(
      Uri.parse('$_baseUrl/drivers/earnings?period=$period'),
      headers: _jsonHeaders(token),
      cacheTtl: const Duration(seconds: 30),
    );

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

  /// Save FCM device token for push notifications.
  static Future<void> saveFcmToken(String fcmToken) async {
    try {
      final token = await getToken();
      if (token == null) return;
      await _withRetry(() => _client
          .post(
            Uri.parse('$_baseUrl/auth/fcm-token'),
            headers: _jsonHeaders(token),
            body: jsonEncode({'token': fcmToken}),
          )
          .timeout(const Duration(seconds: 8)));
    } catch (e) {
      debugPrint('[ApiService] FCM token save failed: $e');
    }
  }

  /// Start Stripe Connect onboarding — returns the onboarding URL.
  static Future<String> getStripeConnectLink() async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/drivers/stripe-connect'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 15));
    final data = _parse(res);
    return data['url'] as String;
  }

  /// Check if driver has completed Stripe Connect onboarding.
  static Future<Map<String, dynamic>> getStripeConnectStatus() async {
    final token = await getToken();
    if (token == null) return {'connected': false};
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/drivers/stripe-connect/status'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
    return {'connected': false};
  }

  /// Request a cashout of driver earnings.
  static Future<Map<String, dynamic>> requestCashout({
    required double amount,
  }) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');

    final res = await _client
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

    final res = await _client
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

  // ═══════════════════════════════════════════════════════
  //  REFERRAL ENDPOINTS
  // ═══════════════════════════════════════════════════════

  /// Get or generate the user's unique referral code + stats.
  static Future<Map<String, dynamic>> getReferralCode() async {
    final token = await getToken();
    if (token == null) return {};
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/auth/referral-code'),
      headers: _jsonHeaders(token),
      cacheTtl: const Duration(minutes: 10),
    );
    if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
    return {};
  }

  /// Apply a referral code entered by the user.
  static Future<Map<String, dynamic>> applyReferralCode(String code) async {
    final token = await getToken();
    if (token == null) throw ApiException(401, 'Not logged in');
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/apply-referral'),
          headers: _jsonHeaders(token),
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Get list of users I've referred and total bonus earned.
  static Future<Map<String, dynamic>> getMyReferrals() async {
    final token = await getToken();
    if (token == null) return {'referrals': [], 'total_bonus': 0.0};
    final res = await _client
        .get(Uri.parse('$_baseUrl/auth/referrals'), headers: _jsonHeaders(token))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
    return {'referrals': [], 'total_bonus': 0.0};
  }

  /// Get next scheduled auto-payout date and pending balance.
  static Future<Map<String, dynamic>> getNextPayoutDate() async {
    final token = await getToken();
    if (token == null) return {};
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/drivers/payouts/next-date'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
    return {};
  }

  /// Get driver's payout methods.
  static Future<List<Map<String, dynamic>>> getPayoutMethods() async {
    final token = await getToken();
    if (token == null) return [];

    final res = await _client
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

    final res = await _client
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

    await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    String? reason,
  }) async {
    final h = await _authHeaders();
    var uri = '$_baseUrl/dispatch/driver/reject?offer_id=$offerId&driver_id=$driverId';
    if (reason != null && reason.isNotEmpty) {
      uri += '&reason=${Uri.encodeComponent(reason)}';
    }
    final res = await _client
        .post(
          Uri.parse(uri),
          headers: h,
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Rider polls dispatch status to see if a driver accepted.
  static Future<Map<String, dynamic>> getDispatchStatus(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
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
            'key': Env.mapsServicesKey,
            'mode': 'driving',
          });
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
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
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        return {'source': 'osrm', ...data};
      }
    } catch (_) {}

    return null;
  }

  /// Get turn-by-turn navigation instructions from backend (Google Directions API).
  /// Returns parsed steps with distance, duration, and maneuver types.
  static Future<Map<String, dynamic>?> getNavigationInstructions({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    try {
      final h = await _authHeaders();
      final uri = Uri.parse(
        '$_baseUrl/navigation/instructions?origin_lat=$originLat&origin_lng=$originLng&dest_lat=$destLat&dest_lng=$destLng',
      );
      final res = await _client
          .get(uri, headers: h)
          .timeout(const Duration(seconds: 15));
      
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error fetching navigation instructions: $e');
      return null;
    }
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
      final res = await _client
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
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/drivers/vehicle'),
      headers: h,
      cacheTtl: const Duration(minutes: 5),
    );
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
    final res = await _client
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
  /// ✅ QUICK WIN #3: Added 5s cache for notification list
  /// Short TTL keeps them fresh while reducing API load
  static Future<List<Map<String, dynamic>>> getNotifications() async {
    final h = await _authHeaders();
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/notifications'),
      headers: h,
      cacheTtl: const Duration(seconds: 5),
      useCache: true,
    );
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final list = jsonDecode(res.body) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Mark a notification as read.
  static Future<void> markNotificationRead(int notifId) async {
    final h = await _authHeaders();
    await _client
        .patch(Uri.parse('$_baseUrl/notifications/$notifId/read'), headers: h)
        .timeout(const Duration(seconds: 5));
  }

  /// Mark all notifications as read.
  static Future<void> markAllNotificationsRead() async {
    final h = await _authHeaders();
    await _client
        .post(Uri.parse('$_baseUrl/notifications/read-all'), headers: h)
        .timeout(const Duration(seconds: 5));
  }

  // ═══════════════════════════════════════════════════════
  //  FORGOT PASSWORD
  // ═══════════════════════════════════════════════════════

  /// Request a password reset code.
  static Future<Map<String, dynamic>> forgotPassword(String identifier) async {
    final res = await _client
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
    final res = await _client
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
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/promo/validate'),
          headers: h,
          body: jsonEncode({'code': code}),
        )
        .timeout(const Duration(seconds: 8));
    return _parse(res);
  }

  /// Create a PayPal order via backend proxy (secrets stay server-side).
  /// Returns `{ order_id, approval_url }`.
  static Future<Map<String, dynamic>> createPayPalOrder({
    required String amount,
    String currency = 'USD',
    String description = 'Cruise ride payment',
  }) async {
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/paypal/create-order'),
          headers: _jsonHeaders(),
          body: jsonEncode({
            'amount': amount,
            'currency': currency,
            'description': description,
          }),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }

  /// Capture a PayPal order after user approval.
  static Future<Map<String, dynamic>> capturePayPalOrder(String orderId) async {
    final h = await _authHeaders();
    final res = await _client
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
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/riders/payment-methods'),
      headers: h,
      cacheTtl: const Duration(seconds: 30),
    );
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
    final res = await _client
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
    await _client
        .delete(Uri.parse('$_baseUrl/riders/payment-methods/$pmId'), headers: h)
        .timeout(const Duration(seconds: 10));
  }

  static Future<void> setDefaultRiderPaymentMethod(int pmId) async {
    final h = await _authHeaders();
    await _client
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
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/charge'),
          headers: h,
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  STRIPE SETUP INTENT
  // ═══════════════════════════════════════════════════════

  /// Create a Stripe SetupIntent for saving a card for future off-session charges.
  /// Returns the client_secret needed to confirm via Stripe SDK.
  static Future<String?> createSetupIntent() async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/payments/setup-intent'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    final data = _parse(res);
    return data['client_secret'] as String?;
  }

  // ═══════════════════════════════════════════════════════
  //  STRIPE PAYMENT INTENT
  // ═══════════════════════════════════════════════════════

  /// Create a Stripe PaymentIntent for authorizing a ride payment.
  /// Returns the full response map with client_secret, payment_intent_id, etc.
  static Future<Map<String, dynamic>> createPaymentIntent({
    required int amountCents,
    String currency = 'usd',
    String? paymentMethodId,
    int? tripId,
  }) async {
    final h = await _authHeaders();
    final body = <String, dynamic>{
      'amount': amountCents,
      'currency': currency,
    };
    if (paymentMethodId != null) body['payment_method_id'] = paymentMethodId;
    if (tripId != null) body['trip_id'] = tripId;
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/payments/create-intent'),
          headers: {...h, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  REFUNDS
  // ═══════════════════════════════════════════════════════

  /// Request a refund for a paid trip. [amount] null = full refund.
  static Future<Map<String, dynamic>> refundTrip(
    int tripId, {
    double? amount,
    String reason = 'requested_by_customer',
  }) async {
    final h = await _authHeaders();
    final body = <String, dynamic>{'reason': reason};
    if (amount != null) body['amount'] = amount;
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/refund'),
          headers: {...h, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  FARE BREAKDOWN
  // ═══════════════════════════════════════════════════════

  /// Get detailed fare breakdown for a trip.
  static Future<Map<String, dynamic>> getFareBreakdown(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/trips/$tripId/fare-breakdown'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  SURGE PRICING
  // ═══════════════════════════════════════════════════════

  /// Get current surge multiplier for a location.
  static Future<Map<String, dynamic>> getCurrentSurge(
    double lat,
    double lng,
  ) async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/surge/current?lat=$lat&lng=$lng'),
          headers: h,
        )
        .timeout(const Duration(seconds: 5));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  SAFETY / SOS
  // ═══════════════════════════════════════════════════════

  /// Send SOS alert with location to trusted contacts via backend.
  static Future<Map<String, dynamic>> sendSosAlert({
    required double lat,
    required double lng,
    required int tripId,
    required List<String> contactPhones,
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/safety/sos-alert'),
          headers: {...h, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'lat': lat,
            'lng': lng,
            'trip_id': tripId,
            'contact_phones': contactPhones,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  BACKGROUND CHECK
  // ═══════════════════════════════════════════════════════

  /// Initiate a background check for the current driver via Checkr.
  static Future<Map<String, dynamic>> initiateBackgroundCheck({
    String? firstName,
    String? lastName,
    String? dob,
    String? ssnLast4,
    String? licenseNumber,
    String? licenseState,
  }) async {
    final h = await _authHeaders();
    final body = <String, dynamic>{};
    if (firstName != null) body['first_name'] = firstName;
    if (lastName != null) body['last_name'] = lastName;
    if (dob != null) body['dob'] = dob;
    if (ssnLast4 != null) body['ssn_last4'] = ssnLast4;
    if (licenseNumber != null) body['license_number'] = licenseNumber;
    if (licenseState != null) body['license_state'] = licenseState;
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/drivers/background-check'),
          headers: h,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }

  /// Get the current background check status.
  static Future<Map<String, dynamic>> getBackgroundCheckStatus() async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/drivers/background-check/status'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  TRIP SHARING
  // ═══════════════════════════════════════════════════════

  /// Generate a share token/URL for a trip.
  static Future<Map<String, dynamic>> shareTrip(int tripId) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/trips/$tripId/share'),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  DRIVER DEMAND HEATMAP
  // ═══════════════════════════════════════════════════════

  /// Get demand heatmap data for drivers.
  static Future<Map<String, dynamic>> getDriverDemandHeatmap(
    double lat,
    double lng, {
    double radiusKm = 10.0,
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse(
            '$_baseUrl/drivers/demand-heatmap?lat=$lat&lng=$lng&radius_km=$radiusKm',
          ),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  FARE ESTIMATION
  // ═══════════════════════════════════════════════════════

  /// Estimate fare for a ride (server-side validation of client estimates).
  static Future<Map<String, dynamic>> estimateFare({
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    String vehicleType = 'comfort',
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse(
            '$_baseUrl/estimate-fare?pickup_lat=$pickupLat&pickup_lng=$pickupLng'
            '&dropoff_lat=$dropoffLat&dropoff_lng=$dropoffLng&vehicle_type=$vehicleType',
          ),
          headers: h,
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  // ═══════════════════════════════════════════════════════
  //  PRIVACY & DATA EXPORT (GDPR/CCPA)
  // ═══════════════════════════════════════════════════════

  /// Export all user data for GDPR/CCPA compliance.
  static Future<Map<String, dynamic>> exportUserData() async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/auth/export-data'),
          headers: h,
        )
        .timeout(const Duration(seconds: 30));
    return _parse(res);
  }

  /// Record user consent action (terms, privacy, location, analytics, ads).
  static Future<Map<String, dynamic>> recordConsent({
    required String consentType,
    required String action, // 'accepted' or 'revoked'
    String? version,
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/auth/consent'),
          headers: h,
          body: jsonEncode({
            'consent_type': consentType,
            'action': action,
            if (version != null) 'version': version,
          }),
        )
        .timeout(const Duration(seconds: 10));
    return _parse(res);
  }

  /// Update device info and privacy preferences in one call.
  static Future<void> updateDeviceInfo({
    String? appVersion,
    String? deviceModel,
    String? osVersion,
    bool? privacyLocation,
    bool? privacyAnalytics,
    bool? privacyAds,
  }) async {
    final updates = <String, dynamic>{};
    if (appVersion != null) updates['app_version'] = appVersion;
    if (deviceModel != null) updates['device_model'] = deviceModel;
    if (osVersion != null) updates['os_version'] = osVersion;
    if (privacyLocation != null) updates['privacy_location'] = privacyLocation;
    if (privacyAnalytics != null) updates['privacy_analytics'] = privacyAnalytics;
    if (privacyAds != null) updates['privacy_ads'] = privacyAds;
    if (updates.isNotEmpty) {
      await updateMe(updates);
    }
  }

  // ═══════════════════════════════════════════════════════
  //  WALLET (Feature 12.2)
  // ═══════════════════════════════════════════════════════

  /// Get current wallet balance.
  /// Returns: {id, balance, currency, updated_at}
  static Future<Map<String, dynamic>> getWalletBalance() async {
    final h = await _authHeaders();
    final res = await _cachedGet(
      Uri.parse('$_baseUrl/wallet/balance'),
      headers: h,
      cacheTtl: const Duration(seconds: 10),
    );
    return _parse(res);
  }

  /// Get wallet transactions history.
  /// Returns: {balance, currency, transactions[]}
  static Future<Map<String, dynamic>> getWalletTransactions({
    int limit = 50,
    int offset = 0,
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .get(
          Uri.parse('$_baseUrl/wallet/transactions?limit=$limit&offset=$offset'),
          headers: h,
        )
        .timeout(const Duration(seconds: 15));
    return _parse(res);
  }

  /// Top up wallet with amount.
  /// Returns: {status, new_balance, transaction}
  static Future<Map<String, dynamic>> topUpWallet({
    required double amount,
    String? paymentMethodId,
  }) async {
    final h = await _authHeaders();
    final body = <String, dynamic>{'amount': amount};
    if (paymentMethodId != null) body['payment_method_id'] = paymentMethodId;
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/wallet/top-up'),
          headers: {...h, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res);
  }

  /// Pay for a ride using wallet balance.
  /// Returns: {status, new_balance, amount_paid}
  static Future<Map<String, dynamic>> payRideWithWallet({
    required int tripId,
    required double amount,
  }) async {
    final h = await _authHeaders();
    final res = await _client
        .post(
          Uri.parse('$_baseUrl/wallet/pay-ride?trip_id=$tripId&amount=$amount'),
          headers: h,
        )
        .timeout(const Duration(seconds: 15));
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
