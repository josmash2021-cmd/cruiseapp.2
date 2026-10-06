import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the duplicate-photo bug in the support chat (user report
/// 2026-10-07: "al enviar una foto se envia dos veces").
///
/// `_uploadAttachment` drops an optimistic local message carrying the signed
/// URL from the upload response; the server RE-SIGNS on every poll, so the
/// confirmed row arrives with a different query string. `_mergeMessages`
/// used to compare the full text — `local:rider:||ATT||<url_A>` never
/// matched `local:rider:||ATT||<url_B>`, the local copy was never swept and
/// the server copy landed next to it. The fix dedups attachments by the URL
/// PATH (the durable S3 key), which is stable across signings.
void main() {
  final src = File('lib/screens/help_screen.dart').readAsStringSync();

  test('attachment dedup normalizes to the URL path', () {
    expect(src.contains('static String _dedupKey(String role, String text)'),
        isTrue,
        reason: 'the merge needs a dedup identity that survives re-signing');
    final start = src.indexOf('static String _dedupKey(String role, String text)');
    final body = src.substring(start, start + 900);
    expect(body.contains('Uri.tryParse'), isTrue);
    expect(body.contains('uri.path'), isTrue,
        reason: 'the path embeds the S3 key — the only stable part of a '
            'presigned URL; the query string changes on every poll');
  });

  test('_mergeMessages sweeps local echoes by the normalized key', () {
    final start = src.indexOf('bool _mergeMessages(List<_ChatMsg> incoming)');
    expect(start, greaterThanOrEqualTo(0));
    final body = src.substring(start, start + 1400);
    expect(body.contains('_dedupKey(m.role, m.text)'), isTrue,
        reason: 'both the incoming set and the local sweep must use the same '
            'normalized key or the duplicate returns');
    expect(body.contains("'local:\${m.role}:\${m.text}'"), isFalse,
        reason: 'raw-text comparison is the bug — signed URLs never match');
  });
}
