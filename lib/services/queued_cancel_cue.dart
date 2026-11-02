import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'api_service.dart';
import 'audio_session_config.dart';
import 'prefs_cache.dart';

/// The "queued ride cancelled" cue (owner design 2026-11-02): two soft
/// descending notes, deeper than a chime.
///
/// Served from the backend (`/static/queued_cancel.wav`) because an OTA
/// patch cannot add assets, and cached on the phone the moment a ride is
/// queued ([warm]) — so when the cancel lands the cue plays at once instead
/// of after a download.
class QueuedCancelCue {
  QueuedCancelCue._();

  static AudioPlayer? _player;

  static String get _url =>
      '${ApiService.currentBaseUrl}/static/queued_cancel.wav';

  /// Downloads the cue into the cache. Fire-and-forget.
  static Future<void> warm() async {
    if (kIsWeb) return;
    try {
      await DefaultCacheManager().getSingleFile(_url);
    } catch (e) {
      debugPrint('[QueuedCancelCue] warm failed: $e');
    }
  }

  /// Plays the cue at the driver's sound volume; silent when they turned
  /// notification sounds off. Never throws.
  static Future<void> play() async {
    try {
      final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
      final volume = prefs.getDouble('sound_volume') ?? 0.8;
      if (!(prefs.getBool('notif_sounds') ?? true) || volume <= 0) return;
      // Before any player touches the session: never stop the driver's
      // music or the navigation voice.
      await ensureNonInterruptingAudio();
      final Source source;
      if (kIsWeb) {
        source = UrlSource(_url);
      } else {
        final file = await DefaultCacheManager().getSingleFile(_url);
        source = DeviceFileSource(file.path);
      }
      final p = _player ??= AudioPlayer();
      await p.setVolume(volume);
      await p.play(source);
    } catch (e) {
      debugPrint('[QueuedCancelCue] play failed: $e');
    }
  }
}
