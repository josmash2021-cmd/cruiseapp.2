// The choose-a-ride map (owner 2026-11-09): "la línea más delgada, los
// label más al lado de sus pines y debajo de los pines los círculos de
// pickup y dropoff".
//  - the web route line is 2.5 wide, the same as the phone's (it drew 5);
//  - pickup, dropoff and stop pins stand on the ground ring (pinOnGround,
//    the navigation's ring) and anchor at its centre, on both platforms;
//  - the floating labels sit ~5 px off the visible pin, not ~22.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final map = _read('lib/screens/ride_request_map.dart');

  test('the route line is 2.5 wide on web and phone', () {
    expect(RegExp(r'width: 5\b').hasMatch(map), isFalse);
    expect(RegExp(r"color: '#F0CA3E',\s*width: 2\.5").allMatches(map).length,
        3);
    expect(RegExp(r'lineWidth: 2\.5').allMatches(map).length, 2);
  });

  test('the pins stand on their ground ring, centred on the spot', () {
    final ctrl = _read('lib/screens/ride_request_controller.dart');
    expect(ctrl.contains('_goldPinIcon = await pinOnGround('), isTrue);
    expect(ctrl.contains('_goldDropoffPinIcon = await pinOnGround('), isTrue);
    final standalone = map.substring(
        map.indexOf('Future<(Uint8List, Uint8List)?> _buildStandalonePin('),
        map.indexOf('Future<Uint8List?> _buildAirportIconBytes('));
    expect('pinOnGround('.allMatches(standalone).length, 2,
        reason: 'the airport icon stands on the ring too');
    expect(map.contains('IconAnchor.BOTTOM,'), isFalse);
    expect('iconAnchor: mapbox.IconAnchor.CENTER,'.allMatches(map).length, 6);
    // Web: same ring, centred.
    expect(map.contains('final bytes = await pinOnGround(pin);'), isTrue);
    expect(map.contains("anchor: 'bottom'"), isFalse);
    expect("anchor: 'center');".allMatches(map).length, 2);
  });

  test('the labels sit right beside their pins', () {
    final widgets = _read('lib/screens/ride_request_widgets.dart');
    expect(widgets.contains('const double pinOnScreenHalfWidth = 13.0;'),
        isTrue);
    expect(widgets.contains('const double sideGap = 5.0;'), isTrue);
  });
}
