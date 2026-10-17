import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'socket_service.dart';
import 'user_session.dart';

class AccountSessionGuard {
  static bool _initialized = false;
  static bool _terminated = false;
  static Timer? _timer;
  static StreamSubscription<Map<String, dynamic>>? _subscription;
  static const _terminalStatuses = {
    'blocked',
    'account_blocked',
    'deleted',
    'account_deleted',
    'deactivated',
    'account_deactivated',
    'pending_deletion',
    'inactive',
    'suspended',
  };

  static void init() {
    if (_initialized) return;
    _initialized = true;
    _terminated = false;
    _subscription = SocketService.accountStatusStream.listen((data) {
      handleStatus(data['status']?.toString());
    });
    _check();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _check());
  }

  static void reset() {
    _terminated = false;
    if (!_initialized) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _check());
    _check();
  }

  static Future<void> handleStatus(String? status) async {
    if (status == null) return;
    final normalized = status.toLowerCase();
    if (normalized == 'account_revoked' ||
        _terminalStatuses.contains(normalized)) {
      await _terminate();
    }
  }

  static Future<void> handleRevoked() => _terminate();

  static Future<void> check() => _check();

  static Future<void> _check() async {
    if (_terminated) return;
    try {
      final token = await ApiService.getToken();
      if (token == null) return;
      final status = await ApiService.getAccountStatus();
      if (status == 'unknown') return;
      await handleStatus(status);
    } catch (error) {
      debugPrint('[AccountSessionGuard] status check failed: $error');
    }
  }

  static Future<void> _terminate() async {
    if (_terminated) return;
    final hasSession = await UserSession.isLoggedInLocal();
    if (!hasSession) return;
    _terminated = true;
    _timer?.cancel();
    _timer = null;
    await UserSession.logout();
    ApiService.onAccountTerminated?.call();
  }

  static void dispose() {
    _timer?.cancel();
    _timer = null;
    _subscription?.cancel();
    _subscription = null;
    _initialized = false;
    _terminated = false;
  }
}
