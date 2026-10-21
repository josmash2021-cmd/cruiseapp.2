import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the support-chat open speed (2026-10-20, user report:
/// "cuando las personas abren el chat con soporte por primera vez se tarda
/// unos 10 segundos en cargar"). Root causes pinned dead:
///  - every Firestore mirror call was a BLOCKING Google round-trip inline
///    inside the create/send/poll requests,
///  - the app awaited a fresh URL probe before even asking for the chat,
///  - the messages poll ran one DB query PER SENDER for names.
void main() {
  final fsSync =
      File('backend/firestore_sync.py').readAsStringSync();
  final supportPy =
      File('backend/routers/support.py').readAsStringSync();
  final helpDart =
      File('lib/screens/help_screen.dart').readAsStringSync();

  test('Firestore mirrors run off the calling thread', () {
    expect(fsSync, contains('def _offload('));
    for (final fn in [
      '_sync_support_chat_now',
      '_sync_support_message_now',
      '_mark_support_messages_read_now',
    ]) {
      expect(fsSync, contains('def $fn('),
          reason: 'the real work moved to a $fn worker-thread function');
      expect(fsSync, contains('_offload($fn'),
          reason: 'the public $fn wrapper offloads instead of blocking');
    }
    expect(fsSync, contains('except RuntimeError'),
        reason: 'no running loop (scripts) stays synchronous');
  });

  test('the messages poll names senders in ONE query', () {
    expect(supportPy, contains('User.id.in_(sender_ids)'));
    expect(
        supportPy,
        isNot(contains(
            'for sid in sender_ids:\n        r = await db.execute')),
        reason: 'the per-sender query loop is gone');
  });

  test('the app never awaits a fresh URL probe before opening the chat', () {
    expect(
        helpDart,
        contains(
            'unawaited(ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 4))'),
        reason: 'the boot probe already settled the URL — awaiting a new '
            'one added up to 4 s to every chat open');
    expect(
        helpDart,
        isNot(contains(
            'await ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 4))')),
        reason: 'the blocking probe in _initChat is gone (the 8 s one in '
            'the error-retry path stays on purpose)');
  });
}
