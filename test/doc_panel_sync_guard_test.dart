import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the missing-documents panel bug (user report 2026-10: "hay
/// drivers que se están registrando que solo están llegando las fotos de la
/// licencia y perfil").
///
/// License/profile reach the review panel because /auth/verify-request syncs
/// them server-side into the Firestore `verifications` doc the panel reads.
/// Insurance/registration/inspection go through /drivers/documents*, which
/// never synced that doc — the only Firestore write was a best-effort
/// client-side mirror that also wrote `registrationUrl` while the panel
/// reads `registrationPhotoUrl`.
///
/// The fix has three legs, all pinned here:
///   1. Backend merges each uploaded doc URL into the verifications doc
///      (sync_verification_doc_url) from BOTH /drivers/documents endpoints.
///   2. The client mirror uses the panel's exact field names.
///   3. /admin/sync-verifications backfills registration from
///      vehicle_registration_url (the column onboarding writes) and carries
///      inspection.
void main() {
  String norm(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  final client = norm('lib/services/firebase_storage_service.dart');
  final driversPy = norm('backend/routers/drivers.py');
  final syncPy = norm('backend/firestore_sync.py');
  final dispatchPy = norm('backend/routers/dispatch.py');

  test('client mirror writes the field names the panel reads', () {
    expect(client.contains("case 'registration':"), isTrue);
    expect(client.contains("return 'registrationPhotoUrl';"), isTrue,
        reason: 'the panel reads registrationPhotoUrl — the default '
            "'\${docType}Url' shape wrote registrationUrl, a field nobody displays");
    expect(client.contains("return 'vehicleInspectionUrl';"), isTrue,
        reason: 'vehicle_inspection must not fall to the default either');
  });

  test('server maps doc types to the exact panel fields', () {
    expect(syncPy.contains('def sync_verification_doc_url('), isTrue);
    final start = syncPy.indexOf('_VERIFICATION_DOC_URL_FIELDS = {');
    expect(start, greaterThanOrEqualTo(0));
    final body = syncPy.substring(start, start + 400);
    expect(body.contains('"insurance": "insuranceUrl"'), isTrue);
    expect(body.contains('"registration": "registrationPhotoUrl"'), isTrue);
    expect(body.contains('"vehicle_inspection": "vehicleInspectionUrl"'), isTrue);
  });

  test('both /drivers/documents endpoints sync the panel after storing', () {
    final calls = 'sync_verification_doc_url('.allMatches(driversPy).length;
    expect(calls, greaterThanOrEqualTo(2),
        reason: 'one call in _store_driver_document (multipart + support '
            'chat filing) and one in the JSON endpoint — a single call '
            'leaves a path that stores the doc but hides it from the panel');
  });

  test('admin re-sync backfills registration and inspection', () {
    final start = dispatchPy.indexOf('def sync_verifications_to_firestore');
    expect(start, greaterThanOrEqualTo(0));
    final body = dispatchPy.substring(start, start + 1800);
    expect(body.contains('vehicle_registration_url'), isTrue,
        reason: 'onboarding registration lands in vehicle_registration_url — '
            'without the fallback the backfill cannot rescue those drivers');
    expect(body.contains('inspection_url'), isTrue);
    expect(syncPy.contains('data["vehicleInspectionUrl"] = inspection_url'),
        isTrue);
  });

  test('identity docs get reviewable rows on the admin detail read', () {
    // 2026-10-14 user spec: "poder aprobar todos los documentos por separado,
    // así como está seguro, registración y licencia" — profile photo, ID and
    // biometric selfie lived as plain user fields with no Document row, so
    // the panel's per-doc buttons never rendered for them. The admin detail
    // read backfills the pending rows; the review endpoint + push copy do
    // the rest.
    final adminPy = norm('backend/routers/admin.py');
    expect(adminPy, contains('_ensure_identity_doc_rows'),
        reason: 'the read-time backfill is wired into admin_get_user');
    expect(adminPy, contains('("profile_photo", "photo_url")'));
    expect(adminPy, contains('("id_document", "id_photo_url")'));
    expect(adminPy, contains('("selfie", "selfie_url")'));
    final approvalPy = norm('backend/services/driver_approval.py');
    for (final kind in ['"profile_photo"', '"id_document"', '"selfie"']) {
      expect(approvalPy, contains('$kind: {'),
          reason: 'ES/EN push copy exists for $kind');
    }
  });
}
