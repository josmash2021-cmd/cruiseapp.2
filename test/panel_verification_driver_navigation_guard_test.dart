import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A driver row in Verificación must open the SAME full profile used by the
/// Drivers page, not the reduced verification modal. The React source lives
/// outside this repo, so the served bundle carries a guard-pin that any
/// rebuild must preserve.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final indexChunks = assets
      .listSync()
      .whereType<File>()
      .where(
          (file) => file.path.contains('index-') && file.path.endsWith('.js'))
      .map((file) => file.readAsStringSync())
      .toList();
  final verificationChunk = indexChunks.firstWhere(
    (source) => source
        .contains('guard-pin panel_verification_driver_navigation_guard_test'),
    orElse: () => '',
  );

  test('driver verification rows navigate to the full Drivers profile', () {
    expect(verificationChunk, isNotEmpty,
        reason: 'a rebuild must re-apply the driver navigation guard-pin');
    expect(
      verificationChunk,
      contains('onClick:e.role==="driver"?()=>nav(Ca(e)):t'),
      reason: 'drivers navigate while riders keep the existing modal',
    );
    expect(verificationChunk, contains(r'return`/personas/${e.role}/${t}`'),
        reason: 'the target is the shared person-detail route');
  });

  test('that route resolves to the existing reviewable PersonDetailScreen', () {
    final html = File('backend/dispatch_panel/index.html').readAsStringSync();
    final match =
        RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
    expect(match, isNotNull);
    final entry = match == null
        ? ''
        : File('backend/dispatch_panel/assets/${match.group(1)}')
            .readAsStringSync();
    expect(entry, contains('path:"/personas/:role/:personId"'));
    expect(entry, contains('default:e.PersonDetailRoute'));

    final profileChunk = indexChunks.firstWhere(
      (source) => source.contains('guard-pin panel_docs_grid_guard_test'),
      orElse: () => '',
    );
    expect(profileChunk, contains('Ia as PersonDetailRoute'));
    expect(profileChunk, contains('Social / Background check'));
  });
}
