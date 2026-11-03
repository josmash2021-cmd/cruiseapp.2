import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03: "el sonido de la app al conectarse quiero que suene
/// justamente cuando me pongo online, pero si me desconecto antes que
/// termine el audio se cortará; y al igual con una oferta: si le doy
/// rechazar o acepto la oferta antes que termine de sonar, se corta".
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final ctl = read('lib/screens/driver/driver_online_controller.dart');
  final ns = read('lib/services/notification_service.dart');

  String body(String src, String sig) {
    final at = src.indexOf(sig);
    expect(at, isNonNegative, reason: sig);
    return src.substring(at, at + 1500);
  }

  test('the chime goes out with the online flip, before any await', () {
    final enter = ctl.substring(
        ctl.indexOf('  Future<void> _enterOnlineMode({bool resuming = false}) async {'));
    final flip = enter.indexOf('_driverOnline = true;');
    final chime = enter.indexOf('NotificationService.playOnlineChime();');
    final firstAwait = enter.indexOf('await ');
    expect(flip, isNonNegative);
    expect(chime, greaterThan(flip));
    expect(chime, lessThan(firstAwait));
    expect(
        RegExp(r'NotificationService\.playOnlineChime\(\);')
            .allMatches(ctl)
            .length,
        1,
        reason: 'one chime per GO');
  });

  test('going offline, accepting or rejecting cuts the cue', () {
    expect(body(ctl, '  Future<void> _exitOnlineMode() async {'),
        contains('NotificationService.stopCues();'));
    expect(body(ctl, '  Future<void> _acceptOffer(Map<String, dynamic> r,'),
        contains('NotificationService.stopCues();'));
    expect(body(ctl, '  Future<void> _rejectOffer(Map<String, dynamic> r,'),
        contains('if (byDriver) NotificationService.stopCues();'));
    expect(read('lib/screens/driver/driver_online_screen.dart'),
        contains('_rejectOffer(_pendingOffers[idx], byDriver: true);'));
  });

  test('a cut cue plays no more repeats and gives the music back', () {
    final stop = body(ns, '  static void stopCues() {');
    expect(stop, contains('_cueGen++;'));
    expect(stop, contains("_quietly(_offerPlayer.stop(), 'cue stop');"));
    expect(stop, contains("_quietly(restoreAfterOfferCue(), 'unduck');"));
    final offer = body(ns, '  static void playOfferSound() {');
    expect(offer, contains('final gen = _cueGen;'));
    expect(offer, contains('if (gen != _cueGen) return;'));
  });
}
