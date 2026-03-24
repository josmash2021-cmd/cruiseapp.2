import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Singleton that monitors network connectivity and exposes a [ValueNotifier]
/// so any widget can react to online/offline changes without polling.
class NetworkService {
  static final NetworkService _instance = NetworkService._internal();
  factory NetworkService() => _instance;
  NetworkService._internal();

  final ValueNotifier<bool> onlineNotifier = ValueNotifier(true);
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _initialized = false;

  bool get isOnline => onlineNotifier.value;

  void init() {
    if (_initialized) return;
    _initialized = true;

    Connectivity().checkConnectivity().then((results) {
      onlineNotifier.value =
          results.any((r) => r != ConnectivityResult.none);
    });

    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online != onlineNotifier.value) {
        onlineNotifier.value = online;
        debugPrint(online ? '🟢 Network online' : '🔴 Network offline');
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _initialized = false;
  }
}
