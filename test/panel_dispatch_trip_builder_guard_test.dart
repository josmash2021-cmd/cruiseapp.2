import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final assets = Directory('backend/dispatch_panel/assets').listSync().whereType<File>().toList();
  final panelFile = assets.firstWhere(
    (file) => file.path.endsWith('.js') &&
        file.readAsStringSync().contains('guard-pin panel_dispatch_trip_builder_guard_test'),
  );
  final panel = panelFile.readAsStringSync().replaceAll('\r\n', '\n');

  test('builder busca server-side, cotiza con quote fresco y nunca crea cuentas', () {
    final start = panel.indexOf('/*! guard-pin panel_dispatch_trip_builder_guard_test');
    final end = panel.indexOf('function rs(', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final helpers = panel.substring(start, end);
    for (final needle in [
      'async function searchDispatchRiders(query){const rows=await Ct("/admin/users",{query:{role:"rider",search:query,limit:8}})',
      'async function searchDispatchDrivers(query){const payload=await Ct("/admin/notification-recipients",{query:{role:"driver",search:query,limit:12}})',
      'function buildDispatchQuoteRequest(',
      'function parseAdminQuote(',
      'function dispatchRiderPayment(',
      'function buildDispatchTripPayload(',
      'gs("/admin/trips",buildDispatchTripPayload(s))',
      'quote_id:input.quoteId',
      'funding_mode:input.fundingMode',
      'allow_courtesy_when_unpaid:input.fundingMode==="platform"',
      'body.target_driver_id=input.targetDriverId',
      'body.tip_amount=input.tipAmount;body.tip_funding=input.fundingMode==="platform"?"platform":input.tipFunding',
      '{value:"standard",label:"Standard"}',
      '{value:"compact",label:"Compact"}',
      '{value:"electric_pro",label:"Electric Pro"}',
      '{value:"premium",label:"Premium"}',
      '{value:"vip",label:"VIP"}',
    ]) {
      expect(helpers, contains(needle), reason: needle);
    }
    for (final forbidden in [
      '/auth/register',
      '/estimate-fare',
      'ensureFresh',
      'users-DWu98l86',
      'value:"sedan"',
      'value:"comfort"',
      'password:',
      'first_name:',
    ]) {
      expect(helpers, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('pantalla exige rider existente, quote fresco, cortesía bloqueada y reserva dirigida', () {
    for (final needle in [
      'Sin coincidencias — el rider debe tener una cuenta registrada.',
      'Selecciona un rider existente',
      'disabled:!quoteFresh||saving',
      'quoteFresh=quote!==null&&quoteSig===currentSig&&currentSig!==""&&!quoting',
      'Cambiar a cortesía',
      'Cortesía — el rider no paga nada',
      'En cortesía, la propina también la cubre la plataforma.',
      'Todos los elegibles',
      'Driver específico',
      'row.is_online===true?"En línea":"Offline"',
      'approved?"Aprobado":"No aprobado"',
      'Espera a que la cotización esté lista.',
      'Confirmar creación del viaje',
      'nav(H.trip(tripId))',
      'La propina debe ser entre \$0 y \$\${DISPATCH_TIP_MAX_USD}.',
    ]) {
      expect(panel, contains(needle), reason: needle);
    }
    for (final forbidden in [
      'St("rider")',
      'Nombre completo',
      'se registrará una cuenta nueva',
      'DISPATCH_API_KEY',
      'x-dispatch',
      'label:"Sedan"',
      'label:"Comfort"',
      'Usar estimación',
    ]) {
      expect(panel, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('detalle muestra propina dispatch y reserva dirigida del snapshot', () {
    for (final needle in [
      'row.dispatch_tip_amount',
      'row.dispatch_tip_funding',
      'row.dispatch_tip_status',
      'row.target_driver_id',
      'row.target_driver_name',
      'label:"Reserva dirigida a"',
      'label:"Propina (dispatch)"',
      'label:"Propina la paga"',
      'label:"Estado de la propina"',
      'children:DISPATCH_TRIP_TIERS.map(tier=>e.jsx("option",{value:tier.value,children:tier.label},tier.value))',
    ]) {
      expect(panel, contains(needle), reason: needle);
    }
  });

  test('helpers reales: búsqueda, parseo de quote, pago y payload', () {
    final start = panel.indexOf('/*! guard-pin panel_dispatch_trip_builder_guard_test');
    final end = panel.indexOf('function rs(', start);
    final helpers = panel.substring(start, end);
    final scenario = '''
const calls = [];
class Ce extends Error { constructor(status, message) { super(message); this.status = status; } }
const Ct = async (path, opts) => {
  calls.push({ path, query: opts.query });
  if (path === "/admin/users") return [{ id: 41, first_name: "Ada", last_name: "Prueba", phone: "+10000000000" }];
  return { items: [{ id: 77, first_name: "Leo", last_name: "Prueba", is_online: true, verification_status: "approved", vehicle: { vehicle_type: "suburban" } }] };
};
const gs = async (path, body) => { calls.push({ path, body }); return { id: 555 }; };
const tierLabel = (v) => v;
$helpers
(async () => {
  const riders = await searchDispatchRiders("ada");
  if (riders.length !== 1 || calls[0].path !== "/admin/users" || calls[0].query.role !== "rider" || calls[0].query.search !== "ada") throw new Error("rider search must hit /admin/users role=rider");
  const drivers = await searchDispatchDrivers("leo");
  if (drivers.length !== 1 || calls[1].path !== "/admin/notification-recipients" || calls[1].query.role !== "driver") throw new Error("driver search must hit notification-recipients role=driver");
  if (dispatchPersonName(riders[0]) !== "Ada Prueba") throw new Error("person name");
  if (dispatchTierLabel("electric_pro") !== "Electric Pro" || dispatchTierLabel("suburban") !== "suburban") throw new Error("tier label");
  const promo = parseAdminQuote({ quote_id: "q1", pricing_version: 7, distance_miles: 4.2, duration_minutes: 11, payment_methods: [{ method_type: "card", display_name: "Visa ···· 4242", is_default: true }], cruise_cash_balance_cents: 300, driver_estimate_cents: 1260, platform_credit_cents: 0, quotes: [{ tier: "standard", original_total_cents: 2000, promo_total_cents: 1400, discount_amount_cents: 600, is_free: false }, { tier: "vip", original_total_cents: 5000, promo_total_cents: 5000 }] }, "standard");
  if (promo.quoteId !== "q1" || promo.promoCents !== 1400 || promo.discountCents !== 600 || promo.isFree !== false) throw new Error("promo quote parse");
  if (promo.defaultMethod.display_name !== "Visa ···· 4242" || promo.cruiseCashCents !== 300 || promo.pricingVersion !== 7) throw new Error("quote extras");
  const free = parseAdminQuote({ quote_id: "q2", quotes: { tier: "vip", original_total_cents: 3000, promo_total_cents: 0, discount_amount_cents: 3000, is_free: true }, driver_estimate_cents: 2700, platform_credit_cents: 2700, payment_methods: [] }, "vip");
  if (!free.isFree || free.promoCents !== 0 || free.platformCreditCents !== 2700) throw new Error("free quote parse");
  if (parseAdminQuote(null, "standard") !== null || parseAdminQuote({ quotes: [] }, "standard") !== null || parseAdminQuote({}, "standard") !== null) throw new Error("invalid quote must be null");
  const withCard = dispatchRiderPayment(promo);
  if (!withCard.canCharge || withCard.riderChargeCents !== 1100 || withCard.cruiseCashAppliedCents !== 300) throw new Error("card + cruise cash math");
  const cashOnly = dispatchRiderPayment(parseAdminQuote({ quote_id: "q3", quotes: { tier: "standard", original_total_cents: 2000, promo_total_cents: 2000 }, payment_methods: [], cruise_cash_balance_cents: 5000 }, "standard"));
  if (!cashOnly.canCharge || cashOnly.riderChargeCents !== 0) throw new Error("cruise cash covering all must be chargeable");
  const broke = dispatchRiderPayment(parseAdminQuote({ quote_id: "q4", quotes: { tier: "standard", original_total_cents: 2000, promo_total_cents: 2000 }, payment_methods: [], cruise_cash_balance_cents: 100 }, "standard"));
  if (broke.canCharge) throw new Error("rider without method nor cash must be blocked");
  if (!dispatchRiderPayment(free).canCharge) throw new Error("free trip must be chargeable");
  const courtesy = buildDispatchTripPayload({ riderId: 41, pickupAddress: "A", pickupLat: 28.5, pickupLng: -81.3, dropoffAddress: "B", dropoffLat: 28.6, dropoffLng: -81.4, tier: "compact", quoteId: "q1", fundingMode: "platform", scheduledAt: "2026-10-30T15:00:00.000Z", targetDriverId: 77, tipAmount: 10, tipFunding: "rider", notes: "  nota  " });
  if (courtesy.funding_mode !== "platform" || courtesy.allow_courtesy_when_unpaid !== true) throw new Error("courtesy flags");
  if (courtesy.tip_funding !== "platform") throw new Error("courtesy must force tip funding platform");
  if (courtesy.tip_amount !== 10 || courtesy.target_driver_id !== 77 || courtesy.scheduled_at !== "2026-10-30T15:00:00.000Z" || courtesy.notes !== "nota") throw new Error("courtesy payload fields");
  const plain = buildDispatchTripPayload({ riderId: 41, pickupAddress: "A", pickupLat: 1, pickupLng: 1, dropoffAddress: "B", dropoffLat: 2, dropoffLng: 2, tier: "standard", quoteId: "q1", fundingMode: "rider", scheduledAt: null, targetDriverId: null, tipAmount: 0, tipFunding: "rider", notes: " " });
  if (plain.allow_courtesy_when_unpaid !== false || "tip_amount" in plain || "target_driver_id" in plain || "scheduled_at" in plain || "notes" in plain) throw new Error("plain payload must omit optionals");
  const created = await Ps({ riderId: 41, pickupAddress: "A", pickupLat: 1, pickupLng: 1, dropoffAddress: "B", dropoffLat: 2, dropoffLng: 2, tier: "vip", quoteId: "q9", fundingMode: "rider", scheduledAt: null, targetDriverId: null, tipAmount: 0, tipFunding: "rider", notes: "" });
  if (created !== "sql_555" || calls[2].path !== "/admin/trips" || calls[2].body.quote_id !== "q9") throw new Error("create must post to /admin/trips with quote_id");
  const req = buildDispatchQuoteRequest({ riderId: 41, pickupAddress: "A", pickupLat: 1, pickupLng: 1, dropoffAddress: "B", dropoffLat: 2, dropoffLng: 2, tier: "vip", scheduledAt: null });
  if (req.rider_id !== 41 || req.vehicle_type !== "vip" || "scheduled_at" in req) throw new Error("quote request");
  if ("first_name" in req || "password" in req || "email" in req) throw new Error("quote request must never carry account fields");
  console.log(JSON.stringify({ ok: true, charge: withCard.riderChargeCents, tip: courtesy.tip_funding }));
})().catch((error) => { console.error(error); process.exit(1); });
''';
    final result = Process.runSync('node', ['-e', scenario]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"charge":1100'));
    expect('${result.stdout}', contains('"tip":"platform"'));
  });

  test('edited trip builder bundle parses', () {
    final result = Process.runSync('node', ['--check', panelFile.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
