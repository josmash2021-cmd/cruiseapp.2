import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the offers list (2026-10-27 user spec: "tarjetas duplicadas
/// y que sea tarjeta por tarjeta, no carrusel").
///
/// Two load-bearing rules:
///   1. The offers UI is a VERTICAL list, each card with its own accept
///      button — no PageView carousel and no page dots.
///   2. _applyOffers dedups by TRIP (newest offer wins), not just offer_id,
///      so a retry/cascade that creates two DispatchOffer rows for the same
///      trip can never show the same ride twice.
void main() {
  final widgets = File('lib/screens/driver/driver_online_widgets.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('offers render as a vertical list, not a PageView carousel', () {
    expect(widgets, contains('ListView.builder('));
    expect(widgets, isNot(contains('PageView.builder(')),
        reason: 'the offer carousel is dead — cards go one per row');
    expect(widgets, isNot(contains('Page indicator dots')));
  });

  test('each offer card owns its accept button', () {
    expect(widgets, contains('child: _buildAcceptButton(offer, oid)'));
    expect(widgets, isNot(contains('_buildAcceptButton(_pendingOffers[safeIdx]')),
        reason: 'no more shared accept pill bound to the current page');
  });

  test('_applyOffers dedups by trip, newest offer wins', () {
    expect(controller, contains('final newestByTrip = <String, Map<String, dynamic>>{}'));
    expect(controller, contains('One card per TRIP, newest offer wins'));
    expect(controller, contains('filtered = newestByTrip.values.toList();'));
  });
}
