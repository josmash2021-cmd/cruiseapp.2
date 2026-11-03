import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: when dispatch reassigns the trip or puts it back on
/// the board, "esto no debe de aparecer… ya no le saldrá ese viaje pero no
/// le avisa, solo desaparece y suena el sonido de cancelado".
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('no "Viaje reasignado" notice — the cancel sound instead', () {
    final c = read('lib/screens/driver/driver_online_controller.dart');
    final body = c.substring(c.indexOf('void _showCancelledNotice('));
    final head = body.substring(0, 800);
    expect(head, contains('if (reassigned) {'));
    expect(head, contains('unawaited(QueuedCancelCue.play());'));
    expect(head.indexOf('return;'),
        lessThan(head.indexOf('_cancelledNoticeTimer?.cancel();')),
        reason: 'it leaves before the notice is built');
  });

  test('a reassign push never shows a banner', () {
    final m = read('lib/main.dart');
    expect(m, contains("if (type == 'trip_reassigned') return;"));
  });

  test('the server tells the rider, never the driver who lost it', () {
    final d = read('backend/routers/dispatch.py');
    final reassign = d.substring(d.indexOf('async def admin_reassign_trip('));
    final end = reassign.indexOf('\n@router.');
    final fn = end > 0 ? reassign.substring(0, end) : reassign;
    expect(fn, isNot(contains('"type": "trip_reassigned"')));
    expect(fn, isNot(contains('notif_type="trip_reassigned"')));
    expect(fn, contains('"type": "ride_reassigned"'),
        reason: 'the rider still hears a new driver is coming');
  });
}
