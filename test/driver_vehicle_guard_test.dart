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

  test('Use this vehicle requires approval and approved current documents',
      () {
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
}
