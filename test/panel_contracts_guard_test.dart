import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the digital-contracts UI on the dispatch panel (2026-10-21,
/// user spec — Uber-style e-acceptance admin). The panel is a compiled bundle
/// whose React source lives outside this repo — the guard-pin comment in each
/// edited chunk is what the next rebuild must re-apply. Backend endpoints
/// (/admin/contracts*) already exist; editing+bumping a contract IS the
/// re-acceptance wave (no per-driver re-request button).
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  String pick(bool Function(String) test) => assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere(test, orElse: () => '');

  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('listContracts'), orElse: () => '');
  final mainChunk = pick((s) => s.contains('async function Yr(){'));
  final personChunk = pick((s) => s.contains('function ExpirySugs({'));
  final configChunk = pick((s) => s.contains('Precios y Config'));

  test('users chunk exposes the contracts API helpers and their export', () {
    expect(usersModule, contains('guard-pin panel_contracts_guard_test'),
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(usersModule, contains('async function listContracts(){'));
    expect(usersModule, contains('/admin/contracts/acceptances?user_id='));
    expect(usersModule, contains('/admin/contracts/versions?slug='));
    expect(usersModule, contains('async function updateContract('));
    expect(usersModule, contains('async function downloadContractReceipt('));
    expect(usersModule, contains('receipt.pdf?user_id='),
        reason: 'the receipt PDF downloads via raw fetch with signed headers');
    expect(
        usersModule,
        contains(
            'listContracts,contractAcceptances,contractVersions,updateContract,downloadContractReceipt'),
        reason: 'all five helpers must be exported for the person page');
  });

  test('main chunk exports the signed-headers builder', () {
    expect(mainChunk, contains('Yr as aY'),
        reason: 'the receipt PDF fetch needs Yr() — without the export the '
            'users chunk import breaks the whole panel');
  });

  test('person page carries the ContractCards section after ExpirySugs', () {
    expect(personChunk, contains('guard-pin panel_contracts_guard_test'));
    expect(personChunk, contains('CONTRACT_DOC_LABELS'));
    expect(personChunk, contains('function ContractCards({userId:'));
    expect(personChunk, contains('Acuerdo de Contratista Independiente'));
    expect(personChunk, contains('Condiciones de Pagos y Comisiones'));
    expect(personChunk, contains('Pendiente'));
    expect(personChunk, contains('Firmado v'));
    expect(personChunk, contains('downloadContractReceipt'));
    expect(personChunk, contains('title:"Contratos"'));
    final expiryMount = personChunk.indexOf('ExpirySugs,{docs:');
    final contractMount = personChunk.indexOf('ContractCards,{userId:');
    expect(expiryMount, greaterThanOrEqualTo(0));
    expect(contractMount, greaterThan(expiryMount),
        reason: 'ContractCards mounts immediately after the ExpirySugs card '
            'on the person page');
  });

  test('config screen carries the legal-documents editor section', () {
    expect(configChunk, contains('guard-pin panel_contracts_guard_test'));
    expect(configChunk, contains('function ContractDocsSection()'));
    expect(configChunk, contains('Documentos legales'));
    expect(configChunk, contains('async function updateContract('));
    expect(configChunk, contains('Guardar y republicar'));
    expect(configChunk, contains('Historial'));
    expect(configChunk, contains('t.jsx(ContractDocsSection,{})'),
        reason: 'the section mounts inside the Tarifas tab column');
  });
}
