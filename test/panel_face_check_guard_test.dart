import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver face-check (selfie 24h) review in the dispatch
/// panel (user spec 2026-10-23: la selfie diaria del driver se revisa a mano
/// en dispatch; rechazar lo desconecta y le avisa de la norma de vestimenta).
///
/// Backend contract (backend/routers/admin.py, face-checks section):
///   GET  /admin/face-checks/pending          -> {face_checks: [{id, user_id,
///                                               driver_name, photo_url
///                                               (avatar), file_path (selfie),
///                                               created_at}]}
///   POST /admin/face-checks/{doc_id}/approve -> driver can go online
///   POST /admin/face-checks/{doc_id}/reject  -> driver disconnected + push
///     (deferred while a rider is aboard)
///
/// The panel is a compiled bundle whose React source lives outside this
/// repo — the guard-pin comments are what the next rebuild must re-apply.
void main() {
  final adminPy = File('backend/routers/admin.py')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final assets = Directory('backend/dispatch_panel/assets');
  final chunks = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
      .toList();
  final personPage =
      chunks.firstWhere((s) => s.contains('replaceDocPhoto'), orElse: () => '');
  final verifPage = chunks.firstWhere(
      (s) => s.contains('Selfies de conductor pendientes'),
      orElse: () => '');
  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
      .firstWhere((s) => s.contains('approveFaceCheck'), orElse: () => '');

  test('the users module exposes the face-check verdict endpoints', () {
    expect(usersModule, isNotEmpty,
        reason: 'approveFaceCheck/rejectFaceCheck must live in the users '
            'module (signed POST helper, same as every /admin mutation)');
    expect(usersModule, contains('guard-pin panel_face_check_guard_test'));
    expect(usersModule, contains('/admin/face-checks/'));
    expect(usersModule, contains('/approve'));
    expect(usersModule, contains('/reject'));
    expect(usersModule, contains('approveFaceCheck,rejectFaceCheck'),
        reason: 'both helpers are exported for the person page chunk');
  });

  test(
      'the selfie_check document card carries Aprobar / Rechazar y desconectar',
      () {
    expect(personPage, isNotEmpty,
        reason: 'person page chunk not found — resolve it via index.html');
    expect(personPage, contains('guard-pin panel_face_check_guard_test'));
    expect(personPage, contains('"selfie_check"'),
        reason: 'the gate is the doc_type — only selfie_check cards get the '
            'face-check buttons');
    expect(
        personPage,
        contains(
            'isSelfie?selfieBtns(d.id):reviewBtns("document",d.id,d.vehicleId)'),
        reason: 'selfie_check cards replace the generic approve/reject row; '
            'account/vehicle/background cards never reach docCard');
    expect(personPage, contains('children:"Aprobar"'));
    expect(personPage, contains('children:"Rechazar y desconectar"'));
    expect(personPage,
        contains('window.confirm("¿Rechazar y desconectar al driver?'),
        reason: 'the reject path confirms before disconnecting the driver');
    expect(personPage, contains('no cumple las normas de vestimenta'));
    expect(personPage, contains('approveFC'), reason: 'POST …/approve');
    expect(personPage, contains('rejectFC'), reason: 'POST …/reject');
  });

  test('the backend exposes the three dispatch-gated face-check endpoints', () {
    expect(
        adminPy,
        contains(
            '@router.get("/admin/face-checks/pending", dependencies=[Depends(_require_dispatch_auth)])'));
    expect(adminPy,
        contains('@router.post("/admin/face-checks/{document_id}/approve"'));
    expect(adminPy,
        contains('@router.post("/admin/face-checks/{document_id}/reject"'));
    expect(adminPy, contains('"face_checks": out'),
        reason: 'the pending list key the panel reads');
  });

  test('the Verificación page opens with the pending-selfies section', () {
    expect(verifPage, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(verifPage, contains('guard-pin panel_face_check_guard_test'));
    expect(verifPage, contains('/admin/face-checks/pending'),
        reason: 'the section lists GET /admin/face-checks/pending');
    expect(verifPage, contains('Array.isArray(d.face_checks)'),
        reason: 'the backend returns {face_checks: [...]} — never "items"');
    expect(verifPage, contains('fc.driver_name'));
    expect(verifPage, contains('fc.file_path'),
        reason: 'file_path is the selfie; photo_url is the avatar');
    expect(verifPage, contains('FaceCheckQueue'));
    expect(verifPage, contains('/personas/driver/sql_'),
        reason: 'tap navigates to the driver person page — same route the '
            'KYC queue uses');
  });
}
