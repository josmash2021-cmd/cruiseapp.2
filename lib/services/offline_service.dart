import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'api_service.dart';

/// Handles offline trip continuation for drivers.
/// If driver loses connection during a trip, queues updates and re-syncs when online.
class OfflineService extends ChangeNotifier {
  static final OfflineService _instance = OfflineService._internal();

  factory OfflineService() {
    return _instance;
  }

  OfflineService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

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

  /// Retry a single failed update later (re-queues it)
  void _requeueUpdate(Map<String, dynamic> update) {
    // Prepend so it gets retried first on next sync
    _queuedUpdates.insert(0, update);
    _saveQueuedUpdates();
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

  /// Sync all queued updates back to server.
  /// Processes each update individually so one failure doesn't drop the rest.
  Future<void> _syncQueuedUpdates() async {
    if (_queuedUpdates.isEmpty || _isSyncing) return;
    _isSyncing = true;
    notifyListeners();

    final toSync = List<Map<String, dynamic>>.from(_queuedUpdates);
    final failed = <Map<String, dynamic>>[];

    debugPrint('[Offline] Syncing ${toSync.length} queued updates...');

    for (final update in toSync) {
      final type = update['type'] as String?;
      final data = update['data'] as Map<String, dynamic>?;
      if (type == null || data == null) continue;

      try {
        switch (type) {
          case 'driver_location':
            final driverId = data['driver_id'] as int?;
            final lat = data['lat'] as double?;
            final lng = data['lng'] as double?;
            final isOnline = data['is_online'] as bool? ?? true;
            if (driverId != null && lat != null && lng != null) {
              await ApiService.updateDriverLocation(
                driverId: driverId,
                lat: lat,
                lng: lng,
                isOnline: isOnline,
              );
            }
            break;

          case 'trip_status':
            final tripId = data['trip_id'] as int?;
            final status = data['status'] as String?;
            if (tripId != null && status != null) {
              await ApiService.updateTripStatus(
                tripId: tripId,
                status: status,
              );
            }
            break;

          default:
            debugPrint('[Offline] Unknown update type: $type');
            break;
        }
      } catch (e) {
        debugPrint('[Offline] Failed to sync update ($type): $e');
        // Re-queue for next sync attempt (max 3 retries)
        final attempts = (update['attempts'] as int? ?? 0) + 1;
        if (attempts < 3) {
          failed.add({...update, 'attempts': attempts});
        } else {
          debugPrint('[Offline] Dropping update after 3 failed attempts: $type');
        }
      }
    }

    _queuedUpdates = failed;
    await _saveQueuedUpdates();
    _isSyncing = false;
    notifyListeners();

    debugPrint('[Offline] Sync complete. ${failed.length} updates re-queued.');
  }

  /// Dispose resources
  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    super.dispose();
  }
}
