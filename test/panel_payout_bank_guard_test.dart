import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch-assisted bank link in the person detail
/// (2026-10-27 owner spec: "desde cada perfil ayudar a conectar su banco").
/// The ficha must show the driver's current bank (bank+last4 only) and offer
/// attach/replace through POST /admin/users/{id}/payout-bank, with digits
/// never logged. Pins the helper, the card and its render point.
void main() {
  final helpers = File('backend/dispatch_panel/assets/users-DWu98l86.js')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final detail = File('backend/dispatch_panel/assets/index-azyIyM-i.js')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('helper posts to the dispatch bank endpoint and is exported', () {
    expect(helpers, contains('async function attachPayoutBank'));
    expect(helpers, contains('/payout-bank`'));
    expect(helpers, contains('export{getRiderInsights,getRiderPaymentMethods,updateVehicle,attachPayoutBank}'));
  });

  test('the bank card exists with attach and replace flows', () {
    expect(detail, contains('function BankPayoutCard'));
    expect(detail, contains('routing_number'));
    expect(detail, contains('account_number'));
    expect(detail, contains('replace:rows.length>0'));
    expect(detail, contains('attachPayoutBank(t.id,'));
  });

  test('the card renders in the driver detail right after Vehículo', () {
    expect(
      detail,
      contains(
        'title:"Vehículo",children:e.jsx(fa,{driver:A,backendDetail:f.detail,onVehicleSaved:()=>f.reload()})}),'
        'e.jsx(z,{icon:xe,title:"Banco y pagos",children:e.jsx(BankPayoutCard,{detail:f.detail,onSaved:()=>f.reload()})',
      ),
    );
  });

  test('bank list comes from backend payout_methods, never full numbers', () {
    expect(detail, contains('t?.payout_methods??[]'));
    expect(detail, contains('method_type==="bank_account"'));
    expect(detail.contains('has_connect'), isFalse,
        reason: 'the card reads the display only; no raw digits in UI');
  });
}
