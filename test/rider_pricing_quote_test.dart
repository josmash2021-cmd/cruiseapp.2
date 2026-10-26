import 'dart:async';

import 'package:cruise_app/services/directions_service.dart';
import 'package:cruise_app/services/places_service.dart';
import 'package:cruise_app/state/rider_trip_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> quotePayload(
  String id, {
  int pricingVersion = 1,
  int discountPercent = 30,
  String? freeTier,
}) {
  const tiers = ['standard', 'compact', 'electric_pro', 'premium', 'vip'];
  return {
    'quote_id': id,
    'expires_at': DateTime.now()
        .add(const Duration(minutes: 10))
        .toUtc()
        .toIso8601String(),
    'pricing_version': pricingVersion,
    'distance_miles': 4.2,
    'duration_minutes': 12,
    'routing_source': 'google',
    'quotes': [
      for (var i = 0; i < tiers.length; i++)
        () {
          final tier = tiers[i];
          final original = 1000 + i * 200;
          final free = tier == freeTier;
          final promo = free
              ? 0
              : discountPercent > 0
                  ? (original * (100 - discountPercent) / 100).round()
                  : original;
          return {
            'tier': tier,
            'original_total_cents': original,
            'promo_total_cents': promo,
            'discount_percent': free ? 100 : discountPercent,
            'discount_amount_cents': original - promo,
            'is_free': free,
            'free_max_miles': free ? 8.0 : null,
            'free_ineligible_reason': null,
            'scheduled_surcharge_cents': 0,
            'airport_fee_cents': 0,
            'meet_greet_fee_cents': 0,
            'surge_multiplier': 1.0,
          };
        }(),
    ],
  };
}

RouteResult routeFixture() => const RouteResult(
      points: [],
      distanceText: '4.2 mi',
      distanceMeters: 6760,
      durationText: '12 min',
      startAddress: 'Start',
      endAddress: 'End',
      durationSeconds: 720,
    );

