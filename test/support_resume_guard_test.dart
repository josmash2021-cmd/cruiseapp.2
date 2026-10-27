import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the support-chat resume rule (2026-10-27 owner spec):
/// EVERY support-chat entry point must open the driver's PENDING chat with
/// its transcript, never a fresh per-trip one. The old sessionKey forced a
/// brand-new empty chat when opening support from another trip — that read
/// as "the chat got deleted on reopen".
void main() {
  final src = File('lib/screens/help_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('support always resumes the open chat (fresh: false)', () {
    expect(src, contains('fresh = false;'));
    expect(src, isNot(contains('fresh = await _consumeFreshSessionFlag()')),
        reason: 'no per-trip fresh conversation may be forced');
  });

  test('the per-trip fresh flag machinery is gone', () {
    expect(src, isNot(contains('_consumeFreshSessionFlag')));
    expect(src, isNot(contains('_prefsSessionKey')));
  });

  test('the new conversation only happens without an open chat / after idle', () {
    expect(src, contains('no open one, or after 6h idle'));
  });
}
