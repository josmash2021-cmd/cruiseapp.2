import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch panel modal focus bug (user report 2026-10-14:
/// "cuando me pide que ingrese la clave en el dispatch… escribo una letra y
/// tengo que volver a darle click a la barra para cada letra"). The Modal's
/// open-effect re-ran on every keystroke (the parent passes a fresh onClose
/// closure per render, and the effect deps were [open, onClose]) and
/// re-focused the FIRST focusable element — the X close button, which sits
/// before the input in DOM order — stealing focus from the password field on
/// every letter. The fix: only auto-focus when focus is not already inside
/// the dialog.
///
/// The panel is a built React bundle (source outside this repo); the guard
/// scans the Modal chunk by its export signature, not the hash.
void main() {
  final modal = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('Modal-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('role:"dialog"'), orElse: () => '');

  test('the Modal chunk exists in the built panel', () {
    expect(modal, isNotEmpty,
        reason: 'no Modal-*.js chunk with role:dialog found — the panel was '
            'rebuilt and this guard needs its needle refreshed');
  });

  test('auto-focus never steals focus from inside the dialog', () {
    expect(modal, contains('t.contains(document.activeElement)'),
        reason: 'the open-effect must skip the autofocus when focus is '
            'already inside the modal (a re-render while typing)');
    expect(modal, contains('guard-pin panel_modal_focus_guard_test'),
        reason: 'the bundle edit carries its guard-pin so the next rebuild '
            'of the out-of-repo React source re-applies it');
  });
}
