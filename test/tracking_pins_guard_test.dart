import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider tracking map's pickup/dropoff pins
/// (user reports 2026-09-19):
///
///   1. "Los pines no aparecen" — the both-or-nothing pinsReady gate kept
///      BOTH pins off the map when a single render failed. Each pin earns
///      its own place now.
///   2. "El pin de pickup se quita con pop out al empezar el viaje" — the
///      pop-out existed but fired into the void whenever the Find-My
///      overlay owned the one native surface at trip start, and the fresh
///      annotations instance on remount then RESURRECTED the pin
///      (retirement doesn't cross instances). After loadPins on a remounted
///      map with the trip underway, the view pops the just-recreated pin
///      where the rider actually sees it.
void main() {
  final annot =
      File('lib/map/tracking_map_annotations.dart').readAsStringSync();
  final view =
      File('lib/widgets/tracking/tracking_map_view.dart').readAsStringSync();

  group('per-pin readiness — one failed render never blocks both pins', () {
    test('per-pin getters exist and gate the static pass', () {
      expect(annot.contains('bool get hasPickupPin'), isTrue);
      expect(annot.contains('bool get hasDropoffPin'), isTrue);
      expect(
          view.contains(
              '(_mapAnnotations!.hasPickupPin || _mapAnnotations!.hasDropoffPin)'),
          isTrue,
          reason: 'the both-or-nothing hasPins gate kept the dropoff pin '
              'off the map when the pickup render failed — per-pin now');
      expect(
          view.contains(
              '(_pickupPinBytes != null || _dropoffPinBytes != null)'),
          isTrue,
          reason: 'same per-pin discipline on the legacy path');
    });
  });

  group('pickup pin pops out visibly at trip start', () {
    test('the pop retires the pin even when there is nothing to animate', () {
      final body = annot.substring(
          annot.indexOf('Future<void> popOutPickupPin() async {'),
          annot.indexOf('Future<void> popOutPickupPin() async {') + 400);
      expect(body.contains('_pickupRetired = true'), isTrue,
          reason: 'retirement lands before the early return so the pin can '
              'never be recreated afterwards in this instance');
    });

    test('a remounted map with the trip underway pops the recreated pin', () {
      // The recreation call in _onMapCreated is the one with the .then
      // callback (the _loadPins() copy has none).
      final start = view.indexOf(").then((_) async {");
      expect(start, isNonNegative);
      final body = view.substring(start, start + 1600);
      expect(body.contains('await _updateAnnotations();'), isTrue,
          reason: 'pins are created first — the pop needs the pin to exist');
      expect(body.contains('_TrackPhase.onTrip'), isTrue);
      expect(body.contains('_TrackPhase.nearDestination'), isTrue);
      expect(body.contains('popOutPickupPin()'), isTrue,
          reason: 'the Find-My owned the surface at trip start, so the pop '
              'fired into the void — replay it where the rider sees it');
      // The pop must come AFTER the creation in this callback.
      final created = body.indexOf('await _updateAnnotations();');
      final popped = body.indexOf('popOutPickupPin()');
      expect(popped, greaterThan(created));
    });
  });
}
