import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch-assisted document photo upload (user spec
/// 2026-10-17: "en dispatch necesito poder actualizar la foto de los
/// documentos por si el usuario necesita ayuda para subirlos yo mismo lo
/// puedo actualizar").
///
/// Backend: POST /admin/users/{id}/documents (multipart, dispatch auth)
/// runs the SAME pipeline as the driver's own upload — validation,
/// Firebase Storage, upsert pending (never a duplicate), panel mirror.
///
/// Panel (manual bundle edits — source outside this repo, guard-pins tell
/// a rebuild to re-apply them): the entry ships `adminUploadDocPhoto`
/// (signed headers minus Content-Type so FormData sets its own boundary)
/// and the person page gets an "Actualizar" button on every document card
/// (never on the account/vehicle/background cards).
void main() {
  final adminPy = File('backend/routers/admin.py').readAsStringSync();
  final html = File('backend/dispatch_panel/index.html')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
  final entry = match == null
      ? ''
      : File('backend/dispatch_panel/assets/${match.group(1)}')
          .readAsStringSync();
  final personPage = File('backend/dispatch_panel/assets/index-azyIyM-i.js')
      .readAsStringSync();

  test('backend endpoint exists with the shared pipeline + dispatch auth', () {
    expect(
        adminPy,
        contains(
            '@router.post("/admin/users/{user_id}/documents", dependencies=[Depends(_require_dispatch_auth)])'),
        reason: 'dispatch-only, like every other admin mutation');
    expect(adminPy, contains('_store_driver_document('),
        reason: 'same validation/storage/upsert/mirror pipeline as the '
            'driver upload — never a parallel one');
    expect(adminPy, contains('_ADMIN_UPLOAD_DOC_TYPES'),
        reason: 'doc_type is whitelisted');
    expect(adminPy, contains('ADMIN_DOCUMENT_UPLOAD'),
        reason: 'operator uploads are audit-logged');
  });

  test('the entry ships the signed multipart upload helper', () {
    expect(entry, contains('panel_admin_doc_upload_guard_test'),
        reason: 'the guard-pin must survive — a rebuild re-applies the edit');
    expect(entry, contains('async function adminUploadDocPhoto('));
    expect(entry, contains('delete h["Content-Type"]'),
        reason: 'FormData sets its own boundary — the signed JSON content '
            'type would corrupt the multipart body');
    expect(entry, contains('adminUploadDocPhoto as panelUploadDocPhoto'),
        reason: 'exported for the person page chunk');
    expect(entry, contains('fd.append("vehicle_id",String(vehicleId))'),
        reason: 'a vehicle document upload must name its own car');
  });

  test('every document card carries the Actualizar button', () {
    expect(personPage, contains('panel_admin_doc_upload_guard_test'));
    expect(personPage, contains('const replaceDocPhoto='),
        reason: 'the file-picker + upload + reload helper');
    expect(personPage, contains('canUploadDoc(kind)'),
        reason: 'account/vehicle/background cards never get the button');
    expect(personPage, contains('children:"Actualizar"'));
    expect(personPage, contains('replaceDocPhoto(kind,vehicleId)'));
    expect(personPage, contains('reviewBtns("document",d.id,d.vehicleId)'),
        reason: 'the id travels from the selected vehicle card to the upload');
  });
}
