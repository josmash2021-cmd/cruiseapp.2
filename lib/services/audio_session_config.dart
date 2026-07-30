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
/// switch on silent — that is the entire point of the cue. What changes is
/// that `mixWithOthers` makes it non-exclusive and `duckOthers` dips the
/// music for the length of the beep instead of ending it. Android's
/// gainTransientMayDuck is the same bargain.
///
/// Must run before any player touches the session: on iOS the category is
/// applied when the session is activated, and the first activation is what
/// interrupts. [ensureNonInterruptingAudio] is idempotent and cheap to
/// await, so every entry point that is about to create or play an
/// [AudioPlayer] calls it first — this cannot live in main() alone, because
/// notification setup is deferred until after runApp and the home screen
/// preloads its sounds before that finishes.
Future<void> ensureNonInterruptingAudio() {
  return _configured ??= _configure();
}

Future<void>? _configured;

Future<void> _configure() async {
  try {
    await AudioPlayer.global.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.duckOthers,
          },
        ),
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );
  } catch (e) {
    // Never fatal: worst case we are back to the old behaviour for this
    // launch, and a failed audio setting must not take the app down with it.
    debugPrint('[Audio] could not set a non-interrupting audio context: $e');
    _configured = null; // let a later caller try again
  }
}
