import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Periodically pings the backend server to keep it alive.
///
/// Free-tier hosting (Render, Railway, etc.) and ngrok tunnels can
/// go to sleep after inactivity. This service sends a lightweight
/// health-check every [interval] to prevent that.
class KeepAliveService {
  KeepAliveService._();
  static final KeepAliveService instance = KeepAliveService._();

  Timer? _timer;
  bool _running = false;
  int _consecutiveFailures = 0;
  static const int _maxFailuresBeforeReprobe = 3;

  /// Start pinging the server every [interval].
  /// Safe to call multiple times — only one timer runs at a time.
  void start({Duration interval = const Duration(seconds: 45)}) {
    if (_running) return;
    _running = true;
    _consecutiveFailures = 0;
    debugPrint('[KeepAlive] Started (every ${interval.inSeconds}s)');
    // Immediate first ping
    _ping();
    _timer = Timer.periodic(interval, (_) => _ping());
  }

  /// Stop the keep-alive pings.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    debugPrint('[KeepAlive] Stopped');
  }

  bool get isRunning => _running;

  Future<void> _ping() async {
    final url = ApiService.activeServerUrl;
    try {
      final res = await http
          .get(
            Uri.parse('$url/health'),
            headers: {
              'Accept': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
          )
          .timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        _consecutiveFailures = 0;
      } else {
        _onFailure('HTTP ${res.statusCode}');
      }
    } catch (e) {
      _onFailure('$e');
    }
  }

  void _onFailure(String reason) {
    _consecutiveFailures++;
    debugPrint(
      '[KeepAlive] Ping failed ($_consecutiveFailures): $reason',
    );

    // After several consecutive failures, try to find a working URL
    if (_consecutiveFailures >= _maxFailuresBeforeReprobe) {
      _consecutiveFailures = 0;
      debugPrint('[KeepAlive] Re-probing for a working server URL...');
      ApiService.probeAndSetBestUrl(
        timeout: const Duration(seconds: 5),
      ).then((url) {
        if (url != null) {
          debugPrint('[KeepAlive] Recovered with URL: $url');
        } else {
          debugPrint('[KeepAlive] No reachable server found');
        }
      }).catchError((_) {});
    }
  }
}
