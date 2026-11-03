import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'api_service.dart';
import 'audio_session_config.dart';
import 'prefs_cache.dart';

/// "Tu pasajero tiene una parada en el camino" / "Your rider has a stop
/// along the way" (voices picked by the owner, 2026-11-03) — spoken the
/// moment the driver slides to pick up a rider whose trip has a stop (owner
/// 2026-11-03), in the app's language, which follows the phone's (main.dart).
///
/// Served from the backend (`/static/voice/rider_stop_{es,en}.mp3`) like
/// [QueuedCancelCue] — an OTA patch cannot add assets — and cached on the
/// phone as soon as the trip is known to have a stop ([warm]).
class RiderStopVoice {
  RiderStopVoice._();

  static AudioPlayer? _player;

  static String _url(bool es) =>
      '${ApiService.currentBaseUrl}/static/voice/rider_stop_${es ? 'es' : 'en'}.mp3';

  /// Downloads both clips into the cache. Fire-and-forget.
  static Future<void> warm() async {
    if (kIsWeb) return;
    for (final es in const [true, false]) {
      try {
        await DefaultCacheManager().getSingleFile(_url(es));
      } catch (e) {
        debugPrint('[RiderStopVoice] warm failed: $e');
      }
    }
  }

  /// Says it at the driver's sound volume, the music dipped while it
  /// speaks; silent when they turned the app's sounds off. Never throws.
  static Future<void> play({required bool es}) async {
    try {
      final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
      final volume = prefs.getDouble('sound_volume') ?? 0.8;
      if (!(prefs.getBool('notif_sounds') ?? true) || volume <= 0) return;
      await ensureNonInterruptingAudio();
      final Source source;
      if (kIsWeb) {
        source = UrlSource(_url(es));
      } else {
        // On time or not at all (owner 2026-11-03: "justamente en el
        // momento"): a line that lands seconds after the pickup only
        // confuses. The clip is normally on the phone already ([warm]);
        // if not, it gets 1.5 s to arrive, and the download carries on
        // for the next trip.
        final cached = await DefaultCacheManager().getFileFromCache(_url(es));
        final file = cached?.file ??
            await DefaultCacheManager()
                .getSingleFile(_url(es))
                .timeout(const Duration(milliseconds: 1500));
        source = DeviceFileSource(file.path);
      }
      final p = _player ??= AudioPlayer();
      await p.setVolume(volume);
      await duckForOfferCue();
      // Music back to full volume when the sentence ends (or after 6 s if
      // the end never reports).
      unawaited(p.onPlayerComplete.first
          .timeout(const Duration(seconds: 6), onTimeout: () {})
          .whenComplete(restoreAfterOfferCue));
      await p.play(source);
    } catch (e) {
      debugPrint('[RiderStopVoice] play failed: $e');
      unawaited(restoreAfterOfferCue());
    }
  }
}
