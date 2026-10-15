import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the panel tier label rename (2026-10-15, user spec: "la
/// categoría black se llamará ahora VIP para el cliente y para los
/// drivers"). The panel's tier→label helper must read VIP; the old
/// 'black' rows keep mapping to it. The panel is a compiled bundle whose
/// React source lives outside this repo — the guard-pin comment is what
/// the next rebuild must re-apply.
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_vip_label_guard_test'),
          orElse: () => '');

  test('the tier label chunk carries the rename and its pin', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk,
        contains('case"black":case"vip":case"luxury":return"VIP"'),
        reason: 'the top tier labels as VIP — old black rows included');
    expect(chunk.contains('return"Black"'), isFalse,
        reason: 'no reader may still label the top tier Black');
  });
}
