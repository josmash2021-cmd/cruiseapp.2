import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-10-30: drivers registering could not send the insurer's PDF — every
/// document picker was photo-only and the signup endpoint dropped PDFs.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('one shared PDF picker, capped at the server limit (10 MB)', () {
    final pick = read('lib/utils/pdf_pick.dart');
    expect(pick, contains("allowedExtensions: const ['pdf']"));
    expect(pick, contains('const int kMaxPdfBytes = 10 * 1024 * 1024;'));
    expect(pick, contains('throw const PdfTooLargeException();'));
  });

  test('signup: insurance and registration offer Upload PDF', () {
    final src = read('lib/screens/driver/driver_signup_screen.dart');
    final sheet = src.substring(src.indexOf('void _showPickOptions('),
        src.indexOf('Widget _sheetOption('));
    expect(sheet, contains('label: S.of(context).uploadPdf,'));
    expect(sheet, contains('await pickPdfDocument()'));
    expect(src, contains('isPdfPath(filePath)'),
        reason: 'the tile shows a PDF icon, not a broken image');
  });

  test('onboarding document screen offers Upload PDF and previews it', () {
    final src = read('lib/screens/driver/onboarding/doc_capture_screen.dart');
    expect(src, contains('s.uploadPdf,'));
    expect(src, contains('_pickPdf();'));
    expect(src, contains('if (_photoPath != null && isPdfPath(_photoPath))'));
  });

  test('documents screen offers Upload PDF for the car papers', () {
    final src = read('lib/screens/driver/driver_documents_screen.dart');
    expect(src, contains('S.of(ctx).uploadPdf,'));
    expect(src, contains("const {'insurance', 'registration', 'vehicle_inspection'}"));
  });

  test('strings exist in both languages', () {
    final l = read('lib/l10n/app_localizations.dart');
    expect(l, contains("String get uploadPdf => _es ? 'Subir PDF' : 'Upload PDF';"));
    expect(l, contains('String get pdfTooLarge'));
    expect(l, contains('String get pdfReady'));
  });
}
