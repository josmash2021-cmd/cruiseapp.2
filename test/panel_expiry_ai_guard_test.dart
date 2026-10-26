import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the AI-expiry confirmation card on the person page
/// (2026-10-20, user-approved design "la IA sugiere, yo confirmo en
/// dispatch"). The panel is a compiled bundle whose React source lives
/// outside this repo — the guard-pin comment is what the next rebuild must
/// re-apply. Backend: the reader writes ONLY expiry_suggested_at; the
/// dispatch endpoints are the ONLY path into the official expiry_date.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunk = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_expiry_ai_guard_test'),
          orElse: () => '');
  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('confirmExpirySuggestion'),
          orElse: () => '');
  final adminPy = File('backend/routers/admin.py').readAsStringSync();
  final readerPy =
      File('backend/services/doc_expiry_reader.py').readAsStringSync();

  test('the backend reader only ever writes a suggestion', () {
    expect(readerPy, contains('expiry_suggested_at'));
    expect(readerPy, isNot(contains('doc.expiry_date =')),
        reason: 'the AI reader NEVER writes the official date — only '
            'dispatch confirmation does');
  });

  test('dispatch endpoints are the only path into the official date', () {
    expect(adminPy, contains('/admin/documents/expiry-suggestions'));
    expect(adminPy, contains('/expiry-suggestion/confirm'));
    expect(adminPy, contains('/expiry-suggestion/dismiss'));
    expect(adminPy, contains('_require_dispatch_auth'));
  });

  test('the person page carries the confirmation card', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('ExpirySugs'));
    expect(chunk, contains('Vencimientos (IA)'));
    expect(chunk, contains('expiry_suggested_at'));
    expect(chunk, contains('Confirmar todas'));
    expect(chunk, contains('window.prompt'),
        reason: 'the Edit action asks for the corrected date');
  });

  test('the users module exposes the three actions', () {
    expect(usersModule, contains('/expiry-suggestion/confirm'));
    expect(usersModule, contains('/expiry-suggestion/dismiss'));
    expect(usersModule, contains('expiry-suggestions/confirm-all'));
    expect(usersModule, contains('guard-pin panel_expiry_ai_guard_test'));
  });
}
