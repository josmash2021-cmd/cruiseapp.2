import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final assets = Directory('backend/dispatch_panel/assets').listSync().whereType<File>().toList();
  final panelFile = assets.firstWhere(
    (file) => file.path.endsWith('.js') &&
        file.readAsStringSync().contains('guard-pin panel_trip_cost_breakdown_guard_test'),
  );
  final panel = panelFile.readAsStringSync().replaceAll('\r\n', '\n');
  // 2026-10-30: el desglose es simple (quién paga, cobrado, conductor,
  // plataforma, propina) y también sale para viajes viejos con solo fare.
  test('detail mounts the simple breakdown and keeps the information card', () {
    final sectionStart = panel.indexOf('/*! guard-pin panel_trip_cost_breakdown_guard_test');
    final sectionEnd = panel.indexOf('function la({tripId', sectionStart);
    expect(sectionStart, isNonNegative);
    expect(sectionEnd, greaterThan(sectionStart));
    final section = panel.substring(sectionStart, sectionEnd);
    for (final needle in [
      'const title="Desglose del pago"',
      'label:"Precio del viaje"',
      'label:"Quién paga"',
      'label:"Cobrado al pasajero"',
      'label:"Estado del cobro"',
      'label:final?"Para el conductor":"Para el conductor (aprox.)"',
      'label:"Para la plataforma"',
      'label:"Propina"',
      '"Se verá al terminar el viaje"',
      '(100% para el conductor)',
      'Plataforma (cortesía)',
      'Cruise Cash',
      'final=(done||st==="cancelled")&&sn.driverEarnings!==null',
      'e.jsx(TripCostBreakdown,{state:costState})',
      'useTripCostSnapshot(c.backendId??tripBackendId(s))',
      'title:"Información del viaje"',
      'title:"Ruta"',
    ]) {
      expect(panel, contains(needle), reason: needle);
    }
    expect(section, isNot(contains('margen')));
    expect(section, isNot(contains('Margin')));
  });

  test('real loader paginates and snapshot math preserves cents dollars and zeroes', () {
    final start = panel.indexOf('async function findTripPricingSnapshot');
    final end = panel.indexOf('function useTripCostSnapshot', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
const sample = {
  id: 777, fare: 0, original_fare_cents: 2000, rider_promo_total_cents: 0,
  driver_fare_cents: 2000, platform_credit_cents: 1800,
  platform_credit_applied_cents: 1800, cruise_cash_cents: 0,
  driver_earnings: 18, pricing_version: 7, quoted_distance_miles: 5,
  funding_source: 'platform_courtesy',
};
const Ct = async (path, options) => {
  calls.push({path, options});
  if (calls.length === 1) return Array.from({length: 500}, (_, index) => ({id: index + 1000}));
  return [sample];
};
$helpers
const close = (actual, expected, label) => {
  if (Math.abs(actual - expected) > 1e-9) throw new Error(label + ': expected ' + expected + ', got ' + actual);
};
(async () => {
  const loaded = await findTripPricingSnapshot(777);
  if (loaded.id !== 777 || calls.length !== 2) throw new Error('trip was not found through pagination');
  if (calls[0].path !== '/admin/trips' || calls[1].options.query.offset !== 500) throw new Error('wrong admin trip query');
  for (const call of calls) {
    if (call.options.query.limit !== 500 || call.options.query.include_auto_cancelled !== true) throw new Error('incomplete trip query');
  }
  const free = tripCostSnapshot(loaded);
  close(free.originalFare, 20, 'original');
  close(free.discount, 20, 'free discount');
  close(free.promoTotal, 0, 'free promo total');
  close(free.cruiseCash, 0, 'free cash');
  close(free.riderCharge, 0, 'free rider charge');
  close(free.driverBase, 20, 'free driver base');
  close(free.driverEarnings, 18, 'free driver earnings');
  close(free.platformCredit, 18, 'free expected platform cost');
  close(free.platformCreditApplied, 18, 'free applied platform cost');
  if (free.pricingVersion !== 7 || free.quotedDistanceMiles !== 5 || free.fundingSource !== 'platform_courtesy') {
    throw new Error('snapshot metadata was lost');
  }
  const discounted = tripCostSnapshot({
    fare: 12, original_fare_cents: 2000, rider_promo_total_cents: 1400,
    driver_fare_cents: 1400, cruise_cash_cents: 200, driver_earnings: 12.6,
    platform_credit_cents: 180, platform_credit_applied_cents: null,
  });
  close(discounted.discount, 6, 'discount');
  close(discounted.promoTotal, 14, 'promo total');
  close(discounted.cruiseCash, 2, 'cruise cash');
  close(discounted.riderCharge, 12, 'rider charge');
  close(discounted.driverBase, 14, 'driver base');
  close(discounted.driverEarnings, 12.6, 'driver earnings');
  if (discounted.platformCreditApplied !== null) throw new Error('pending credit must not become a real zero');
  const legacy = tripCostSnapshot({fare: 20, status: 'completed', tip_amount: 3, payment_status: 'paid'});
  close(legacy.originalFare, 20, 'legacy fare');
  close(legacy.riderCharge, 20, 'legacy rider charge');
  close(legacy.tipAmount, 3, 'legacy tip');
  if (legacy.tripStatus !== 'completed' || legacy.paymentStatus !== 'paid') throw new Error('legacy status lost');
  if (tripCostSnapshot({status: 'completed'}) !== null) throw new Error('a trip without any price must not get a card');
  if (tripBackendId('sql_777') !== 777 || tripBackendId('firestore-doc') !== null) throw new Error('wrong backend id parsing');
  console.log(JSON.stringify({free, discounted, calls: calls.length}));
})().catch(error => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"originalFare":20'));
    expect('${result.stdout}', contains('"driverEarnings":18'));
    expect('${result.stdout}', contains('"platformCreditApplied":18'));
  });

  test('edited trip bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
