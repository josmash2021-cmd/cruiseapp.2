import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the person-detail document photo display (user report
/// 2026-10-15: "las fotos quiero que se vea como fotos de verificación" —
/// the server-document photos rendered object-COVER: blown up and cropped
/// into strips. They must render CONTAINED — the full photo visible, like
/// the verification thumbnails).
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_photo_display_guard_test'),
          orElse: () => '');

  test('the document photo render chunk exists', () {
    expect(chunk, isNotEmpty,
        reason: 'the chunk carrying the doc photo render (and its guard-pin) '
            'must exist');
  });

  test('document photos render contained, never cropped', () {
    expect(
        chunk,
        contains('className:"h-full w-full object-contain '
            'transition-transform hover:scale-[1.02]"'),
        reason: 'object-contain — the full document photo is visible');
    expect(
        chunk.contains('className:"h-full w-full object-cover '
            'transition-transform hover:scale-[1.02]"'),
        isFalse,
        reason: 'object-cover (blown up + cropped) is dead on doc photos');
    expect(chunk, contains('guard-pin panel_photo_display_guard_test'),
        reason: 'the bundle edit carries its guard-pin so the next rebuild '
            'of the out-of-repo React source re-applies it');
  });
}
