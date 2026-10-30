import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Insurance and registration often come as the insurer's PDF (2026-10-30:
/// drivers could only send photos). The server keeps PDFs up to 10 MB.
const int kMaxPdfBytes = 10 * 1024 * 1024;

/// The web build gets bytes, never a file path, so the option is hidden there.
bool get pdfPickSupported => !kIsWeb;

bool isPdfPath(String? path) =>
    path != null && path.toLowerCase().endsWith('.pdf');

/// Opens the system file picker on PDFs. Returns the path, or null when the
/// driver cancels. Throws [PdfTooLargeException] over [kMaxPdfBytes].
Future<String?> pickPdfDocument() async {
  if (!pdfPickSupported) return null;
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  final path = picked?.files.single.path;
  if (path == null) return null;
  if (await File(path).length() > kMaxPdfBytes) {
    throw const PdfTooLargeException();
  }
  return path;
}

class PdfTooLargeException implements Exception {
  const PdfTooLargeException();
}
