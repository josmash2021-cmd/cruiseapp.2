import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cruise_app/map/nav_dest_markers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-04, with Lyft photos: a reservation's pickup is a pill over
/// a dot ("Scheduled"); an ordinary one is the gold pin. Both images are
/// anchored at their CENTRE, which must be the exact spot — the ring's
/// white middle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> fakePin() async {
    // A 160 x 147 gold teardrop stand-in, tip at the bottom centre.
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    c.drawCircle(const Offset(80, 64), 60, Paint()..color = const Color(0xFFD4A800));
    c.drawPath(
        Path()
          ..moveTo(60, 110)
          ..lineTo(100, 110)
          ..lineTo(80, 147)
          ..close(),
        Paint()..color = const Color(0xFFD4A800));
    final img = await r.endRecording().toImage(160, 147);
    return (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
  }

  Future<(int, int, Color)> centre(Uint8List png) async {
    final img = (await (await ui.instantiateImageCodec(png)).getNextFrame())
        .image;
    final data = (await img.toByteData())!;
    final x = img.width ~/ 2;
    final y = img.height ~/ 2;
    final i = (y * img.width + x) * 4;
    return (
      img.width,
      img.height,
      Color.fromARGB(data.getUint8(i + 3), data.getUint8(i),
          data.getUint8(i + 1), data.getUint8(i + 2)),
    );
  }

  test('the pin stands on the ring: the image centre is the spot', () async {
    final pin = await fakePin();
    for (final halo in [true, false]) {
      final (w, h, c) = await centre(await pinOnGround(pin, halo: halo));
      expect(c, Colors.white, reason: 'halo=$halo: centre must be the ring');
      expect(h, greaterThan(147 * 2), reason: 'the pin fits above the spot');
      expect(w, greaterThanOrEqualTo(160));
    }
  });

  test('the pickup stop ring is centred on the spot', () async {
    final pin = await fakePin();
    final (_, _, c) = await centre(await stopRingMarker(160, pin));
    expect(c, Colors.white);
  });

  test('the reservation is the ring under the pill, centred on the spot',
      () async {
    final pin = await fakePin();
    final (_, _, c) = await centre(await scheduledPickupMarker('Reservado', 160, pin));
    expect(c, Colors.white);
  });

  test('the nav draws them at the centre anchor', () {
    final nav = File('lib/screens/driver/driver_nav_view.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final dest = nav.substring(nav.indexOf('Future<void> _drawDestPin() async {'));
    final body = dest.substring(0, dest.indexOf('unawaited(_drawStopPin());'));
    expect(body, contains(': await stopRingMarker(unit, pin);'),
        reason: 'the pickup is the ring alone: the gold pin is the rider');
    expect(body, contains('bytes = await pinOnGround(pin);'));
    expect(body, contains('final stop = _stopPoint;'),
        reason: 'the ring is where the line ends, not the raw address');
    expect(body, contains('iconAnchor: mapbox.IconAnchor.CENTER,'));
    expect(body, isNot(contains('IconAnchor.BOTTOM')));
  });
}
