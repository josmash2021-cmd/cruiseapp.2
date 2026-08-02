import '../utils/app_platform.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
    // Simple device info without external dependencies
    String deviceInfo = 'Unknown';
    try {
      if (AppPlatform.isIOS) {
        deviceInfo = 'iOS Device';
      } else if (AppPlatform.isAndroid) {
        deviceInfo = 'Android Device';
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
        // Without this a permission-denied throws into the zone and lands
        // in Crashlytics instead of the log. The stream survives, so it
        // recovers on its own once the Firebase session exists.
        .handleError((Object e, StackTrace _) {
          debugPrint('[DriverReports] snapshot rejected: $e');
        })
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        data['id'] = doc.id;
        return data;
      }).toList();
    });
  }
}
