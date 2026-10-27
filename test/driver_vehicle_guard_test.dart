import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for vehicle lifecycle UI: card state, selection, and archived cars.
void main() {
  test('the vehicle card reads the backend per-car document state', () {
    final screen = File('lib/screens/driver/driver_vehicle_screen.dart')
        .readAsStringSync();
    expect(screen, contains("vehicle['missing_vehicle_docs']"));
    expect(screen, contains("vehicle['documents_approved']"));
    expect(screen, contains('missingDocsCount: missingDocs'));
    expect(screen, contains('documentsApproved: documentsApproved'));
    expect(screen.contains("vehicle['insurance_valid']"), isFalse,
        reason: 'the card must not trust stale vehicle validity flags');
    expect(screen.contains("vehicle['registration_valid']"), isFalse);
  });

  test('Use this vehicle requires approval and approved current documents', () {
    final detail = File('lib/screens/driver/driver_vehicle_detail_screen.dart')
        .readAsStringSync();
    expect(detail, contains('final bool documentsApproved;'));
    expect(detail, contains('documentsApproved &&'));
    expect(detail, contains("approvalStatus == 'approved'"));
    expect(detail, contains('vehicleId != null'));
  });

  test('the backend archives vehicles and keeps their documents', () {
    final drivers = File('backend/routers/drivers.py').readAsStringSync();
    expect(drivers, contains('vehicle.archived_at ='));
    expect(drivers, contains('vehicle.is_active = False'));
    expect(drivers, contains('expire_pending_offers_for_driver'));
    expect(drivers.contains('await db.delete(vehicle)'), isFalse,
        reason: 'archiving must never hard-delete rows tied to documents');
  });

  test('documents and plate stay scoped to the selected vehicle', () {
    final docs = File('lib/screens/driver/driver_documents_screen.dart')
        .readAsStringSync();
    final plate = File('lib/screens/driver/driver_license_plate_screen.dart')
        .readAsStringSync();
    final api = File('lib/services/api_service.dart').readAsStringSync();
    final mirror =
        File('lib/services/firebase_storage_service.dart').readAsStringSync();
    expect(docs, contains('vehicleId: _selectedVehicleId'));
    expect(docs, contains('isActiveVehicle: vehicle'));
    expect(plate, contains('vehicleId: widget.vehicleId'));
    expect(api, contains("if (vehicleId != null) 'vehicle_id': vehicleId"));
    expect(mirror, contains("'vehicleDocumentUrls': {"));
    expect(mirror, contains("'\$vehicleId': {fieldName: photoUrl}"));
  });

  test('View Documents refreshes on dispatch decisions and cancels watchers',
      () {
    final docs = File('lib/screens/driver/driver_documents_screen.dart')
        .readAsStringSync();
    expect(docs, contains('SocketService.onboardingItemStream.listen'));
    expect(docs, contains('const Duration(seconds: 25)'));
    expect(docs, contains('await _fetchVehicles();'));
    expect(docs, contains('_reviewSub?.cancel();'));
    expect(docs, contains('_reviewPoll?.cancel();'));
    expect(docs, contains("vehicle['approval_status']"));
    expect(docs, contains('existing.isNotEmpty'));
  });
}
