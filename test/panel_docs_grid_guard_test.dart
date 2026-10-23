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
        reason: 'videos keep object-contain so the whole frame is visible');
  });

  test('photo cells are uniform and open a lightbox, never a new page', () {
    expect(chunk, contains('aspectRatio:"4/3"'),
        reason: 'every media cell (photo / video / broken) is the same 4:3 '
            'box — no stretched "very long" photos (2026-10-22 spec)');
    expect(chunk, contains('object-cover transition-transform'),
        reason: 'grid photos cover their cell (crop, never deform)');
    expect(chunk, contains('[zoom,setZoom]=m.useState(null)'),
        reason: 'the lightbox is a local state in the person-detail '
            'component (the open photo URL)');
    expect(chunk, contains('onClick:()=>setZoom(url)'),
        reason: 'tapping a photo opens the lightbox');
    expect(chunk, isNot(contains('window.open(url')),
        reason: 'the photo NEVER navigates away / opens another page');
    expect(chunk, contains('position:"fixed",inset:0'),
        reason: 'the lightbox is a full-screen overlay ON TOP of the page');
    expect(chunk, contains('rgba(0,0,0,0.85)'),
        reason: 'dark backdrop');
    expect(chunk, contains('objectFit:"contain"'),
        reason: 'the enlarged photo renders whole');
    expect(chunk, contains('onClick:()=>setZoom(null)'),
        reason: 'clicking the backdrop (or the ✕) closes the lightbox');
    expect(chunk, contains('children:"✕"'),
        reason: 'explicit close button');
  });

  test('the four account actions are a uniform grid of rectangular buttons',
      () {
    expect(chunk, contains('mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4'),
        reason: 'the actions grid spans the full card width (2×2 on narrow, '
            '4 columns on wide)');
    expect(chunk, contains('whitespace-nowrap rounded-lg border'),
        reason: 'rectangular one-line buttons — the round pills that split '
            '"Lista de espera" into 3 lines are gone');
    expect(chunk, isNot(contains('size:"sm",icon:me')),
        reason: 'the F pill component no longer renders the account actions');
    for (final a in ['"approve")', '"waitlist")', '"pending")']) {
      expect(chunk, contains('act({kind:"account",id:t},$a'),
          reason: 'account action $a keeps its endpoint');
    }
    expect(chunk, contains('setRejectTarget({kind:"account",id:t})'),
        reason: 'Rechazar still opens the reason modal');
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

  test('account approval is manual and pending reversal is available', () {
    expect(chunk, contains('guard-pin panel_manual_account_approval_guard_test'));
    expect(chunk, contains('Cuenta completa del driver'));
    expect(chunk, contains('target.kind==="account"?await accountSet'),
        reason: 'account decisions use their own endpoint, never a document one');
    expect(chunk, contains('kind:"account",id:t},"pending"'),
        reason: 'an accidental global approval can be returned to To-do');
    expect(chunk, contains('kind:"account",id:t},"waitlist"'),
        reason: 'the full driver profile keeps the Lista de espera action');
    expect(usersModule, contains('/auth/dispatch-approve/\${e}'));
    expect(usersModule, contains('/auth/dispatch-reject/\${e}'));
    expect(usersModule, contains('/auth/dispatch-waitlist/\${e}'));
    expect(usersModule, contains('/auth/dispatch-unwaitlist/\${e}'));
    expect(usersModule, contains('setDriverVerificationStatus'),
        reason: 'la decisión de cuenta sale por sus endpoints propios (approve/reject/waitlist/unwaitlist)');
  });

  test('per-card busy: no stray global busy reference survives', () {
    expect(chunk, contains('busyKey==='),
        reason: 'buttons disable per card (busyKey=kind:id)');
    expect(
        chunk.contains('disabled:busy,') || chunk.contains('disabled:busy}'),
        isFalse,
        reason: 'prod crash 2026-10-15 ("busy is not defined" en la ficha de '
            'persona): the account card buttons kept the dead global busy — '
            'never again');
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