PlaceDetails place(String address, double lat, double lng) =>
    PlaceDetails(address: address, lat: lat, lng: lng);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('quote mapping', () {
    test('maps every canonical tier and uses server cents verbatim', () {
      final options = rideOptionsFromQuote(quotePayload('q1'));
      expect(options.map((o) => o.id), [
        'fusion',
        'camry',
        'electric_pro',
        'suv_xl',
        'suburban',
      ]);
      expect(options.map((o) => o.canonicalTier), [
        'standard',
        'compact',
        'electric_pro',
        'premium',
        'vip',
      ]);
      final standard = options.first;
      expect(standard.originalTotalCents, 1000);
      expect(standard.promoTotalCents, 700);
      expect(standard.priceEstimate, 7.0);
      expect(standard.originalPriceEstimate, 10.0);
      expect(standard.discountPercent, 30);
      expect(standard.hasPercentageDiscount, isTrue);
      expect(canonicalRideTier('fusion'), 'standard');
      expect(canonicalRideTier('camry'), 'compact');
      expect(canonicalRideTier('electric_pro'), 'electric_pro');
      expect(canonicalRideTier('suv_xl'), 'premium');
      expect(canonicalRideTier('suburban'), 'vip');
    });

    test('accepts legitimate Free but rejects an unexplained zero fare', () {
      final free = rideOptionsFromQuote(
        quotePayload('q-free', freeTier: 'standard'),
      ).first;
      expect(free.isFree, isTrue);
      expect(free.hasServerPrice, isTrue);
      expect(free.priceEstimate, 0);
      final invalid = quotePayload('q-invalid', freeTier: 'standard');
      (invalid['quotes'] as List).first['is_free'] = false;
      expect(() => rideOptionsFromQuote(invalid), throwsFormatException);
    });
  });

  group('Cruise Cash after promotion', () {
    const option = RideOption(
      id: 'fusion',
      name: 'Comfort',
      description: '',
      priceEstimate: 140,
      etaMinutes: 12,
      icon: '',
      originalTotalCents: 20000,
      promoTotalCents: 14000,
      discountPercent: 30,
      discountAmountCents: 6000,
    );

    test('caps the adjustment at 50 dollars and never below zero', () {
      expect(applicableCruiseCashCents(option: option, balanceCents: 9000), 5000);
      expect(rideHoldAmountCents(option: option, balanceCents: 9000), 9000);
      expect(rideHoldAmountCents(option: option, balanceCents: 1000), 13000);
      expect(rideHoldAmountCents(option: option, balanceCents: 0), 14000);
    });

    test('Free skips Cruise Cash and the hold entirely', () {
      final free = rideOptionsFromQuote(
        quotePayload('q-free', freeTier: 'standard'),
      ).first;
      expect(applicableCruiseCashCents(option: free, balanceCents: 5000), 0);
      expect(rideHoldAmountCents(option: free, balanceCents: 5000), 0);
    });
  });

  group('RiderTripController quotes', () {
    test('preloaded routes include stop, schedule, airport and meet flags', () async {
      final bodies = <Map<String, dynamic>>[];
      final controller = RiderTripController(
        quoteFetcher: (body) async {
          bodies.add(Map<String, dynamic>.from(body));
          return quotePayload('q-flags');
        },
        revisionFetcher: () async =>
            {'pricing_version': 1, 'promotions_revision': '0'},
        pricingUpdates: const Stream.empty(),
      );
      addTearDown(controller.dispose);
      controller.setSchedule(DateTime.now().add(const Duration(hours: 3)));
      controller.setAirportMetadata(isAirport: true, code: 'MIA');
      controller.setMeetInside(true);
      controller.setStopAddress('Middle', lat: 25.8, lng: -80.2);
      controller.setPreloadedRoute(
        pickup: place('Start', 25.76123456, -80.19123456),
        pickupLabel: 'Start',
        dropoff: place('Airport', 25.90123456, -80.30123456),
        dropoffLabel: 'Airport',
        route: routeFixture(),
      );
      await controller.refreshQuote();
      expect(bodies, hasLength(1));
      expect(bodies.single, {
        'pickup_lat': 25.761235,
        'pickup_lng': -80.191235,
        'dropoff_lat': 25.901235,
        'dropoff_lng': -80.301235,
        'stop_lat': 25.8,
        'stop_lng': -80.2,
        'is_scheduled': true,
        'is_airport': true,
        'meet_inside': true,
      });
      expect(controller.state.quote?.id, 'q-flags');
      expect(controller.state.rideOptions.every((o) => o.hasServerPrice), isTrue);
    });

    test('latest response wins without replacing the selected tier', () async {
      final calls = <Completer<Map<String, dynamic>>>[];
      final controller = RiderTripController(
        quoteFetcher: (_) {
          final completer = Completer<Map<String, dynamic>>();
          calls.add(completer);
          return completer.future;
        },
        revisionFetcher: () async =>
            {'pricing_version': 1, 'promotions_revision': '0'},
        pricingUpdates: const Stream.empty(),
      );
      addTearDown(controller.dispose);
      controller.setPreloadedRoute(
        pickup: place('Start', 1, 1),
        pickupLabel: 'Start',
        dropoff: place('Old end', 2, 2),
        dropoffLabel: 'Old end',
        route: routeFixture(),
      );
      final first = controller.refreshQuote();
      controller.selectRideOption(controller.state.rideOptions.first);
      controller.setPreloadedRoute(
        pickup: place('Start', 1, 1),
        pickupLabel: 'Start',
        dropoff: place('New end', 3, 3),
        dropoffLabel: 'New end',
        route: routeFixture(),
      );
      final second = controller.refreshQuote();
      expect(calls, hasLength(2));
      calls[1].complete(quotePayload('q-new'));
      await second;
      calls[0].complete(quotePayload('q-old'));
      await first;
      expect(controller.state.quote?.id, 'q-new');
      expect(controller.state.dropoffLabel, 'New end');
      expect(controller.state.selectedOption?.id, 'suburban');
      expect(controller.state.selectedOption?.canonicalTier, 'vip');
    });

    test('socket refresh is debounced and frozen for confirmation', () async {
      final updates = StreamController<Map<String, dynamic>>();
      addTearDown(updates.close);
      var calls = 0;
      final controller = RiderTripController(
        quoteFetcher: (_) async {
          calls++;
          return quotePayload('q-$calls');
        },
        revisionFetcher: () async =>
            {'pricing_version': 1, 'promotions_revision': '0'},
        pricingUpdates: updates.stream,
      );
      addTearDown(controller.dispose);
      controller.setPreloadedRoute(
        pickup: place('Start', 1, 1),
        pickupLabel: 'Start',
        dropoff: place('End', 2, 2),
        dropoffLabel: 'End',
        route: routeFixture(),
      );
      await controller.refreshQuote();
      expect(calls, 1);
      controller.selectRideOption(controller.state.rideOptions.first);
      expect(await controller.prepareQuoteForConfirmation(), isTrue);
      updates.add(const {'version': 2});
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(calls, 1, reason: 'confirmation owns the frozen quote');
      controller.releaseQuoteConfirmation();
      updates.add(const {'version': 2});
      updates.add(const {'version': 2});
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(calls, 2, reason: 'a burst produces one refreshed quote');
    });

    test('quote failure stays unknown and cannot be confirmed', () async {
      final controller = RiderTripController(
        quoteFetcher: (_) async => throw Exception('offline'),
        revisionFetcher: () async =>
            {'pricing_version': 1, 'promotions_revision': '0'},
        pricingUpdates: const Stream.empty(),
      );
      addTearDown(controller.dispose);
      controller.setPreloadedRoute(
        pickup: place('Start', 1, 1),
        pickupLabel: 'Start',
        dropoff: place('End', 2, 2),
        dropoffLabel: 'End',
        route: routeFixture(),
      );
      await controller.refreshQuote();
      expect(controller.state.quote, isNull);
      expect(controller.state.quoteFailed, isTrue);
      expect(controller.state.rideOptions.every((o) => !o.hasServerPrice), isTrue);
      controller.selectRideOption(controller.state.rideOptions.first);
      expect(await controller.prepareQuoteForConfirmation(), isFalse);
    });
  });
}
