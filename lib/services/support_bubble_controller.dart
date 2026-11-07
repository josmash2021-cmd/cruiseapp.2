import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'user_session.dart';

/// What GET /support/active answers (see [ApiService.getSupportActive]).
typedef SupportActiveSnapshot = ({
  int? chatId,
  int unread,
  int? lastId,
  bool lastFromSupport,
});

/// How often the bubble asks while the app is in front and in rider mode.
const kSupportBubblePollEvery = Duration(seconds: 45);

/// The rider's floating support bubble (owner 2026-11-07): the live support
/// conversation follows them on every screen — support wrote to them, or
/// they wrote to support — and a tap opens the chat.
///
/// Riders only: in driver mode nothing shows and nothing is polled. The
/// bubble is visible while there is a live chat, the rider has not dropped
/// it on the close target (a newer message brings it back), no support chat
/// screen is open and the top route is a regular page (not the splash /
/// login pages, not a dialog or sheet).
///
/// Refreshed at start, on resume, on a foreground support push, when a
/// support chat screen closes and every [pollEvery] in the foreground —
/// never in the background.
class SupportBubbleController extends ChangeNotifier {
  SupportBubbleController({
    Future<SupportActiveSnapshot?> Function()? fetch,
    Future<String> Function()? readMode,
    bool Function()? inForeground,
    Future<String?> Function()? loadDismissed,
    Future<void> Function(String? value)? saveDismissed,
    this.pollEvery = kSupportBubblePollEvery,
  })  : _fetch = fetch ?? ApiService.getSupportActive,
        _readMode = readMode ?? UserSession.getMode,
        _inForegroundFn = inForeground ?? _appInForeground,
        _loadDismissed = loadDismissed ?? _prefsLoad,
        _saveDismissed = saveDismissed ?? _prefsSave;

  static final SupportBubbleController instance = SupportBubbleController();

  static const _prefsKey = 'support_bubble_dismissed_v1';

  final Future<SupportActiveSnapshot?> Function() _fetch;
  final Future<String> Function() _readMode;
  final bool Function() _inForegroundFn;
  final Future<String?> Function() _loadDismissed;
  final Future<void> Function(String? value) _saveDismissed;
  final Duration pollEvery;

  // ── Server state ──
  bool _isRider = false;
  int? _chatId;
  int _unread = 0;
  int? _lastId;

  // ── Local state ──
  /// Dropped on the close target at this chat / newest message id; a newer
  /// message clears it.
  ({int chat, int last})? _dismissed;
  bool _dismissedLoaded = false;
  bool _sessionFetched = false;
  int _supportChatsOpen = 0;
  bool _routeBlocks = true;
  bool _overlayMounted = false;
  bool _inForeground = true;

  /// A preview waits for the bubble to be on screen.
  bool _pendingPreview = false;
  bool _pendingHaptic = false;

  /// The next refresh must not preview (the rider just read the chat).
  bool _quietNext = false;

  int _previewSeq = 0;
  bool _previewHaptic = false;

  Timer? _poll;
  Timer? _modeDebounce;
  Future<void>? _running;
  bool _again = false;

  // ── Read by the overlay ──

  /// The live conversation, null when there is none.
  int? get chatId => _chatId;
  int get unread => _unread;

  /// Bumped each time the overlay should pop the "Support wrote to you"
  /// preview (only while [visible]).
  int get previewSeq => _previewSeq;

  /// The current preview is for a message that just arrived (haptic tick).
  bool get previewHaptic => _previewHaptic;

  bool get isRider => _isRider;
  bool get supportChatOpen => _supportChatsOpen > 0;

  bool get _isDismissed {
    final d = _dismissed;
    return d != null && d.chat == _chatId && (_lastId ?? 0) <= d.last;
  }

  bool get visible =>
      _overlayMounted &&
      _isRider &&
      _chatId != null &&
      !_isDismissed &&
      _supportChatsOpen == 0 &&
      !_routeBlocks;

  // ── Overlay lifecycle ──

