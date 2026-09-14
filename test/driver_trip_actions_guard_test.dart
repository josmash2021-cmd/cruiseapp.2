import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the driver trip screen's action row (user spec 2026-09-14):
/// chat / call / support as one centered, labeled Find-My row — the call
/// disc the only gold-filled one, the unread badge on chat — replacing the
/// old icon-only discs that sat beside the avatar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync();

  test('the row is chat / call / support with labels, call filled gold', () {
    expect(src.contains('_tripActionBtn('), isTrue);
    expect(src.contains('icon: Icons.chat_bubble_rounded'), isTrue);
    expect(src.contains('icon: Icons.call_rounded'), isTrue);
    expect(src.contains('filled: true'), isTrue,
        reason: 'the call disc is the only gold-filled one');
    expect(src.contains('icon: Icons.support_agent_rounded'), isTrue);
    expect(src.contains('label: S.of(context).chat'), isTrue);
    expect(src.contains('label: S.of(context).callAction'), isTrue);
    expect(src.contains('label: S.of(context).supportAction'), isTrue);
  });

  test('chat keeps the unread badge and support opens the support chat', () {
    final badgeIdx = src.indexOf('badge: ChatService().unreadCountStream(');
    expect(badgeIdx, isNonNegative,
        reason: 'the unread count stream rides the chat disc');
    final badgeBody = src.substring(badgeIdx, badgeIdx + 200);
    expect(badgeBody.contains("readerRole: 'driver'"), isTrue);
    expect(src.contains('onTap: _openChat'), isTrue);
    expect(src.contains('onTap: _call'), isTrue);
    expect(src.contains('onTap: _openSupportChat'), isTrue,
        reason: 'support opens the in-trip support chat like the menu does');
  });

  test('the old icon-only discs are gone', () {
    expect(src.contains('_msgBtnWithBadge('), isFalse,
        reason: 'replaced by the labeled row');
    expect(src.contains('Widget _actionBtn('), isFalse,
        reason: 'the old icon-only disc helper must not come back');
  });
}
