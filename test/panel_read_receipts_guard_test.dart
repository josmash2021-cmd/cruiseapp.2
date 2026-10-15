import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the panel read receipts (user spec 2026-10-15: "quiero saber
/// cuando el driver o rider lean el mensaje con 2 palomitas que se colocan
/// en azul"). The soporte chat bubble must render CheckCheck on outgoing
/// (dispatch/bot) messages, blue when the mirror's isRead is true. The panel
/// is a compiled bundle whose React source lives outside this repo — the
/// guard-pin comment is what the next rebuild must re-apply.
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere(
          (s) => s.contains('guard-pin panel_read_receipts_guard_test'),
          orElse: () => '');

  test('the support chat chunk carries the receipts and its pin', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('aS as CheckCheck'),
        reason: 'the lucide CheckCheck icon is imported for the ✓✓');
    expect(chunk, contains('(c||u)&&e.jsx(CheckCheck'),
        reason: 'outgoing (dispatch + bot) bubbles carry the ✓✓');
    expect(chunk, contains('style:s.isRead?{color:"#38BDF8"}:void 0'),
        reason: 'blue only when the app user actually read the message');
  });
}
