import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the "GO Online" gate on the driver person page (owner spec:
/// dispatch can pause a driver's GO — he goes offline instantly and his app
/// learns by socket — and hand it back later).
///
/// Backend contract (implemented separately):
///   POST /admin/users/{user_id}/go-online-gate  (dispatch auth)
///     body {"disabled": true|false} -> {"ok": true, "disabled": bool}
///   GET  /admin/users/{id} exposes `go_online_disabled` in the user dict.
///
/// The panel is a compiled bundle whose React source lives outside this
/// repo — the guard-pin comments are what the next rebuild must re-apply.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunks = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
      .toList();
  final personPage = chunks.firstWhere((s) => s.contains('replaceDocPhoto'),
      orElse: () => '');
  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync().replaceAll('\r\n', '\n'))
      .firstWhere((s) => s.contains('setGoOnlineGate'), orElse: () => '');

  test('the users module exposes the signed go-online-gate mutation', () {
    expect(usersModule, isNotEmpty,
        reason: 'setGoOnlineGate must live in the users module (signed POST '
            'helper, same as every /admin mutation)');
    expect(usersModule, contains('guard-pin panel_go_online_gate_guard_test'));
    expect(usersModule, contains('/go-online-gate'));
    expect(usersModule, contains('{disabled:t}'),
        reason: 'the body is {"disabled": bool} per the backend contract');
    expect(RegExp(r'export\{[^}]*setGoOnlineGate[^}]*\}').hasMatch(usersModule),
        isTrue,
        reason: 'exported for the person page chunk');
  });

  test('the account card reads go_online_disabled and shows the state', () {
    expect(personPage, isNotEmpty,
        reason: 'person page chunk not found — resolve it via index.html');
    expect(personPage,
        contains('guard-pin panel_go_online_gate_guard_test'));
    expect(personPage, contains('go_online_disabled'),
        reason: 'the current state comes from the person user dict');
    expect(personPage, contains('children:"GO Online"'));
    expect(personPage, contains('children:"GO pausado"'),
        reason: 'the chip makes a paused GO visible at a glance');
    expect(personPage, contains('"Activar GO Online"'));
    expect(personPage, contains('"Desactivar GO Online"'));
  });

  test('only disabling asks for confirmation; both paths reload the ficha',
      () {
    expect(personPage,
        contains('if(next&&!window.confirm("¿Desactivar el GO Online'),
        reason: 'the confirm gate runs ONLY when the next state is disabled '
            '(next === true) — activating goes straight through');
    expect(personPage, contains('Quedará offline al instante'));
    expect(personPage, contains('no podrá conectarse hasta que lo reactives'));
    expect(personPage, contains('await goGateSet(t,next),await load()'),
        reason: 'same reload-the-ficha mechanism as the neighboring account '
            'actions');
    expect(personPage, contains('No se pudo actualizar el GO Online'),
        reason: 'failures surface with the retry toast (Pe), never silently');
  });
}
