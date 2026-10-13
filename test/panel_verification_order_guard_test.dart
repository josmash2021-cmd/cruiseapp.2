import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch panel verification-page ordering (user request
/// 2026-10-13: "en la pagina de verificacion colocame por orden de recien a
/// mas viejo sin danar nada").
///
/// The panel is a built React bundle served from backend/dispatch_panel —
/// the entry filename is hashed, so this guard resolves it from index.html
/// instead of hardcoding it. The page merges four sources and sorts by
/// submittedAt DESC; rows from GET /admin/verifications carried
/// submittedAt=null and sank to the bottom regardless of recency. The fix:
/// the endpoint ships created_at and the bundle maps it into submittedAt.
void main() {
  final html = File('backend/dispatch_panel/index.html')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);

  test('the live panel bundle resolves from index.html', () {
    expect(match, isNotNull,
        reason: 'index.html must reference the entry bundle');
  });

  final bundle = match == null
      ? ''
      : File('backend/dispatch_panel/assets/${match.group(1)}')
          .readAsStringSync();

  test('the queue sorts newest-first and backend rows carry a real date', () {
    expect(bundle.contains('.sort(rn)'), isTrue,
        reason: 'rn is the submittedAt-DESC comparator of the verification '
            'queue — without it the list renders unordered');
    expect(
      bundle.contains('submittedAt:_(e.created_at)??_(e.verified_at)'),
      isTrue,
      reason: 'backend rows used submittedAt:null → the comparator threw '
          'them to a year-2000 bucket at the bottom of the list',
    );
  });

  test('the backend payload ships created_at for the panel sort', () {
    final adminPy = File('backend/routers/admin.py')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(adminPy.contains('"created_at": u.created_at.isoformat()'), isTrue,
        reason: 'without created_at in /admin/verifications the panel has '
            'no date to sort backend rows by');
  });
}
