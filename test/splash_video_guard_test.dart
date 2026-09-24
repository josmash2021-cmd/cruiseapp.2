import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the video splash (user spec 2026-09-19): the intro clip
/// "Let's Get You There" (assets/videos/splash_intro.mp4) replaced the
/// CRUISE letter animation.
///
///   1. The clip plays muted and LOOPS — a slow destination resolve must
///      never freeze on the last frame.
///   2. Navigation waits for one full playthrough, hard-capped at 8 s, AND
///      for destination + preload — no black gap, no hostage splash.
///   3. The logged-in fast path still skips the intro entirely.
///   4. The routing logic (destination computation, token validation,
///      first-run permissions) is untouched.
void main() {
  final src = File('lib/screens/splash_screen.dart').readAsStringSync();

  test('intro clip: muted, looping, first-playthrough signal', () {
    expect(src.contains('assets/videos/splash_intro.mp4'), isTrue);
    expect(src.contains('setVolume(0)'), isTrue);
    expect(src.contains('setLooping(true)'), isTrue,
        reason: 'looping keeps the screen alive if init runs long');
    expect(src.contains('_firstLoopDone.complete()'), isTrue);
  });

  test('navigation waits for the playthrough, hard-capped at 8 s', () {
    final cap = RegExp(
            r'_firstLoopDone\.future\.timeout\(\s*const Duration\(seconds: 8\)')
        .hasMatch(src);
    expect(cap, isTrue,
        reason: 'a missing/corrupt clip must never hold the app hostage');
    final wait = RegExp(
            r'Future\.wait\(\[\s*destinationFuture,\s*preloadFuture,\s*firstLoop,')
        .hasMatch(src);
    expect(wait, isTrue,
        reason: 'destination + preload ride the same wait — no black gap');
  });

  test('logged-in fast path skips the intro', () {
    final fastPath = src.indexOf('if (loggedIn) {');
    final videoWait = src.indexOf('_firstLoopDone.future');
    expect(fastPath, isNonNegative);
    expect(videoWait, greaterThan(fastPath),
        reason: 'the video wait must live AFTER the logged-in early return');
  });

  test('session boot never even INITIALIZES the intro clip (2026-09-23)', () {
    final initState = src.substring(
        src.indexOf('void initState() {'),
        src.indexOf('Future<void> _initVideo() async {'));
    expect(initState.contains('_initVideo('), isFalse,
        reason: 'with an active session the splash must not even TRY to '
            'appear — no clip init, no play glyph over home');
    final fastReturn = src.indexOf('if (loggedIn) {');
    final initCall = src.indexOf('unawaited(_initVideo())');
    expect(initCall, greaterThan(fastReturn),
        reason: 'the clip initializes strictly on the logged-out path, '
            'after the session check');
  });

  test('routing logic untouched', () {
    expect(src.contains('_computeDestination'), isTrue);
    expect(src.contains('_validateTokenInBackground'), isTrue);
    expect(src.contains('_requestFirstRunPermissions'), isTrue);
    expect(src.contains('UserSession.isLoggedInLocal()'), isTrue);
  });

  test('the hand-off to the next screen is a 700 ms crossfade', () {
    expect(
        src.contains(
            'transitionDuration: const Duration(milliseconds: 700)'),
        isTrue,
        reason: 'the clip ends fading to black and the next screen fades '
            'IN over it — one continuous reveal, no cut');
    expect(src.contains('Curves.easeInOut'), isTrue);
  });
}
