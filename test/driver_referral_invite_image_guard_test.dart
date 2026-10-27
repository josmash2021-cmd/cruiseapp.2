import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the referral invite share: text + link lets WhatsApp render
/// the golden artwork from the static landing's Open Graph metadata. The
/// artwork and its byte-identical backend copy remain available.
void main() {
  final src = File('lib/screens/driver/driver_referral_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the golden invite asset exists in the bundle', () {
    final f = File('assets/images/referral_invite.png');
    expect(f.existsSync(), isTrue,
        reason: 'the invite image must ship with the app');
    expect(f.lengthSync(), greaterThan(10000));
  });

  test('_shareInvite shares text and the OTA-safe path without an attachment', () {
    expect(src, contains("'\${ApiService.publicBaseUrl}/drive/\$_code'"));
    expect(
      src,
      contains('await shareText(context, text, subject: s.driverShareSubject)'),
    );
    expect(src, contains('driverShareCodeLine'));
    expect(src.contains('Share.shareXFiles('), isFalse);
  });

  test('the backend copy is byte-identical to the golden invite asset', () {
    final remote = File('backend/static/media/referral_invite.png');
    expect(remote.existsSync(), isTrue);
    expect(
      remote.readAsBytesSync(),
      orderedEquals(
        File('assets/images/referral_invite.png').readAsBytesSync(),
      ),
    );
  });

  test('no image attachment or download helper remains in the share flow', () {
    expect(src.contains('_inviteImageBytes'), isFalse);
    expect(src.contains('getTemporaryDirectory'), isFalse);
    expect(
      src.contains("rootBundle.load('assets/images/referral_invite.png')"),
      isFalse,
    );
  });
}