  /// The overlay above the navigator is up: first look + the poll.
  void overlayMounted() {
    _overlayMounted = true;
    _inForeground = _inForegroundFn();
    unawaited(refresh());
  }

  void overlayUnmounted() {
    _overlayMounted = false;
    _stopPolling();
    _modeDebounce?.cancel();
    _modeDebounce = null;
  }

  /// App lifecycle from the overlay. Resume = look again; leaving the
  /// foreground stops the poll.
  void appLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inForeground = true;
      unawaited(refresh());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _inForeground = false;
      _stopPolling();
    }
  }

  /// The top route changed: [blocks] = splash / login / a dialog or sheet.
  /// The mode is read again shortly after (rider ↔ driver switch).
  void topRouteChanged({required bool blocks}) {
    if (_routeBlocks != blocks) {
      _routeBlocks = blocks;
      _recompute();
    }
    if (!_overlayMounted) return;
    _modeDebounce?.cancel();
    _modeDebounce = Timer(const Duration(milliseconds: 400), () {
      _modeDebounce = null;
      unawaited(_recheckMode());
    });
  }

  /// A support chat screen opened ([CruiseSupportChatScreen], or
  /// [ChatScreen] for support): the bubble steps aside.
  void supportChatOpened() {
    _supportChatsOpen++;
    _pendingPreview = false;
    _recompute();
  }

  /// A support chat screen closed: look again, without a preview for what
  /// the rider just read there.
  void supportChatClosed() {
    if (_supportChatsOpen > 0) _supportChatsOpen--;
    _quietNext = true;
    _recompute();
    unawaited(refresh());
  }

  /// Dropped on the close target: hidden until a newer message.
  void dismiss() {
    final chat = _chatId;
    if (chat == null) return;
    _dismissed = (chat: chat, last: _lastId ?? 0);
    _pendingPreview = false;
    unawaited(_persistDismissed());
    _recompute();
  }

  /// Logout: nothing of the previous account stays.
  void clear() {
    _chatId = null;
    _unread = 0;
    _lastId = null;
    _isRider = false;
    _sessionFetched = false;
    _pendingPreview = false;
    _quietNext = false;
    _stopPolling();
    _recompute();
  }

  /// A support push arrived with the app in front. True when the rider
  /// sees it without a banner: the bubble (with its preview) is on screen,
  /// or the support chat itself is. False = draw the banner as before
  /// (driver mode, no overlay, the bubble cannot show right now).
  /// [systemBannerShown]: an old iOS binary already drew its own banner —
  /// the bubble only pulses, no second notice.
  Future<bool> handleForegroundPush({bool systemBannerShown = false}) async {
    if (!_overlayMounted) return false;
    String mode;
    try {
      mode = await _readMode();
    } catch (_) {
      return false;
    }
    if (mode != 'rider') return false;
    if (systemBannerShown) _quietNext = true;
    await refresh();
    if (_supportChatsOpen > 0) return true;
    if (visible) return true;
    // The banner shows instead; no late preview on top of it.
    _pendingPreview = false;
    return false;
  }

  // ── Refresh ──

  /// One GET /support/active; a call while one is running runs once more
  /// after it (a push must not be answered by an older look).
  Future<void> refresh() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final f = _refreshLoop();
    _running = f;
    return f;
  }

  Future<void> _refreshLoop() async {
    try {
      do {
        _again = false;
        await _refreshOnce();
      } while (_again);
    } finally {
      _running = null;
    }
  }

  Future<void> _refreshOnce() async {
    if (!_overlayMounted) return;
    String mode;
    try {
      mode = await _readMode();
    } catch (_) {
      return;
    }
    if (mode != 'rider') {
      if (_isRider) {
        _isRider = false;
        _recompute();
      }
      _stopPolling();
      return;
    }
    _isRider = true;
    if (!_dismissedLoaded) {
      _dismissedLoaded = true;
      await _restoreDismissed();
    }
    final snap = await _fetch();
    if (snap == null) {
      // Network or no session: keep what is on screen, try again later.
      _ensurePolling();
      return;
    }
    _apply(snap);
    _ensurePolling();
  }

  void _apply(SupportActiveSnapshot snap) {
    final first = !_sessionFetched;
    _sessionFetched = true;
    final prevLast = _lastId;
    final prevChat = _chatId;
    _chatId = snap.chatId;
    _unread = snap.unread < 0 ? 0 : snap.unread;
    _lastId = snap.lastId;

    final quiet = _quietNext || _supportChatsOpen > 0;
    _quietNext = false;

    final d = _dismissed;
    if (d != null &&
        _chatId != null &&
        (d.chat != _chatId || (_lastId ?? 0) > d.last)) {
      // Another conversation, or a newer message: the drop is over.
      _dismissed = null;
      unawaited(_persistDismissed());
    }

    if (_chatId == null) {
      _pendingPreview = false;
    } else if (!quiet) {
      final last = snap.lastId;
      if (first) {
        // Opening the app onto an unread reply: one preview.
        if (_unread > 0) {
          _pendingPreview = true;
          _pendingHaptic = false;
        }
      } else if (snap.lastFromSupport &&
          last != null &&
          (prevLast == null || prevChat != _chatId || last > prevLast)) {
        _pendingPreview = true;
        _pendingHaptic = true;
      }
    }
    _recompute();
  }

  Future<void> _recheckMode() async {
    if (!_overlayMounted) return;
    String mode;
    try {
      mode = await _readMode();
    } catch (_) {
      return;
    }
    final rider = mode == 'rider';
    if (rider == _isRider) return;
    if (rider) {
      unawaited(refresh());
    } else {
      _isRider = false;
      _stopPolling();
      _recompute();
    }
  }

  void _recompute() {
    if (_supportChatsOpen > 0) _pendingPreview = false;
    if (_pendingPreview && visible) {
      _pendingPreview = false;
      _previewHaptic = _pendingHaptic;
      _previewSeq++;
    }
    notifyListeners();
  }

  // ── Poll (foreground + rider only) ──

  void _ensurePolling() {
    if (!_overlayMounted || !_isRider || !_inForeground) {
      _stopPolling();
      return;
    }
    _poll ??= Timer.periodic(pollEvery, (_) {
      // Belt and braces: a suspended app never asks.
      if (!_inForeground || !_inForegroundFn()) return;
      unawaited(refresh());
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @visibleForTesting
  bool get isPolling => _poll != null;

  // ── Dismissal across restarts ──

  Future<void> _restoreDismissed() async {
    try {
      final raw = await _loadDismissed();
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        final chat = (m['chat'] as num?)?.toInt();
        final last = (m['last'] as num?)?.toInt();
        if (chat != null && last != null) {
          _dismissed ??= (chat: chat, last: last);
        }
      }
    } catch (_) {}
  }

  Future<void> _persistDismissed() async {
    final d = _dismissed;
    try {
      await _saveDismissed(
          d == null ? null : jsonEncode({'chat': d.chat, 'last': d.last}));
    } catch (_) {}
  }

  static Future<String?> _prefsLoad() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey);
  }

  static Future<void> _prefsSave(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, value);
    }
  }

  static bool _appInForeground() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    _stopPolling();
    _modeDebounce?.cancel();
    super.dispose();
  }
}

/// Tells [SupportBubbleController] what is on top of the navigator, so the
/// bubble stays off the splash / login pages and from under dialogs and
/// sheets. Mirrors the route stack (the observer callbacks fire while the
/// navigator is locked, so it cannot be asked).
class SupportBubbleRouteObserver extends NavigatorObserver {
  SupportBubbleRouteObserver(this.controller, {required this.blocks});

  final SupportBubbleController controller;

  /// True for a top route the bubble must not float over.
  final bool Function(Route<dynamic> route) blocks;

  final List<Route<dynamic>> _stack = [];

  void _changed() {
    final top = _stack.isEmpty ? null : _stack.last;
    controller.topRouteChanged(blocks: top == null || blocks(top));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      if (i >= 0) {
        _stack[i] = newRoute;
      } else {
        _stack.add(newRoute);
      }
    } else if (i >= 0) {
      _stack.removeAt(i);
    }
    _changed();
  }
}
