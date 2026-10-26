import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final state = source('lib/state/rider_trip_controller.dart');
  final booking = source('lib/screens/ride_request_controller.dart');
  final widgets = source('lib/screens/ride_request_widgets.dart');
  final api = source('lib/services/api_service.dart');
  final socket = source('lib/services/socket_service.dart');
  final promotions = source('lib/screens/promo_code_screen.dart');

  test('booking has no local fare authority or legacy promo math', () {
    for (final removed in [
      'anchorRates',
      'flDiscount',
      'getCurrentSurge',
      '_generateRideOptions',
      'priceEstimate * 0.9',
      'LocalDataService.setPromoUsed',
    ]) {
      expect(state, isNot(contains(removed)), reason: removed);
      expect(booking, isNot(contains(removed)), reason: removed);
      expect(widgets, isNot(contains(removed)), reason: removed);
    }
    expect(state, contains('ApiService.createRideQuote'));
    expect(state, contains('rideOptionsFromQuote'));
    expect(widgets, contains('QuotedFareView('));
  });

  test('quote, revision and promotions use the authenticated endpoints', () {
    expect(api, contains("Uri.parse('\$_baseUrl/pricing/quote')"));
    expect(api, contains("Uri.parse('\$_baseUrl/pricing/revision')"));
    expect(api, contains("Uri.parse('\$_baseUrl/promotions/me')"));
    expect(
      "if (quoteId != null) 'quote_id': quoteId".allMatches(api).length,
      2,
      reason: 'scheduled createTrip and immediate dispatch both send quote_id',
    );
    expect(api, contains("'meet_inside': meetInside"));
  });

  test('every booking entry quotes and canonical ids reach creation', () {
    expect(state, contains('void setPreloadedRoute('));
    expect(state, contains('_restartQuoteForInputs();'));
    expect(state, contains("'is_scheduled': _state.scheduledAt != null"));
    expect(state, contains("'stop_lat': _quoteCoordinate(stopLat)"));
    expect(state, contains("'meet_inside': _state.meetInside"));
    expect(state, contains('quoteId: _state.quote!.id'));
    expect(state, contains('vehicleType: _state.selectedOption!.canonicalTier'));
    expect(booking, contains('quoteId: quote.id'));
    expect(booking, contains('vehicleType: option.canonicalTier'));
    expect(booking, isNot(contains('vehicleType: state.selectedOption?.name')));
  });

  test('refresh is visible, debounced, latest-wins and revision gated', () {
    expect(state, contains('_quoteDebounceDelay'));
    expect(state, contains('_quotePollInterval = Duration(seconds: 20)'));
    expect(state, contains('const Duration(seconds: 60)'));
    expect(state, contains('requestSeq != _quoteSeq'));
    expect(state, contains('pricingChanged || promotionsChanged || expiring'));
    expect(state, contains('_appInForeground'));
    expect(state, contains('_categoryVisible'));
    expect(state, contains('_quoteFrozen'));
    expect(state, contains('prepareQuoteForConfirmation'));
    expect(socket, contains("on('pricing_updated'"));
    expect(socket, contains('pricingUpdatedStream'));
  });

  test('Free skips payment and Cruise Cash stays after the promo', () {
    expect(booking, contains('if (option.isFree || amountCents == 0)'));
    expect(booking, contains('rideHoldAmountCents('));
    expect(booking, contains('_cruiseCashCents >= option.promoTotalCents!'));
    expect(booking, contains('e.statusCode == 409'));
    expect(state, contains('apiErr?.statusCode == 409'));
    expect(state, contains('await refreshQuote();'));
    expect(state, contains('ApiService.cancelPaymentIntent(staleHold)'));
  });

  test('promotion screen is server driven with no local promo store', () {
    expect(promotions, contains('ApiService.getMyPromotions'));
    expect(promotions, contains('SocketService.pricingUpdatedStream'));
    expect(promotions, isNot(contains('SharedPreferences')));
    expect(promotions, isNot(contains('WELCOME10')));
    expect(promotions, isNot(contains('CRUISE50')));
    expect(promotions, isNot(contains('TextField(')));
  });
}
