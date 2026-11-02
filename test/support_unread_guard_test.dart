// Support writes mid-trip (owner 2026-11-02): the headset in the trip panel
// carries the unread count, a tap opens THAT chat, and the chat marks where
// the new messages start.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final chat = File('lib/screens/help_screen.dart').readAsStringSync();

  test('the trip screen polls the count and hands it to the panel', () {
    expect(trip.contains('ApiService.getSupportUnread()'), isTrue);
    expect(trip.contains('supportUnread: _supportUnread,'), isTrue);
    expect(trip.contains('_supportUnreadTimer?.cancel();'), isTrue,
        reason: 'the poll dies with the screen');
  });

  test('a tap with unread messages opens the chat that has them', () {
    expect(
      trip.contains(
          'chatId: problem == null && _supportUnread > 0 ? _supportUnreadChatId : null,'),
      isTrue,
    );
  });

  test('"Mensajes nuevos" sits above the first message that was unread', () {
    expect(chat.contains("m['was_unread'] == true"), isTrue);
    expect(chat.contains('if (_newFromId != null && msg.id == _newFromId) {'),
        isTrue);
    expect(chat.contains('S.of(context).supportNewMessages'), isTrue);
  });
}
