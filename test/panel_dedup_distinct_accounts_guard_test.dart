import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch panel verification-queue dedup (user report
/// 2026-10-17: "Victor Galue no me aparece en la pagina de verificacion
/// pero si en la pagina de drivers").
///
/// The queue merges four sources (Firestore verifications / clients /
/// drivers + GET /admin/verifications) and dedups by docId / userId /
/// phone / email. Two PG accounts of the same person — rider sql_124 and
/// driver sql_149, same phone and email — collided on the phone/email
/// keys and the "pending" rider row REPLACED the waitlisted driver row,
/// so the driver vanished from the Drivers tab of the verification page
/// while still showing in the Drivers page (which dedups only by id).
///
/// The fix is a manual bundle edit (the panel source lives outside this
/// repo — a rebuild must re-apply it, the guard-pin comment says so): a
/// dedup match is rejected when both rows carry a different userId > 0.
/// Phone/email may still merge a no-userId sheet into its backend row,
/// and same-account rows still merge by docId/uid.
void main() {
  final html = File('backend/dispatch_panel/index.html')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
  final bundle = match == null
      ? ''
      : File('backend/dispatch_panel/assets/${match.group(1)}')
          .readAsStringSync();

  test('the dedup never merges two distinct backend accounts', () {
    expect(match, isNotNull,
        reason: 'index.html must reference the entry bundle');
    expect(
      bundle.contains('!(o.userId>0&&t[v].userId>0&&o.userId!==t[v].userId)'),
      isTrue,
      reason: 'without this guard a phone/email match lets one account '
          'absorb another (rider 124 hid driver 149)',
    );
    expect(
      bundle.contains('panel_dedup_distinct_accounts_guard_test'),
      isTrue,
      reason: 'the guard-pin comment tells a rebuild to re-apply the fix',
    );
  });
}
