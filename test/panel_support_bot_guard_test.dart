import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the support-bot diagnostics + reactivation (user report
/// 2026-10-14: "el soporte no funciona — revisa qué le pasó al robot y
/// activa para que atienda a las personas que han escrito"). Chats stuck in
/// a silent phase (escalated / phantom dispatch_takeover) with no human
/// message ever written waited forever; dispatch now sees them and hands
/// them back to the bot, answering the pending message on the spot.
void main() {
  test('backend exposes bot-status and bot-reactivate, dispatch-gated', () {
    final s = File('backend/routers/support.py').readAsStringSync();
    expect(s, contains('/support/bot-status'));
    expect(s, contains('/support/bot-reactivate'));
    expect(s, contains('attended_by_human'),
        reason: 'chats a human actually wrote in are NEVER handed back to '
            'the bot');
    expect(s, contains('_background_bot_reply('),
        reason: 'reactivation answers the pending message immediately');
    final statusIdx = s.indexOf('/support/bot-status');
    expect(
        s.substring(statusIdx - 300, statusIdx + 90),
        contains('_require_dispatch_auth'),
        reason: 'bot-status is dispatch-only');
    final reIdx = s.indexOf('/support/bot-reactivate');
    expect(s.substring(reIdx - 300, reIdx + 90),
        contains('_require_dispatch_auth'));
  });

  test('the panel support page carries the bot card', () {
    final chunk = Directory('backend/dispatch_panel/assets')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
        .map((f) => f.readAsStringSync())
        .firstWhere((s) => s.contains('SupportChatListScreen'),
            orElse: () => '');
    expect(chunk, isNotEmpty,
        reason: 'no built chunk exports SupportChatListScreen');
    expect(chunk, contains('PanelBotStatusCard'),
        reason: 'the bot-status card is mounted on the chat list page');
    expect(chunk, contains('/support/bot-status'));
    expect(chunk, contains('/support/bot-reactivate'));
    expect(chunk, contains('Reactivar bot y atender'));
    expect(chunk, contains('guard-pin panel_support_bot_guard_test'),
        reason: 'the bundle edit carries its guard-pin so the next rebuild '
            'of the out-of-repo React source re-applies it');
  });
}
