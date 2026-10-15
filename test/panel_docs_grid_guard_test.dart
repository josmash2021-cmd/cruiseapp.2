import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the person-detail documents grid (user spec 2026-10-15:
/// "quiero que este en un grid y el boton de aprobar o rechazar este debajo
/// de cada imagen … tambien debe estar la opcion de aprobar o rechazar el
/// carro, el social, y las 8 cosas que subieron").
///
/// The "Fotos de verificación" visual-only grid and the "Documentos del
/// servidor" stacked list merged into ONE reviewable grid (that dual render
/// was what made the license show twice). Every card carries its
/// Aprobar/Rechazar under the image; the vehicle and the Social/Background
/// check are reviewable too. The panel is a compiled bundle whose React
/// source lives outside this repo — the guard-pin comment is what the next
/// rebuild must re-apply.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunks = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .toList();
  final chunk = chunks.firstWhere(
      (s) => s.contains('guard-pin panel_docs_grid_guard_test'),
      orElse: () => '');
  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('setBackgroundCheckStatus'),
          orElse: () => '');

  test('the documents grid chunk exists and carries its guard-pin', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
  });

  test('documents render as a grid with review buttons under the image', () {
    expect(chunk,
        contains('grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3'),
        reason: 'driver documents render as a grid, not a stacked list');
    expect(chunk, contains('const mediaCell='),
        reason: 'the image/video cell renders ABOVE the buttons');
    expect(
        chunk.indexOf('const mediaCell=') < chunk.indexOf('const reviewBtns='),
        isTrue,
        reason: 'media first, buttons below — declaración en ese orden');
    expect(chunk, contains('flex-1 border-success/40 text-success'),
        reason: 'full-width Aprobar button under each image');
    expect(chunk, contains('object-contain'),
        reason: 'photos render contained (the full document visible)');
  });

  test('the social/background check card is reviewable', () {
    expect(chunk, contains('Social / Background check'));
    expect(chunk, contains('await bgset(target.id'),
        reason: 'background decisions POST through the new helper');
    expect(chunk, contains('setBackgroundCheckStatus as bgset'),
        reason: 'the chunk imports the helper from the users module');
    expect(usersModule,
        contains('`/admin/users/\${e}/background-check-status`'),
        reason: 'the users module POSTs the admin background-check endpoint');
    expect(usersModule, contains('setBgStatus as setBackgroundCheckStatus'),
        reason: '…and exports it');
  });

  test('the vehicle is always reviewable and the dead duplicate grid is gone',
      () {
    expect(chunk.contains('d.approvalStatus!=="approved"'), isFalse,
        reason: 'the vehicle approve/reject buttons no longer disappear once '
            'approved — dispatch can reverse a decision');
    expect(chunk.contains('children:e.jsx(sa,{photos:j})'), isFalse,
        reason: 'the visual-only Fotos grid (the duplicate render) is dead');
    expect(
        chunk.contains('mt-1.5 h-[140px] w-full rounded-[10px] border '
            'border-cardBorder object-cover'),
        isFalse,
        reason: 'the cropped 140px strip render is dead — photos show whole');
  });
}
