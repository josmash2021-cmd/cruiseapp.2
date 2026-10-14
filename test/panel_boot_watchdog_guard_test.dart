import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch panel boot watchdog (user report 2026-10-14:
/// "a veces el dispatch no carga en teléfono y tengo que reiniciar la
/// página"). On a flaky mobile network a bundle chunk can fail before the
/// app mounts, leaving a blank page until a manual reload. index.html now
/// reloads ITSELF once when #root is still empty 9 s in.
void main() {
  final html = File('backend/dispatch_panel/index.html').readAsStringSync();

  test('the boot watchdog is wired in index.html', () {
    expect(html, contains("panel_boot_retried"),
        reason: 'the once-per-tab-session reload latch');
    expect(html, contains('root.hasChildNodes()'),
        reason: 'the watchdog checks that the app actually mounted');
    expect(html, contains('}, 9000);'),
        reason: 'the 9 s boot deadline');
    expect(html, contains('sessionStorage.removeItem(KEY)'),
        reason: 'a successful boot clears the latch for the next visit');
    // It must never loop: the latch is set BEFORE reloading.
    final setIdx = html.indexOf("sessionStorage.setItem(KEY, '1')");
    final reloadIdx = html.indexOf('location.reload()');
    expect(setIdx, greaterThanOrEqualTo(0));
    expect(reloadIdx, greaterThan(setIdx),
        reason: 'the latch is armed before location.reload() — the reloaded '
            'page sees it and never fires a second reload');
  });
}
