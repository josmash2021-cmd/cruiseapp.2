import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('backend/dispatch_panel/assets/users-DWu98l86.js')
      .readAsStringSync();

  test('Dispatch name normalization removes every Spanish diacritic', () async {
    final helper = source.substring(
      source.indexOf('function normalizeDispatchPerson'),
      source.indexOf('async function O('),
    );
    final result = await Process.run('node', ['-e', '''
$helper
const assert = require('node:assert/strict');
assert.equal(normalizeDispatchPerson('José'), 'Jose');
assert.equal(normalizeDispatchPerson('Martínez'), 'Martinez');
assert.equal(normalizeDispatchPerson('María Ñuñez'), 'Maria Nunez');
assert.equal(normalizeDispatchPerson('Jose\u0301'), 'Jose');
assert.equal(normalizeDispatchPerson('Jhon'), 'Jhon');
assert.equal(normalizeDispatchPerson(null), '');
console.log('Dispatch names normalized');
''']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('Dispatch names normalized'));
  });

  test('registration, mirror creation and mirror edits all normalize names', () {
    final register = source.substring(
      source.indexOf('async function O('),
      source.indexOf('async function ee('),
    );
    expect(register, contains('firstName:normalizeDispatchPerson(e.firstName)'));
    expect(register, contains('lastName:normalizeDispatchPerson(e.lastName)'));

    final create = source.substring(
      source.indexOf('async function H('),
      source.indexOf('async function K('),
    );
    expect(create, contains('firstName:normalizeDispatchPerson(t.firstName)'));
    expect(create, contains('lastName:normalizeDispatchPerson(t.lastName)'));

    final edit = source.substring(
      source.indexOf('async function z('),
      source.indexOf('async function le('),
    );
    expect(edit, contains('s={...s}'));
    expect(edit, contains('s.firstName=normalizeDispatchPerson(s.firstName)'));
    expect(edit, contains('s.lastName=normalizeDispatchPerson(s.lastName)'));
  });

  test('edited Dispatch users bundle parses', () async {
    final result = await Process.run('node', [
      '--check',
      'backend/dispatch_panel/assets/users-DWu98l86.js',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  });
}
