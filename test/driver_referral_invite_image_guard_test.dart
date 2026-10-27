import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the referral invite share (2026-10-27 owner spec): the share
/// must attach the golden invite image alongside the code+link, not a bare
/// text message. Uses a temp file (shareXFiles needs a real path on device)
/// and falls back to text-only if the image write fails.
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

  test('_shareInvite shares the image as an attachment plus code and link', () {
    expect(src, contains("rootBundle.load('assets/images/referral_invite.png')"));
    expect(src, contains('Share.shareXFiles('));
    expect(src, contains('text: text,'));
    expect(src, contains('subject: s.driverShareSubject'));
  });

  test('falls back to text-only when the image write fails', () {
    expect(src, contains('unawaited(shareText(context, text'));
  });
}
