import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the push-channel cleanup on logout (user report 2026-09-17:
/// "notifications of a rider with a driver reach other drivers/riders").
///
/// FCM topic subscriptions bind the DEVICE, not the account — a phone that
/// ever went online as a driver stays subscribed to `drivers_available`
/// across logout, and marketplace broadcasts (with riders' addresses) kept
/// landing on whatever account signed in next.
void main() {
  final session =
      File('lib/services/user_session.dart').readAsStringSync();

  test('logout releases the device-wide driver topic', () {
    final body = srcIsolate(session, 'static Future<void> logout() async {');
    expect(body.contains("unsubscribeFromTopic('drivers_available')"),
        isTrue,
        reason: 'without this the marketplace broadcasts follow the PHONE, '
            'not the account — straight into the next account signed in');
  });

  test('logout still forgets the registered token memo', () {
    expect(session.contains('NotificationService.forgetRegisteredToken()'),
        isTrue);
  });
}

/// The body of a method, up to the next top-level declaration.
String srcIsolate(String src, String signature) {
  final start = src.indexOf(signature);
  assert(start >= 0, '$signature not found');
  final end = src.indexOf('\n  static ', start + signature.length);
  return src.substring(start, end > start ? end : src.length);
}
