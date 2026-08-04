import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Configure the app's audio to share the phone rather than take it over.
///
/// audioplayers defaults to the iOS category `playback` with no options, and
/// to Android audio focus `gain`. Both mean "this app is now the only thing
/// the user is listening to": iOS stops the other app's audio outright,
/// Android makes it pause. Simply arming our offer cue was enough to trigger
/// it — so opening Cruise stopped Spotify, Apple Music, a podcast, a video.
/// On the passenger's phone that happened for a sound they will never hear.
///
/// `playback` stays, because a ride offer has to be audible with the ringer
/// switch on silent — that is the entire point of the cue.
///
/// Ducking is TRANSIENT, not ambient (user spec 2026-08-04): the resting
/// state is `mixWithOthers` alone, so music and video play at full volume
/// the whole time the app is open. `duckOthers` is applied only for the
/// seconds the offer cue is actually sounding — [duckForOfferCue] right
/// before play, [restoreAfterOfferCue] when the cue ends. With `duckOthers`
/// in the resting category, iOS dips other audio for as long as our session
/// is active, and the pre-warmed offer player keeps it active — that was
/// the permanent "volume drop" drivers heard while just driving with the
/// app open.
///
/// Must run before any player touches the session: on iOS the category is
/// applied when the session is activated, and the first activation is what
/// interrupts. [ensureNonInterruptingAudio] is idempotent and cheap to
/// await, so every entry point that is about to create or play an
/// [AudioPlayer] calls it first — this cannot live in main() alone, because
/// notification setup is deferred until after runApp and the home screen
/// preloads its sounds before that finishes.
Future<void> ensureNonInterruptingAudio() {
  return _configured ??= _apply(duck: false);
}

Future<void>? _configured;

/// Dip other audio (music, video) while the offer cue plays. Call right
/// before starting the cue; pair with [restoreAfterOfferCue].
Future<void> duckForOfferCue() async {
  if (kIsWeb) return; // browser mixes on its own; no session categories
  await _apply(duck: true);
}

/// Back to full-volume mixing once the cue is done. Re-applying the
/// category without `duckOthers` is what ends the dip on iOS.
Future<void> restoreAfterOfferCue() async {
  if (kIsWeb) return;
  await _apply(duck: false);
}

Future<void> _apply({required bool duck}) async {
  try {
    await AudioPlayer.global.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            if (duck) AVAudioSessionOptions.duckOthers,
          },
        ),
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          // Resting: no focus request at all — other audio untouched.
          // Cue: transient focus that lets the OS dip the music briefly.
          audioFocus: duck
              ? AndroidAudioFocus.gainTransientMayDuck
              : AndroidAudioFocus.none,
        ),
      ),
    );
  } catch (e) {
    // Never fatal: worst case we are back to the old behaviour for this
    // launch, and a failed audio setting must not take the app down with it.
    debugPrint('[Audio] could not set audio context (duck=$duck): $e');
    if (!duck) _configured = null; // let a later caller try again
  }
}
