import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _pin = 'guard-pin panel_photo_source_guard_test';

List<File> _pinnedChunks() => Directory('backend/dispatch_panel/assets')
    .listSync()
    .whereType<File>()
    .where((file) =>
        file.path.contains('index-') &&
        file.path.endsWith('.js') &&
        file.readAsStringSync().contains(_pin))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

String _extract(String source, String startNeedle, String endNeedle) {
  final start = source.indexOf(startNeedle);
  final end = source.indexOf(endNeedle, start);
  expect(start, isNonNegative, reason: startNeedle);
  expect(end, greaterThan(start), reason: '$startNeedle -> $endNeedle');
  return source.substring(start, end);
}

void main() {
  const backendUrl = 'https://api.example.test/real/profile.jpg';
  final chunks = _pinnedChunks();
  final entry = chunks.singleWhere(
      (file) => file.readAsStringSync().contains('function Se(e,t){'));
  final verification = chunks.singleWhere((file) =>
      file.readAsStringSync().contains('function ie(e){const t=[]'));
  final people = chunks.singleWhere(
      (file) => file.readAsStringSync().contains('function Ys({role:'));
  final entrySource = entry.readAsStringSync();
  final verificationSource = verification.readAsStringSync();
  final peopleSource = people.readAsStringSync();

  test('all three photo renderers use real URLs and carry the rebuild pin', () {
    expect(chunks, hasLength(3));
    for (final file in chunks) {
      expect(file.readAsStringSync(), isNot(contains('photos/user_')),
          reason: file.path);
    }
    expect(
        entrySource,
        contains(
            'profilePhotoUrl:t.profilePhotoUrl??e.profilePhotoUrl'));
    expect(entrySource, contains('profilePhotoUrl:c(m.photo_url)'));
    expect(entrySource, contains('profilePhotoUrl:o.profilePhotoUrl'));
    expect(verificationSource, isNot(contains('function Aa(')));
    expect(verificationSource, contains('e.selfieUrl!==null&&t.push'));
    expect(peopleSource, contains('photoUrl:s.photoUrl??null'));
    expect(peopleSource, isNot(contains('function yt(')));
  });

  test('real Se merge prefers backend photos and dedup keeps IDs separate', () {
    final seSource =
        _extract(entrySource, 'function Se(e,t){', 'function Zs(');
    final tnSource = _extract(entrySource, 'function tn(e){', 'function rn(');
    final scenario = '''
$seSource
$tnSource
const backendUrl = 'https://api.example.test/real/profile.jpg';
const oldUrl = 'https://firebase.example.test/old/profile.jpg';
const mergedFromNull = Se(
  {userId: 42, profilePhotoUrl: null},
  {profilePhotoUrl: backendUrl},
);
const mergedFromOld = Se(
  {userId: 42, profilePhotoUrl: oldUrl},
  {profilePhotoUrl: backendUrl},
);
const keptMirror = Se(
  {userId: 42, profilePhotoUrl: oldUrl},
  {profilePhotoUrl: null},
);
const shared = {
  phone: '+13055550100',
  email: 'same@example.com',
  firstName: 'Same',
  lastName: 'Person',
  submittedAt: null,
};
const rows = tn([
  {...shared, docId: 'sql_124', userId: 124, status: 'pending', profilePhotoUrl: null},
  {...shared, docId: 'sql_149', userId: 149, status: 'waitlist', profilePhotoUrl: backendUrl},
]);
const actual = {
  mergedFromNull: mergedFromNull.profilePhotoUrl,
  mergedFromOld: mergedFromOld.profilePhotoUrl,
  keptMirror: keptMirror.profilePhotoUrl,
  ids: rows.map((row) => row.userId),
};
const expected = {
  mergedFromNull: backendUrl,
  mergedFromOld: backendUrl,
  keptMirror: oldUrl,
  ids: [124, 149],
};
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error(JSON.stringify(actual));
  process.exit(1);
}
console.log(JSON.stringify(actual));
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"mergedFromOld":"$backendUrl"'));
    expect('${result.stdout}', contains('"ids":[124,149]'));
  });

  test('the edited photo bundles parse', () {
    for (final file in chunks) {
      final result = Process.runSync('node', ['--check', file.path]);
      expect(result.exitCode, 0, reason: '${file.path}\n${result.stderr}');
    }
  });
}
