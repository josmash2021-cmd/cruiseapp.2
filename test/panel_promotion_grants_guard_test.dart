import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final assets = Directory('backend/dispatch_panel/assets').listSync().whereType<File>().toList();
  final panelFile = assets.firstWhere(
    (file) => file.path.endsWith('.js') &&
        file.readAsStringSync().contains('guard-pin panel_promotion_grants_guard_test'),
  );
  final panel = panelFile.readAsStringSync().replaceAll('\r\n', '\n');
  test('grant UI uses real endpoints, rider pagination and explicit all-riders confirmation', () {
    final sectionStart = panel.indexOf('/*! guard-pin panel_promotion_grants_guard_test');
    final sectionEnd = panel.indexOf('function js({onRetry', sectionStart);
    expect(sectionStart, isNonNegative);
    expect(sectionEnd, greaterThan(sectionStart));
    final section = panel.substring(sectionStart, sectionEnd);
    for (final needle in [
      '/admin/promotion-grants',
      'searchNotificationRecipients("rider",query.trim(),"all")',
      'if(form.allRiders){setConfirmAll(!0);return}void createNow(result.payload)',
      'open:confirmAll',
      'Sí, crear para todos',
      'children:"Revocar"',
      'children:"Activar"',
      'children:expanded?"Ocultar redenciones":"Ver redenciones"',
      'Usos por rider:',
      'promotionAudience(grant)',
      'promotionStatus(grant)',
      'listPromotionRedemptions(grant.id)',
      'VIP no es elegible',
      'function jr(){return t.jsx(PromotionGrantsScreen,{})}',
    ]) {
      expect(section, contains(needle), reason: needle);
    }
    expect(section, isNot(contains('addOptimistic')));
    expect(section, isNot(contains('/admin/promos/')));
  });

  test('real builders enforce Percent Free audience tiers and immutable patch fields', () {
    final start = panel.indexOf('const PROMOTION_TIERS=');
    final end = panel.indexOf('function promotionTitle', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
const Ie = async path => { calls.push({method: 'GET', path}); return path.endsWith('/redemptions') ? {redemptions: []} : {grants: []}; };
const \$e = async (path, payload) => { calls.push({method: 'POST', path, payload}); return payload; };
const vt = async (path, payload) => { calls.push({method: 'PATCH', path, payload}); return payload; };
$helpers
(async () => {
  if (PROMOTION_TIER_IDS.join(',') !== 'standard,compact,electric_pro,premium') throw new Error('wrong promo tiers');
  if (PROMOTION_TIER_IDS.includes('vip')) throw new Error('VIP must not be eligible');
  const base = emptyPromotionForm();
  const percent = buildPromotionGrantPayload({...base, maxMiles: '5'}, [{id: 7}, {id: 9}]);
  if (percent.error !== null) throw new Error(percent.error);
  if (percent.payload.kind !== 'percent' || percent.payload.percent !== 30 || percent.payload.max_miles !== null) {
    throw new Error('wrong Percent payload: ' + JSON.stringify(percent.payload));
  }
  if (percent.payload.rider_ids.join(',') !== '7,9' || percent.payload.all_riders !== false) throw new Error('wrong individual audience');
  if (percent.payload.allowed_tiers.includes('vip')) throw new Error('VIP leaked into payload');
  const free = buildPromotionGrantPayload({...base, kind: 'free', maxMiles: '5', fallbackPercent: '30', allRiders: true}, [{id: 999}]);
  if (free.error !== null) throw new Error(free.error);
  if (free.payload.kind !== 'free' || free.payload.percent !== 30 || free.payload.fallback_percent !== 30 || free.payload.max_miles !== 5) {
    throw new Error('wrong Free payload: ' + JSON.stringify(free.payload));
  }
  if (free.payload.all_riders !== true || free.payload.rider_ids.length !== 0) throw new Error('all riders must have an empty id list');
  const invalid = [
    buildPromotionGrantPayload({...base, percent: '100'}, [{id: 1}]),
    buildPromotionGrantPayload({...base, kind: 'free', maxMiles: ''}, [{id: 1}]),
    buildPromotionGrantPayload(base, []),
    buildPromotionGrantPayload({...base, allowedTiers: ['vip']}, [{id: 1}]),
    buildPromotionGrantPayload({...base, startsAt: '2026-11-02T10:00', expiresAt: '2026-11-01T10:00'}, [{id: 1}]),
  ];
  if (invalid.some(result => result.error === null || result.payload !== null)) throw new Error('invalid grant accepted');
  await updatePromotionGrant(42, {is_active: false, expires_at: null, reason: 'stop', percent: 90, kind: 'free', rider_ids: [1]});
  const patchCall = calls[calls.length - 1];
  if (patchCall.path !== '/admin/promotion-grants/42') throw new Error('wrong grant PATCH path');
  if (JSON.stringify(patchCall.payload) !== JSON.stringify({is_active: false, expires_at: null, reason: 'stop'})) {
    throw new Error('immutable grant fields leaked: ' + JSON.stringify(patchCall.payload));
  }
  await listPromotionGrants();
  await listPromotionRedemptions(42);
  if (!calls.some(call => call.path === '/admin/promotion-grants/42/redemptions')) throw new Error('missing redemption history call');
  console.log(JSON.stringify({percent: percent.payload, free: free.payload, patch: patchCall.payload}));
})().catch(error => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"max_miles":5'));
    expect('${result.stdout}', contains('"rider_ids":[]'));
  });

  test('edited grants bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
