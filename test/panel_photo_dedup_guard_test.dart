import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the person-detail verification photo grid dedup (user report
/// 2026-10-15: "dispatch sigue duplicando las fotos" — LICENCIA (FRENTE) from
/// the Firestore `verifications` doc and LICENCIA DE CONDUCIR from the SQL
/// `Document` row render the SAME license photo twice because the two URLs
/// differ in form, so the exact-URL dedup never fires). The grid now skips a
/// SQL doc whose category is already covered by a Firestore field; the SQL
/// document keeps showing in "Documentos del servidor" below (where the
/// approve/reject buttons live).
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_photo_dedup_guard_test'),
          orElse: () => '');

  test('the photo grid chunk exists and carries its guard-pin', () {
    expect(chunk, isNotEmpty,
        reason: 'the chunk building the verification photo rows (and its '
            'guard-pin) must exist — a rebuild of the out-of-repo React '
            'source must re-apply this edit');
  });

  test('SQL doc rows are skipped when Firestore already shows the category',
      () {
    expect(
        chunk,
        contains('w.includes("license")&&(d(t.licenseFrontUrl)||'
            'd(t.licenseBackUrl)||d(t.licenseUrl))'),
        reason: 'license family skipped when the grid already renders '
            'licenseFrontUrl/licenseBackUrl/licenseUrl');
    expect(chunk, contains('w==="insurance"&&d(t.insuranceUrl)'),
        reason: 'insurance skipped when insuranceUrl is already rendered');
    expect(
        chunk,
        contains('(w==="id_document"||w==="id_card"||w==="government_id")'
            '&&d(t.idPhotoUrl)'),
        reason: 'id document skipped when idPhotoUrl is already rendered');
    expect(chunk, contains('w==="selfie"&&d(t.selfieUrl)'),
        reason: 'selfie skipped when selfieUrl is already rendered');
  });

  test('the exact-URL dedup stays as the backstop', () {
    expect(chunk, contains('a.some(c=>c.url===p)||a.push({label:Se(u.docType)'),
        reason: 'the original same-URL dedup is still the last gate before '
            'pushing a SQL doc row into the grid');
  });
}
