// Owner spec 2026-11-01:
//  - tapping a trip callout must open the offer card with its route, like a
//    ring (it used to do nothing: the claim card only rendered inside the
//    offer stack, which never mounts with no offer);
//  - new trips on the map ease the follow camera out once, arrow centred;
//  - the zone recentre in a state with no zones frames Pelham, Hoover and
//    Birmingham.
import 'dart:io';
import 'dart:math' as math;

import 'package:cruise_app/map/map_callout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final row = <String, dynamic>{
    'trip_id': 783,
    'pickup_address': 'Pelham Civic Complex',
    'dropoff_address': 'Riverchase Galleria',
    'pickup_lat': 33.2962,
    'pickup_lng': -86.8076,
    'dropoff_lat': 33.3779,
    'dropoff_lng': -86.8101,
    'driver_earnings': 11.04,
    'vehicle_type': 'comfort',
    'rider_name': 'Michael',
    'rider_rating': 4.9,
    'rider_is_new': false,
    'rider_rides_count': 3,
  };

  group('boardOfferFrom', () {
    test('a board row becomes an offer card the reject path cannot send', () {
      final o = boardOfferFrom(row)!;
      expect(o[kBoardTripKey], 783);
      expect(o['offer_id'], 'board-783');
      expect(int.tryParse(o['offer_id'] as String), isNull,
          reason: 'never parses as a real offer id');
      expect(o['fare'], 11.04, reason: "the driver's pay, like a ring");
      expect(o['dropoff_lat'], 33.3779);
      expect(o['rider_ratings_count'], 3);
    });

    test('no route without the far end (older server)', () {
      expect(boardOfferFrom({...row}..remove('dropoff_lat')), isNull);
      expect(boardOfferFrom({...row}..remove('trip_id')), isNull);
    });
  });

  group('boardRevealZoom', () {
    const phone = Size(390, 844);
    test('a close pickup keeps the working zoom', () {
      expect(boardRevealZoom(latDeg: 33.3, farthestM: 150, viewport: phone),
          kSearchFollowZoom);
    });

    test('a pickup 3 km away lands on screen, arrow still centred', () {
      final z = boardRevealZoom(latDeg: 33.3, farthestM: 3000, viewport: phone);
      expect(z, lessThan(kSearchFollowZoom));
      final mPerPx = 40075016.686 *
          math.cos(33.3 * math.pi / 180) /
          (512 * math.pow(2, z));
      expect(3000 / mPerPx,
          closeTo(phone.width / 2 - kBoardRevealMarginPx, 0.5));
    });

    test('never past the floor', () {
      expect(boardRevealZoom(latDeg: 33.3, farthestM: 80000, viewport: phone),
          kBoardRevealMinZoom);
    });
  });

  group('wiring', () {
    final callouts =
        File('lib/screens/driver/driver_online_callouts.dart').readAsStringSync();
    final ctrl =
        File('lib/screens/driver/driver_online_controller.dart').readAsStringSync();
    final widgets =
        File('lib/screens/driver/driver_online_widgets.dart').readAsStringSync();
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    String body(String src, String head, [int len = 1600]) {
      final i = src.indexOf(head);
      expect(i, greaterThanOrEqualTo(0), reason: head);
      return src.substring(i, math.min(src.length, i + len));
    }

    test('the tap opens the trip as the offer card and draws its route', () {
      final tap = body(callouts, 'void _onTripCalloutTap(int tripId)');
      expect(tap, contains('boardOfferFrom('));
      expect(tap, contains('_pendingOffers = [offer]'));
      expect(tap, contains('_autoTriggerRoutePreview(offer)'));
    });

    test('closing a board card sends nothing and shows no "declined"', () {
      final reject = body(ctrl, 'Future<void> _rejectOffer(', 500);
      final branch = reject.indexOf('if (_isBoardOffer(r))');
      expect(branch, greaterThan(0));
      expect(reject.indexOf('_closeBoardOffer()'), greaterThan(branch));
      expect(reject.indexOf('rejectRideOffer'), -1,
          reason: 'the board branch returns before any server call');
    });

    test('accept on a board card claims it off the board', () {
      final accept = body(ctrl, 'Future<void> _acceptOffer(', 700);
      expect(accept, contains('_claimBoardOffer(r)'));
      expect(body(ctrl, 'Future<void> _claimBoardOffer('),
          contains("_claimTrip({'trip_id': r[kBoardTripKey]})"));
    });

    test('a board card has no running clock', () {
      expect(widgets,
          contains('active: isVisible && offer[kBoardTripKey] == null'));
    });

    test('the board card survives polls; a real ring replaces it', () {
      final merge = body(ctrl, 'if (_pendingOffers.any(_isBoardOffer))', 700);
      expect(merge, contains('filtered = _pendingOffers.where(_isBoardOffer)'));
      expect(merge, contains('_closeBoardOffer(restoreCamera: false)'));
    });

    test('new board trips ease the follow zoom out, once per trip', () {
      expect(ctrl, contains('_maybeRevealBoardTrips(trips)'));
      expect(ctrl, contains('final zoomTarget = _searchFollowZoom;'));
      final reveal = body(callouts, 'void _maybeRevealBoardTrips(', 1800);
      expect(reveal, contains('_revealedBoardTripIds'));
      expect(reveal, contains('_cameraFollowing'));
    });

    test('no zones in Alabama: the recentre frames Pelham–Hoover–Birmingham',
        () {
      expect(map, contains("'AL': [-86.92, 33.26, -86.70, 33.56]"));
      bool inside(double lat, double lng) =>
          lng >= -86.92 && lng <= -86.70 && lat >= 33.26 && lat <= 33.56;
      expect(inside(33.5186, -86.8104), isTrue, reason: 'Birmingham');
      expect(inside(33.4054, -86.8114), isTrue, reason: 'Hoover');
      expect(inside(33.2856, -86.8100), isTrue, reason: 'Pelham');
      expect(body(map, 'Future<bool> _fitHomeZones('),
          contains('kStateMetroFrames[state]'));
    });
  });
}
