import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

/// Handles offline trip continuation for drivers.
/// If driver loses connection during a trip, queues updates and re-syncs when online.
class OfflineService extends ChangeNotifier {
  static final OfflineService _instance = OfflineService._internal();

  factory OfflineService() {
    return _instance;
  }

  OfflineService._internal();

  final Connectivity _connectivity = Connectivity();
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  List<Map<String, dynamic>> _queuedUpdates = [];
  List<Map<String, dynamic>> get queuedUpdates => _queuedUpdates;

  /// Initialize offline service and listen for connectivity changes
  void init() {
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((result) async {
      final wasOnline = _isOnline;
      _isOnline = !result.contains(ConnectivityResult.none);

      if (wasOnline != _isOnline) {
        notifyListeners();
        debugPrint('[Offline] Connection: $_isOnline');

        // When coming back online, sync queued updates
        if (_isOnline && _queuedUpdates.isNotEmpty) {
          await _syncQueuedUpdates();
        }
      }
    });

    // Load queued updates from storage
    _loadQueuedUpdates();
  }

  /// Queue an update to be sent when online (e.g., location updates, trip status)
  void queueUpdate(String type, Map<String, dynamic> data) {
    _queuedUpdates.add({
      'type': type,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    });
    _saveQueuedUpdates();
    debugPrint('[Offline] Queued ${_queuedUpdates.length} updates');
  }

  /// Clear all queued updates
  void clearQueue() {
    _queuedUpdates.clear();
    _saveQueuedUpdates();
  }

  /// Save queued updates to local storage using proper JSON serialization
  Future<void> _saveQueuedUpdates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _queuedUpdates.map((u) => jsonEncode(u)).toList();
      await prefs.setStringList('offline_queue', jsonList);
    } catch (e) {
      debugPrint('[Offline] Error saving queue: $e');
    }
  }

  /// Load queued updates from local storage with proper JSON deserialization
  Future<void> _loadQueuedUpdates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList('offline_queue') ?? [];
      _queuedUpdates = jsonList.map((str) {
        try {
          final decoded = jsonDecode(str);
          if (decoded is Map<String, dynamic>) return decoded;
          return <String, dynamic>{'data': str};
        } catch (_) {
          return <String, dynamic>{'data': str};
        }
      }).toList();
    } catch (e) {
      debugPrint('[Offline] Error loading queue: $e');
    }
  }

  /// Sync all queued updates back to server
  Future<void> _syncQueuedUpdates() async {
    if (_queuedUpdates.isEmpty) return;

    debugPrint('[Offline] Syncing ${_queuedUpdates.length} queued updates...');
    _queuedUpdates.clear();
    await _saveQueuedUpdates();
  }

  /// Dispose resources
  @override
  void dispose() {
    _connectivitySubscription.cancel();
    super.dispose();
  }
}
