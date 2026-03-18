import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Service for drivers to submit bug reports, crashes, and other issues.
class DriverReportService {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference get _reports => _db.collection('driver_reports');

  /// Submit a new report from a driver.
  static Future<String> submitReport({
    required String driverId,
    required String driverName,
    required String type, // 'app_crash', 'bug', 'feature_request', 'complaint', 'other'
    required String message,
    String? tripId,
  }) async {
    // Get device info
    String deviceInfo = 'Unknown device';
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        deviceInfo = 'iPhone ${iosInfo.model} / iOS ${iosInfo.systemVersion}';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        deviceInfo = '${androidInfo.manufacturer} ${androidInfo.model} / Android ${androidInfo.version.release}';
      }
    } catch (e) {
      debugPrint('[DriverReport] Could not get device info: $e');
    }

    final docRef = await _reports.add({
      'driverId': driverId,
      'driverName': driverName,
      'type': type,
      'message': message,
      'tripId': tripId,
      'deviceInfo': deviceInfo,
      'status': 'pending',
      'createdAt': Timestamp.now(),
      'resolvedAt': null,
    });

    debugPrint('✅ Driver report submitted: ${docRef.id}');
    return docRef.id;
  }

  /// Get all reports for a specific driver.
  static Stream<List<Map<String, dynamic>>> watchDriverReports(String driverId) {
    return _reports
        .where('driverId', isEqualTo: driverId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return data;
      }).toList();
    });
  }
}
