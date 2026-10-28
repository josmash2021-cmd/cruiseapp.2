import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the missing-documents panel bug and orphan-free uploads.
///
/// License/profile reach the review panel because /auth/verify-request syncs
/// them server-side into the Firestore `verifications` doc the panel reads.
/// Insurance/registration/inspection go through /drivers/documents*. Both app
/// flows send the photo directly to the backend, which validates the vehicle
/// before storing anything and owns the panel sync. A rejected upload therefore
/// cannot leave a client-created Storage object behind.
///
/// The repair has three legs, all pinned here:
///   1. Both Flutter flows call ApiService.uploadDocument with their vehicle id
///      and never upload or mirror documents through FirebaseStorageService.
///   2. Backend merges each uploaded doc URL into the verifications doc
///      (sync_verification_doc_url) from BOTH /drivers/documents endpoints.
///   3. /admin/sync-verifications backfills registration from
///      vehicle_registration_url (the column onboarding writes) and carries
///      inspection.
void main() {
  String norm(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  String section(String source, String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
    final end = source.indexOf(endMarker, start + startMarker.length);
    expect(end, greaterThan(start), reason: 'missing $endMarker');
    return source.substring(start, end);
  }

  final capture = norm('lib/screens/driver/onboarding/doc_capture_screen.dart');
  final documents = norm('lib/screens/driver/driver_documents_screen.dart');
  final driversPy = norm('backend/routers/drivers.py');
  final syncPy = norm('backend/firestore_sync.py');
  final dispatchPy = norm('backend/routers/dispatch.py');
  const forbiddenClientWrites = [
    'FirebaseStorageService.uploadDocumentPhoto',
    'FirebaseStorageService.saveVerificationPhoto',
    'ApiService.getMe',
  ];

  test('onboarding capture uploads through the backend with its vehicle id',
      () {
    final body = section(
      capture,
      'Future<void> _save() async {',
      '  @override\n  Widget build(BuildContext context) {',
    );
    expect(body, contains('ApiService.uploadDocument('));
    expect(body, contains('filePath: path'));
    expect(body, contains('vehicleId: widget.vehicleId'));
    expect(body, contains('ApiService.submitOnboardingDoc('));
    for (final forbidden in forbiddenClientWrites) {
      expect(body, isNot(contains(forbidden)),
          reason: 'the server must be the first and only storage writer');
    }
  });

  test('documents upload uses base64 backend flow with its selected vehicle',
      () {
    final body = section(
      documents,
      'Future<void> _uploadFile(String path, String docType) async {',
      '  Widget _uploadOption(',
    );
    expect(body, contains('ApiService.uploadDocument('));
    expect(body, contains('photoBase64: base64Photo'));
    expect(body, contains('vehicleId: _selectedVehicleId'));
    for (final forbidden in forbiddenClientWrites) {
      expect(body, isNot(contains(forbidden)),
          reason: 'the server must be the first and only storage writer');
    }
  });

  test('server maps doc types to the exact panel fields', () {
    expect(syncPy.contains('def sync_verification_doc_url('), isTrue);
    final start = syncPy.indexOf('_VERIFICATION_DOC_URL_FIELDS = {');
    expect(start, greaterThanOrEqualTo(0));
    final body = syncPy.substring(start, start + 400);
    expect(body.contains('"insurance": "insuranceUrl"'), isTrue);
    expect(body.contains('"registration": "registrationPhotoUrl"'), isTrue);
    expect(
        body.contains('"vehicle_inspection": "vehicleInspectionUrl"'), isTrue);
  });

  test('both /drivers/documents endpoints sync the panel after storing', () {
    final jsonEndpoint = section(
      driversPy,
      'async def upload_document(',
      'async def _store_driver_document(',
    );
    final sharedStore = section(
      driversPy,
      'async def _store_driver_document(',
      '@router.post("/drivers/documents/upload"',
    );
    final multipartEndpoint = section(
      driversPy,
      'async def upload_document_multipart(',
      '@router.post("/drivers/{driver_id}/background-check"',
    );
    expect(jsonEndpoint, contains('sync_verification_doc_url('),
        reason: 'the JSON endpoint must sync its own stored document');
    expect(sharedStore, contains('sync_verification_doc_url('),
        reason: 'the shared store also covers support chat document filing');
    expect(multipartEndpoint, contains('_store_driver_document('),
        reason: 'multipart reaches the panel through the syncing shared store');
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

  test('driver documents are approved MANUALLY, never by the agent', () {
    // 2026-10-14 user decision: "los documentos para los drivers no se
    // aprueban solo — por el momento eso será manual". The
    // DocumentApprovalAgent's Phase 1 (insurance/registration auto-approval
    // every 5 min) is OFF; every decision is a human one in the panel.
    final agent = norm('backend/document_approval_agent.py');
    expect(agent, contains('MANUAL_REVIEW_ONLY = True'),
        reason: 'the kill switch is ON');
    expect(agent, contains('if not MANUAL_REVIEW_ONLY:'),
        reason: 'the Phase 1 scan is gated by it');
    expect(agent, contains('"manual_review_only": MANUAL_REVIEW_ONLY'),
        reason: 'the agent status reports it');
  });
}
