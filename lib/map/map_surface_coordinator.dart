import 'dart:async';

import 'package:flutter/widgets.dart';

/// Guarantees that at most one native Mapbox surface is alive, by handoff
/// instead of by hope.
///
/// Two live `MapWidget`s crash iOS. The app has eight of them across the
/// driver flow and they overlap constantly — home sits under online, online
/// pushes the trip screen, the trip screen replaces itself with a new online
/// screen at the end. The previous defence was a pair of timers on each
/// side of every transition: the outgoing screen dropped its surface at
/// `kTripHandoffMs + 200`, the incoming one mounted at `kTripHandoffMs +
/// 250`, and the screen underneath suspended 600 ms after being covered.
///
/// Those numbers only work if tearing down a PlatformView takes less than
/// the 50 ms between them. It does not, and it especially does not during a
/// route transition, which is exactly when every one of these handoffs
/// happens — the platform thread is busiest at the precise moment the
/// margin is thinnest. That is why this crash was fixed twice and came
/// back twice: each fix moved the numbers, and moving the numbers cannot
/// fix a race, it can only change which phones lose it.
///
/// Here the incoming screen does not guess. It asks for the surface, the
/// holder is told to let go, and the request completes only once the holder
/// confirms its `MapWidget` is out of the tree. No margin to tune, and
/// nothing to re-tune when a transition duration changes.
///
/// Requests are serialised, so two screens mounting in the same frame hand
/// off in order rather than both concluding the coast is clear.
class MapSurfaceCoordinator {
  MapSurfaceCoordinator._();

  static final MapSurfaceCoordinator instance = MapSurfaceCoordinator._();

  /// Visible for tests: a fresh coordinator with no global state.
  @visibleForTesting
  factory MapSurfaceCoordinator.forTest() = MapSurfaceCoordinator._;

  /// How long a holder gets to confirm before we take the surface anyway.
  ///
  /// A holder that never answers — disposed mid-revoke, an exception in its
  /// release path — must not leave the incoming screen with a permanently
  /// blank map. Losing the guarantee for one transition is bad; a driver
  /// staring at an empty rectangle for the rest of the trip is worse.
  static const Duration revokeTimeout = Duration(milliseconds: 1500);

  String? _owner;
  Future<void> Function()? _onRevoke;

  /// Serialises acquisitions. Each request chains onto the previous one, so
  /// a burst of mounts in one frame is handed off one at a time.
  Future<void> _queue = Future<void>.value();

  /// Who currently holds the surface, or null. Diagnostics and tests.
  String? get currentOwner => _owner;

  /// Wait until it is safe for [owner] to mount its `MapWidget`.
  ///
  /// [onRevoke] must remove the widget from the tree and complete only once
  /// that has actually rendered — see [surfaceRemoved] for the helper that
  /// does the waiting. It is kept so a later acquirer can evict [owner].
  Future<void> acquire({
    required String owner,
    required Future<void> Function() onRevoke,
  }) {
    final result = _queue.then((_) => _handoff(owner, onRevoke));
    // Keep the chain alive even if one handoff blows up, or every later
    // acquire inherits the error and no map ever mounts again.
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _handoff(
    String owner,
    Future<void> Function() onRevoke,
  ) async {
    if (_owner != null && _owner != owner) {
      final revoke = _onRevoke;
      debugPrint('[MapSurface] $owner requesting — revoking $_owner');
      if (revoke != null) {
        try {
          await revoke().timeout(revokeTimeout);
        } on TimeoutException {
          debugPrint(
            '[MapSurface] $_owner did not release within '
            '${revokeTimeout.inMilliseconds}ms — taking the surface anyway',
          );
        } catch (e) {
          debugPrint('[MapSurface] $_owner failed to release: $e');
        }
      }
    }
    _owner = owner;
    _onRevoke = onRevoke;
    debugPrint('[MapSurface] $owner holds the surface');
  }

  /// Give the surface up voluntarily — from `dispose`, or when a screen
  /// drops its map for its own reasons.
  ///
  /// Only clears the holder if [owner] still is one: a screen that was
  /// already evicted must not wipe out its successor's claim on the way out.
  void release(String owner) {
    if (_owner != owner) return;
    _owner = null;
    _onRevoke = null;
    debugPrint('[MapSurface] $owner released');
  }
}

/// Wait until a `MapWidget` removed in the current build is really gone.
///
/// `setState` only schedules the rebuild. The element is unmounted during
/// the next frame and the platform view is disposed over the channel after
/// that, so returning as soon as the flag flips would confirm a release that
/// has not happened — the exact false confirmation the timers used to make.
///
/// Two frames cover the rebuild and the detach; the short settle after them
/// covers the disposal crossing to the platform thread. It is a delay, but
/// unlike the ones it replaces it runs *after* the teardown has been
/// ordered rather than in parallel with it, so it is a margin on top of a
/// guarantee instead of a substitute for one.
Future<void> surfaceRemoved() async {
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 120));
}
