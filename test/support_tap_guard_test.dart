import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the support-message push tap routing (2026-10-20, user
/// spec: "cuando le dan abre el chat ya listo con los mensajes así hayan
/// cerrado la app"). The backend pushes type support_message (bot/dispatch
/// message or human takeover) and support_followup (the 24h check); the tap
/// must land on CruiseSupportChatScreen, which resumes the open chat.
void main() {
  final mainDart = File('lib/main.dart').readAsStringSync();

  test('main.dart routes support pushes to the support chat screen', () {
    expect(mainDart, contains("type == 'support_message'"),
        reason: 'bot/dispatch messages open the chat');
    expect(mainDart, contains("type == 'support_followup'"),
        reason: 'the 24h follow-up opens it too');
    expect(mainDart, contains('_navigateToSupportChat'));
    expect(mainDart, contains('CruiseSupportChatScreen('),
        reason: 'the screen resumes the open chat with its transcript');
    expect(mainDart,
        contains("import 'screens/help_screen.dart';"),
        reason: 'CruiseSupportChatScreen lives in help_screen.dart');
  });

  test('the backend pushes carry the chat id and type', () {
    final support = File('backend/routers/support.py').readAsStringSync();
    expect(support, contains('"type": "support_message"'));
    expect(support, contains('"chat_id": str(chat.id)'));
    expect(support, contains('Soporte CRUISE IN RIDE'),
        reason: 'ES title');
    expect(support, contains('CRUISE IN RIDE Support'),
        reason: 'EN title');
  });

  test('every message path pushes: dispatch, takeover, bot batch', () {
    final support = File('backend/routers/support.py').readAsStringSync();
    expect(
      RegExp(r'await _push_support_message\(').allMatches(support).length,
      greaterThanOrEqualTo(4),
      reason: 'helper + dispatch send + connect-agent + connect-supervisor '
          '+ bot batch',
    );
    expect(support, contains('first_bot_preview'),
        reason: 'the bot pushes ONCE per batch — never per part');
  });
}
