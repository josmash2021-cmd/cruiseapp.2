import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: "cuando recoja al rider y le dé deslizar para recoger
/// dirá tu pasajero tiene una parada — si tienen el teléfono en español lo
/// dirá en español y si lo tienen en inglés lo dirá en inglés".
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('both voice clips ship with the backend', () {
    for (final lang in ['es', 'en']) {
      final f = File('backend/static/voice/rider_stop_$lang.mp3');
      expect(f.existsSync(), isTrue, reason: f.path);
      expect(f.lengthSync(), greaterThan(10000), reason: f.path);
    }
    expect(read('lib/services/rider_stop_voice.dart'),
        contains("'\${ApiService.currentBaseUrl}/static/voice/rider_stop_\${es ? 'es' : 'en'}.mp3'"));
  });

  test('the pickup slide says it, once, only when the trip has a stop', () {
    final src = read('lib/screens/driver/driver_trip_accept_screen.dart');
    final at = src.indexOf('  void _startRideConfirmed() {');
    expect(at, isNonNegative);
    final body = src.substring(at, src.indexOf('Future.delayed(', at));
    expect(body,
        contains('if (_stopLatLng != null && !_stopDeparted && !_stopVoiceSaid) {'));
    expect(body, contains("es: Localizations.localeOf(context).languageCode == 'es'"));
    // Both pickup paths end here: the nav panel's slide and the sheet's.
    expect(src, contains('onSlidePickUp: _startRideConfirmed,'));
  });

  test('it speaks only with the app sounds on, and gives the music back', () {
    final v = read('lib/services/rider_stop_voice.dart');
    expect(v, contains("if (!(prefs.getBool('notif_sounds') ?? true) || volume <= 0) return;"));
    expect(v, contains('await duckForOfferCue();'));
    expect(v, contains('.whenComplete(restoreAfterOfferCue));'));
  });

  test('on time or not at all: from the cache, or 1.5 s to download', () {
    final v = read('lib/services/rider_stop_voice.dart');
    expect(v, contains('await DefaultCacheManager().getFileFromCache(_url(es));'));
    expect(v, contains('.timeout(const Duration(milliseconds: 1500));'));
    // Fire-and-forget at the slide, before the ride-start work.
    final src = read('lib/screens/driver/driver_trip_accept_screen.dart');
    final at = src.indexOf('  void _startRideConfirmed() {');
    final play = src.indexOf('unawaited(RiderStopVoice.play(', at);
    expect(play, greaterThan(at));
    expect(play, lessThan(src.indexOf('Future.delayed(', at)));
  });
}
