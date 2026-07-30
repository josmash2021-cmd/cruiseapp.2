import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// A position stream that comes back on its own.
///
/// Every `Geolocator.getPositionStream(...).listen(...)` in this app used to
/// be a one-shot: five of the six had no `onError` and none had an `onDone`.
/// A geolocator stream ends for reasons that have nothing to do with the app
/// being wrong — the OS revokes or downgrades the permission, the user
/// toggles location services, the platform channel throws once, iOS tears
/// the manager down under memory pressure. When that happened the
/// subscription completed and **nothing ever subscribed again**. The driver
/// went silent for the rest of the shift and the passenger's car froze
/// mid-street, with no error anywhere to say so.
///
/// Three independent things bring it back, because in practice they fail in
/// different ways:
///
///  * **onDone / onError → resubscribe with backoff.** The stream told us it
///    is finished. Straightforward.
///  * **A staleness watchdog.** The nastier failure is the stream that stays
///    open and stops delivering — the OS quietly stops feeding it and no
///    callback ever fires. Nothing can detect that except the absence of
///    data, so [staleAfter] of silence forces a fresh subscription.
///  * **[onAppResumed].** Coming back from background is the single most
///    likely moment to find a dead stream, and it is the one moment we know
///    about for free.
///
/// The backoff resets on every real fix, so a stream that recovers quickly
/// keeps retrying quickly, and one that is genuinely denied settles at
/// [retryMax] instead of spinning.
class ResilientPositionStream {
  ResilientPositionStream({
    required this.settings,
    required this.onPosition,
    this.label = 'gps',
    this.staleAfter = const Duration(seconds: 25),
    this.retryBase = const Duration(seconds: 2),
    this.retryMax = const Duration(seconds: 30),
    this.onFirstFixAfterGap,
  });

  /// Settings for the native stream. Reused verbatim on every resubscribe,
  /// so background flags survive a restart — a stream that came back as
  /// foreground-only would fail again the moment the screen locked.
  final LocationSettings settings;

  final void Function(Position position) onPosition;

  /// Prefix for the debug logs, so several streams can be told apart.
  final String label;

  /// How long the stream may stay silent before it is assumed dead.
  ///
  /// Has to be comfortably longer than the gap a stationary driver produces:
  /// these streams use a distance filter, so a car at a light legitimately
  /// emits nothing at all. 25 s is long enough for a red light and short
  /// enough that a passenger watching a frozen car does not give up first.
  final Duration staleAfter;

  final Duration retryBase;
  final Duration retryMax;

  /// Fired when a fix arrives after the stream had to be rebuilt. Lets the
  /// caller re-announce presence (heartbeat, RTDB write) rather than wait
  /// for its own throttle to come round.
  final void Function()? onFirstFixAfterGap;

  StreamSubscription<Position>? _sub;
  Timer? _retryTimer;
  Timer? _watchdog;
  Duration _retryDelay = Duration.zero;
  DateTime? _lastFixAt;
  bool _started = false;
  bool _recovering = false;

  bool get isRunning => _sub != null;
  DateTime? get lastFixAt => _lastFixAt;

  /// True when the stream is subscribed but has not delivered inside
  /// [staleAfter]. Exposed so a UI can say "locating…" honestly.
  bool get isStale {
    final last = _lastFixAt;
    if (last == null) return _started;
    return DateTime.now().difference(last) > staleAfter;
  }

  void start() {
    _started = true;
    _retryDelay = Duration.zero;
    _subscribe();
  }

  /// Call from `didChangeAppLifecycleState(AppLifecycleState.resumed)`.
  void onAppResumed() {
    if (!_started) return;
    if (_sub == null || isStale) {
      debugPrint('[$label] resumed onto a dead or stale stream — restarting');
      _recovering = true;
      _retryDelay = Duration.zero;
      _subscribe();
    }
  }

  Future<void> stop() async {
    _started = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  void _subscribe() {
    if (!_started) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    // Cancel without awaiting: an await here would let a watchdog tick or a
    // resume land between the cancel and the new listen and start a second
    // stream, which is how you end up publishing two positions per fix.
    _sub?.cancel();
    _sub = null;

    try {
      _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) {
          _lastFixAt = DateTime.now();
          _retryDelay = Duration.zero; // a real fix means the stream works
          if (_recovering) {
            _recovering = false;
            debugPrint('[$label] stream recovered');
            onFirstFixAfterGap?.call();
          }
          onPosition(pos);
        },
        onError: (Object e) {
          debugPrint('[$label] stream error: $e');
          _scheduleRestart();
        },
        // The one that was missing everywhere. A geolocator stream that
        // completes is not an error — it is simply over, silently.
        onDone: () {
          debugPrint('[$label] stream closed by the platform');
          _scheduleRestart();
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[$label] could not subscribe: $e');
      _scheduleRestart();
      return;
    }

    _armWatchdog();
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    // Half the staleness window, so a stall is caught within 1.5x of it.
    final period = Duration(
      milliseconds: (staleAfter.inMilliseconds ~/ 2).clamp(2000, 60000),
    );
    _watchdog = Timer.periodic(period, (_) {
      if (!_started) return;
      final last = _lastFixAt;
      if (last == null) return; // no fix yet — the retry path owns this
      if (DateTime.now().difference(last) <= staleAfter) return;
      debugPrint(
        '[$label] no fix in ${DateTime.now().difference(last).inSeconds}s '
        '— rebuilding a stream that never said it stopped',
      );
      _recovering = true;
      _subscribe();
    });
  }

  void _scheduleRestart() {
    if (!_started) return;
    if (_retryTimer != null) return; // one restart in flight is enough
    _recovering = true;
    _retryDelay = _retryDelay == Duration.zero
        ? retryBase
        : Duration(
            milliseconds:
                (_retryDelay.inMilliseconds * 2).clamp(0, retryMax.inMilliseconds),
          );
    final delay = _retryDelay;
    debugPrint('[$label] resubscribing in ${delay.inSeconds}s');
    _retryTimer = Timer(delay, () async {
      _retryTimer = null;
      if (!_started) return;
      // A denied permission is not something retrying can fix, and hammering
      // the platform channel over it wastes battery for the whole shift.
      // Stay subscribed to the schedule at the slowest rate so the stream
      // still comes back the moment the user grants it in Settings.
      try {
        final perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          debugPrint('[$label] permission is $perm — backing off');
          _retryDelay = retryMax;
        }
      } catch (_) {
        // Permission check itself failed; fall through and try anyway.
      }
      _subscribe();
    });
  }
}
