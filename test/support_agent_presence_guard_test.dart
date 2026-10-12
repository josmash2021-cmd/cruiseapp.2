import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardians for the support-chat presence polish (user report 2026-10-11,
/// chat 84):
///  - the bot's bubble avatar is the SUPPORT GLYPH, never a letter;
///  - a connected human signs with the chat's agent-name initial ("Diego" →
///    D), never the "Agente especializado" label's A;
///  - the agent's bubble is GOLD like the rest of the brand, never purple;
///  - while the human types in the panel the app shows "escribiendo…"
///    (polled from the backend typing endpoint).
void main() {
  final src = File('lib/screens/help_screen.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();

  test('bot avatar is the support glyph inside _buildBubble', () {
    final start = src.indexOf('Widget _buildBubble(_ChatMsg msg)');
    expect(start, greaterThanOrEqualTo(0));
    final body = src.substring(start);
    expect(body.contains('Icons.support_agent_rounded'), isTrue,
        reason: 'the robot bubble must carry the support icon, not a letter');
  });

  test('dispatch avatar letters the chat agent name, not the label', () {
    final start = src.indexOf('Widget _buildBubble(_ChatMsg msg)');
    final body = src.substring(start);
    expect(body.contains('_agentName![0].toUpperCase()'), isTrue,
        reason: 'the human bubble shows D for Diego — the A came from '
            '"Agente especializado" and read as a different person');
  });

  test('no purple left in the incoming bubbles', () {
    for (final purple in ['0xFF6A5ACD', '0xFF483D8B', '0xFF9D8FE8', '0xFF1E1A2E']) {
      expect(src.contains(purple), isFalse,
          reason: '$purple is the old dispatch purple — the agent bubble is '
              'gold like the rest of the brand');
    }
    final start = src.indexOf('Widget _buildBubble(_ChatMsg msg)');
    final body = src.substring(start);
    expect(body.contains('0xFF2A2210'), isTrue,
        reason: 'the dispatch bubble keeps a distinct dark-gold tint');
  });

  test('dispatch typing drives the indicator and the status line', () {
    expect(src.contains('bool _isDispatchTyping = false;'), isTrue);
    expect(src.contains('ApiService.getSupportTyping(_chatId!)'), isTrue,
        reason: 'the 3 s message poll must also poll the typing flag');
    final status = src.indexOf("statusLabel = _isSpanish ? 'Escribiendo...' : 'Typing...';");
    expect(status, greaterThanOrEqualTo(0));
    final before = src.substring(status - 220, status);
    expect(before.contains('_isDispatchTyping'), isTrue,
        reason: 'the header says Escribiendo… when the HUMAN types too');
    final bubble = src.indexOf('child: TypingBubble(agentName: _agentName)');
    final bubbleIf = src.substring(bubble - 200, bubble);
    expect(bubbleIf.contains('_isDispatchTyping'), isTrue,
        reason: 'the three-dot bubble must appear for the human agent too');
  });

  test('ApiService exposes getSupportTyping against the typing endpoint', () {
    expect(api.contains('static Future<bool> getSupportTyping(int chatId)'), isTrue);
    final start = api.indexOf('static Future<bool> getSupportTyping(int chatId)');
    final body = api.substring(start, start + 700);
    expect(body.contains("/support/chats/\$chatId/typing"), isTrue);
    expect(body.contains("data['dispatch_typing'] == true"), isTrue);
    expect(body.contains('return false;'), isTrue,
        reason: 'non-critical: failures must read as "not typing"');
  });
}
