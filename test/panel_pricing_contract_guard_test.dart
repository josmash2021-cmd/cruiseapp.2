import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final assets = Directory('backend/dispatch_panel/assets').listSync().whereType<File>().toList();
  final panelFile = assets.firstWhere(
    (file) => file.path.endsWith('.js') &&
        file.readAsStringSync().contains('guard-pin panel_pricing_contract_guard_test'),
  );
  final panel = panelFile.readAsStringSync().replaceAll('\r\n', '\n');
  test('active pricing UI exposes every real tier rate and no dead controls', () {
    final sectionStart = panel.indexOf('/*! guard-pin panel_pricing_contract_guard_test');
    final sectionEnd = panel.indexOf('function legacyPricingScreen', sectionStart);
    expect(sectionStart, isNonNegative);
    expect(sectionEnd, greaterThan(sectionStart));
    final section = panel.substring(sectionStart, sectionEnd);
    for (final needle in [
      'async function ka(){return Ie("/admin/pricing")}',
      'async function savePricingConfig(patch){return vt("/admin/pricing",patch)}',
      'id:"standard"',
      'id:"compact"',
      'id:"electric_pro"',
      'id:"premium"',
      'id:"vip"',
      'key:"base"',
      'key:"per_mile"',
      'key:"per_minute"',
      'key:"booking_fee"',
      'key:"min_fare"',
      'apiKey:"scheduled_surcharge_pct"',
      'apiKey:"airport_fee"',
      'apiKey:"airport_meet_greet_fee"',
      r'Versión ${config.version}',
      'makePricingDraft(saved)',
      'setBaseline(next)',
      'setDraft(next)',
      't.jsx(ContractDocsSection,{})',
    ]) {
      expect(panel, contains(needle), reason: needle);
    }
    for (final forbidden in [
      'per_mile_rate',
      'surge_multiplier',
      'surgeMultiplier',
      'vehicle_multipliers',
      'Multiplicador de demanda',
      'Tarifas actuales',
    ]) {
      expect(section, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('real draft and patch helpers send only changed contract fields', () {
    final start = panel.indexOf('const PRICING_TIERS=');
    final end = panel.indexOf('function cs()', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
const vt = async (path, patch) => { calls.push({path, patch}); return {ok: true}; };
$helpers
const rate = (base, perMile) => ({base, per_mile: perMile, per_minute: .2, booking_fee: 2.5, min_fare: 8});
const config = {
  version: 7,
  rates: {
    standard: rate(2, 1), compact: rate(2.5, 1.15), electric_pro: rate(2.5, 1.4),
    premium: rate(3, 1.75), vip: rate(7.5, 2.75),
  },
  scheduled_surcharge_pct: .12,
  airport_fee: 10,
  airport_meet_greet_fee: 5,
};
(async () => {
  const baseline = makePricingDraft(config);
  if (baseline.scheduledSurchargePct !== '12') throw new Error('surcharge must be shown as 12 percent');
  const unchanged = buildPricingPatch(baseline, baseline);
  if (unchanged.error !== null || Object.keys(unchanged.patch).length !== 0) throw new Error('false dirty patch');
  const draft = makePricingDraft(config);
  draft.rates.standard.per_mile = '1.25';
  draft.scheduledSurchargePct = '15';
  draft.airportFee = '12';
  const changed = buildPricingPatch(draft, baseline);
  const expected = {rates: {standard: {per_mile: 1.25}}, scheduled_surcharge_pct: .15, airport_fee: 12};
  if (changed.error !== null || JSON.stringify(changed.patch) !== JSON.stringify(expected)) {
    throw new Error('wrong partial patch: ' + JSON.stringify(changed));
  }
  if ('per_mile_rate' in changed.patch || 'surge_multiplier' in changed.patch || 'vehicle_multipliers' in changed.patch) {
    throw new Error('dead pricing field leaked');
  }
  const response = await savePricingConfig(changed.patch);
  if (!response.ok || calls.length !== 1 || calls[0].path !== '/admin/pricing') throw new Error('wrong PATCH call');
  if (JSON.stringify(calls[0].patch) !== JSON.stringify(expected)) throw new Error('PATCH payload changed');
  const invalidDraft = makePricingDraft(config);
  invalidDraft.rates.vip.base = '101';
  const invalid = buildPricingPatch(invalidDraft, baseline);
  if (invalid.patch !== null || invalid.error === null) throw new Error('invalid rate was accepted');
  const zeroDraft = makePricingDraft(config);
  zeroDraft.rates.compact.booking_fee = '0';
  const zero = buildPricingPatch(zeroDraft, baseline);
  if (zero.error !== null || zero.patch.rates.compact.booking_fee !== 0) throw new Error('valid zero was rejected');
  console.log(JSON.stringify({patch: changed.patch, calls: calls.length}));
})().catch(error => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"per_mile":1.25'));
    expect('${result.stdout}', contains('"scheduled_surcharge_pct":0.15'));
  });

  test('edited pricing bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
