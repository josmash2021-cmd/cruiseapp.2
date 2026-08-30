import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models/chat_message.dart';
import '../services/api_service.dart';
import '../services/chat_service.dart';
import '../services/error_service.dart';
import '../services/masked_call_service.dart';
import '../services/socket_service.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../widgets/neu_style.dart';
import '../widgets/verified_avatar.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;
import '../widgets/dismiss_keyboard.dart';
import '../services/firebase_auth_recovery.dart';

/// Full-page chat screen — real-time via Firebase RTDB for trip chats,
/// REST API polling for support chat.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.recipientName,
    this.isSupport = false,
    this.avatarInitial,
    this.tripId,
    this.currentUserId,
    this.currentRole,
    this.recipientPhotoUrl,
    this.recipientId,
    this.recipientRole,
  });

  /// The trip ID of the currently active chat screen (if any).
  /// Used to suppress push notifications while the user is in this chat.
  static int? activeTripId;

  final String recipientName;
  final bool isSupport;
  final String? avatarInitial;
  final int? tripId;

  /// Recipient's profile photo. Falls back to the initial when absent.
  final String? recipientPhotoUrl;

  /// Recipient's user id — lets VerifiedAvatar resolve the photo itself
  /// when [recipientPhotoUrl] was not passed.
  final String? recipientId;

  /// 'driver' or 'rider' — who the recipient is, for the avatar.
  final String? recipientRole;

  /// Current user's ID (as String). If null, resolved from ApiService.
  final String? currentUserId;

  /// 'driver' or 'rider'. If null, defaults to 'rider'.
  final String? currentRole;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _gold = Color(0xFFE8C547);
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _chat = ChatService();

  String _myUserId = '';
  String _myRole = 'rider';
  String get _otherRole => _myRole == 'driver' ? 'rider' : 'driver';
  String get _rideId => widget.tripId?.toString() ?? '';

  /// True for trip chats, false for support.
  ///
  /// A getter, not a field assigned during init: it is a pure decision about
  /// the widget's own arguments, and as a field it read `false` for the whole
  /// window before init finished — long enough for a send to take the wrong
  /// branch.
  bool get _useRtdb => !widget.isSupport && widget.tripId != null;

  /// The live message feed, opened once in [_initChat]. See the comment there
  /// for why this is not built inside build().
  Stream<List<ChatMessage>>? _messagesStream;
  bool _chatReady = false; // true after _initChat completes
  bool _rtdbFailed = false; // true when RTDB stream errors → REST fallback

  // ── Support-mode state ──
  final List<_SupportMessage> _supportMessages = [];
  Timer? _pollTimer;
  bool _supportError = false;
  int? _supportChatId;
  String _agentName = 'Support';
  final int _lastSupportMsgId = 0; // tracks highest msg id seen for polling
  bool _agentTyping = false;
  /// Signature of the support list as last rendered, so an unchanged poll
  /// does not rebuild it (and re-trigger the scroll animation).
  String _supportSig = '';

  // ── REST fallback messages (used when RTDB fails) ──
  final List<ChatMessage> _restMessages = [];
  Timer? _restPollTimer;
  StreamSubscription<Map<String, dynamic>>? _socketChatSub;

  // ── Typing ──
  Timer? _typingTimer;
  bool? _rtdbConnected;
  StreamSubscription<DatabaseEvent>? _rtdbConnectionSub;

  // ── Auto-scroll tracking ──
  int _lastMsgCount = 0;
  bool _hadFirstConnect = false;

  @override
  void initState() {
    super.initState();
    ChatScreen.activeTripId = widget.tripId;
    _initChat();
  }

  Future<void> _initChat() async {
    _myRole = widget.currentRole ?? 'rider';

    // Who we are is NOT a prerequisite for the chat working.
    //
    // getCurrentUserId() used to be awaited right here, with a 15-second
    // timeout, and _chatReady only flipped after it. Until then build()
    // painted a spinner instead of the message list, so the RTDB listener was
    // never even attached and nothing arrived; and _sendMessage returned early
    // at its !_chatReady guard, so every tap on send was a silent no-op with
    // no error and no bubble. That is the entire "messages take forever and
    // sending just fails" report — the chat was inert for as long as that one
    // call took, and on a cold cache it is a full HTTP round trip.
    //
    // The room is keyed on the trip id, which we already have. Only the
    // sender's own id needs resolving, and the send path does that itself when
    // it finds the field empty.
    if (widget.currentUserId != null && widget.currentUserId!.isNotEmpty) {
      _myUserId = widget.currentUserId!;
    } else {
      unawaited(
        ApiService.getCurrentUserId()
            .timeout(const Duration(seconds: 15))
            .then((id) {
          if (id != null && id > 0) _myUserId = id.toString();
        }).catchError((e) {
          debugPrint('[Chat] user id resolve failed: $e');
          return null;
        }),
      );
    }

    // Firebase Auth IS a prerequisite — RTDB rules require auth != null, and
    // attaching the listener without it fails the stream straight into the
    // REST fallback. Normally free: main.dart already signed in at startup, so
    // this only costs a round trip when that session was lost.
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuthRecovery.ensureSignedIn();
      }
    } catch (e) {
      debugPrint('[Chat] Firebase Auth sign-in failed: $e');
    }

    // Decide mode: RTDB for trip chats, polling for support
    if (_useRtdb) {
      // Opened ONCE, here — never inside build().
      //
      // Every call to messagesStream() attaches a brand-new RTDB listener, and
      // this was being called straight from the StreamBuilder in build(). So
      // each setState tore the listener down and attached another: the builder
      // fell back to its initialData (an empty list, so the bubbles blinked
      // out), re-downloaded all 200 messages, and re-ran the auto-scroll.
      // A chat that re-subscribes on every rebuild feels slow no matter how
      // fast the network underneath it is.
      _messagesStream = _chat.messagesStream(_rideId);
      _startConnectionListener();
      // Mark existing messages as read when opening
      _chat.markAsRead(rideId: _rideId, readerRole: _myRole);
    } else if (widget.isSupport) {
      await _initSupportChat();
    }

    _chatReady = true;
    if (mounted) setState(() {});
  }

  // ── Support chat init + polling ────────────────────────────────────────

  Future<void> _initSupportChat() async {
    try {
      final locale = Localizations.localeOf(context).languageCode;
      final result = await ApiService.createSupportChat(locale: locale).timeout(const Duration(seconds: 15));
      _supportChatId = (result['id'] as num?)?.toInt();
      _agentName = (result['agent_name'] as String?) ?? 'Support';
      if (_supportChatId != null) {
        await _pollSupportMessages(); // load existing messages immediately
        _startSupportPolling();
      }
    } catch (e) {
      debugPrint('[Chat] Support chat init failed: $e');
      if (mounted) setState(() => _supportError = true);
    }
  }

  void _startSupportPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollSupportMessages();
    });
  }

  Future<void> _pollSupportMessages() async {
    final chatId = _supportChatId;
    if (chatId == null) return;
    try {
      final msgs = await ApiService.getSupportMessages(chatId).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final parsed = msgs.map((m) {
        final role = (m['sender_role'] as String?) ?? 'bot';
        final isMe = role == 'rider' || role == 'driver' || role == 'user';
        final senderName = (m['sender_name'] as String?) ?? _agentName;
        final text = (m['message'] as String?) ?? '';
        final createdAt = m['created_at'] as String?;
        final time = createdAt != null
            ? (DateTime.tryParse(createdAt) ?? DateTime.now())
            : DateTime.now();
        final id = (m['id'] as num?)?.toInt() ?? 0;
        return _SupportMessage(
          id: id,
          text: text,
          isMe: isMe,
          time: time,
          senderName: senderName,
          role: role,
        );
      }).toList()
        ..sort((a, b) => a.time.compareTo(b.time));

      if (!mounted) return;
      // Update agent name if set by backend
      final lastBot = parsed.lastWhere((m) => !m.isMe && m.senderName.isNotEmpty, orElse: () => parsed.isNotEmpty ? parsed.last : _SupportMessage(id: 0, text: '', isMe: false, time: DateTime.now(), senderName: _agentName, role: 'bot'));
      if (lastBot.senderName.isNotEmpty) _agentName = lastBot.senderName;

      // Keep optimistic sends the server has not echoed back yet.
      //
      // This used to clear and replace the whole list whenever the counts
      // differed — and right after a send the count ALWAYS differs, because
      // the local echo (id 0) is in our list and not yet in the server's. So
      // the driver's own message was deleted off the screen a moment after
      // they sent it and only came back on the next poll two seconds later.
      // That is both "my message takes a while to appear" and the scroll
      // jump: the list shrank and re-grew, and maxScrollExtent moved
      // underneath a running animation.
      final serverTexts = parsed.map((m) => m.text).toSet();
      final pendingMine = _supportMessages
          .where((m) => m.isMe && m.id == 0 && !serverTexts.contains(m.text));
      final merged = <_SupportMessage>[...parsed, ...pendingMine];

      // Signature, not length: a poll that brings back the same messages must
      // not rebuild the list, because every rebuild re-runs the scroll
      // animation. Two messages can also swap without the count changing.
      final sig = merged.map((m) => '${m.id}|${m.text}').join('');
      if (sig != _supportSig) {
        _supportSig = sig;
        final hasNewBotMsg = parsed.any((m) => !m.isMe);
        setState(() {
          _supportMessages
            ..clear()
            ..addAll(merged);
          if (hasNewBotMsg) _agentTyping = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[Chat] Support poll error: $e');
    }
  }

  @override
  void dispose() {
    ChatScreen.activeTripId = null;
    _pollTimer?.cancel();
    _typingTimer?.cancel();
    _restPollTimer?.cancel();
    _socketChatSub?.cancel();
    _rtdbConnectionSub?.cancel();
    _agentTyping = false;
    // Stop typing indicator when leaving
    if (_useRtdb && !_rtdbFailed) {
      _chat.setTyping(rideId: _rideId, role: _myRole, isTyping: false);
    }
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── REST API fallback ────────────────────────────────────────────────
  void _startRestPolling() {
    _fetchRestMessages(); // immediate first fetch
    _restPollTimer?.cancel();
    _restPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchRestMessages();
    });

    // The instant lane under the poll: the backend broadcasts every
    // REST-sent message over Socket.IO to the trip room in the same beat
    // (emit_chat_message, sub-100 ms), so a REST-mode chat stops feeling
    // like a 3-second walkie-talkie in both directions.
    _socketChatSub?.cancel();
    final tripId = widget.tripId;
    if (tripId != null) {
      unawaited(
        SocketService.init().then((_) => SocketService.joinTrip(tripId)),
      );
      _socketChatSub = SocketService.chatMessageStream.listen((data) {
        if (!mounted) return;
        if ((data['trip_id']?.toString() ?? '') != tripId.toString()) return;
        final senderRole = (data['sender_role'] ?? '').toString();
        // Own bubble is already on screen from the send path — adding it
        // again from the room broadcast would double it.
        if (senderRole == _myRole) return;
        final text = (data['message'] ?? '').toString().trim();
        if (text.isEmpty) return;
        final ts = (data['timestamp'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        // The next poll brings the same message back from the backend —
        // never show it twice.
        final dupe = _restMessages.any((m) =>
            m.senderRole == senderRole &&
            m.text == text &&
            (m.timestamp - ts).abs() < 8000);
        if (dupe) return;
        setState(() {
          _restMessages.add(ChatMessage(
            id: 'sock_$ts',
            senderId: (data['sender_id'] ?? '').toString(),
            senderRole: senderRole,
            text: text,
            timestamp: ts,
            read: false,
          ));
          _lastMsgCount = _restMessages.length;
        });
        _scrollToBottom();
        _chat.markAsRead(rideId: _rideId, readerRole: _myRole);
      });
    }
  }

  Future<void> _fetchRestMessages() async {
    if (widget.tripId == null) return;
    try {
      final msgs = await ApiService.getChatMessages(widget.tripId!).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final parsed = msgs.map((m) {
        return ChatMessage(
          id: m['id']?.toString() ?? '',
          senderId: m['sender_id']?.toString() ?? '',
          senderRole: m['sender_role']?.toString() ?? 'rider',
          text: m['message']?.toString() ?? m['text']?.toString() ?? '',
          timestamp: _parseTimestamp(m['created_at'] ?? m['timestamp']),
          read: m['is_read'] == true,
        );
      }).toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      if (!mounted) return;
      setState(() => _restMessages
        ..clear()
        ..addAll(parsed));

      if (parsed.length != _lastMsgCount) {
        _lastMsgCount = parsed.length;
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[Chat] REST poll error: $e');
    }
  }

  int _parseTimestamp(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) {
      final dt = DateTime.tryParse(value);
      if (dt != null) return dt.millisecondsSinceEpoch;
    }
    return 0;
  }

  void _startConnectionListener() {
    _rtdbConnectionSub?.cancel();
    _rtdbConnectionSub = FirebaseDatabase.instance
        .ref('.info/connected')
        .onValue
        .listen((event) {
      final val = event.snapshot.value;
      final connected = val == true;
      if (!mounted) return;
      if (connected) _hadFirstConnect = true;
      setState(() => _rtdbConnected = connected);
    }, onError: (e) {
      debugPrint('[Chat] RTDB connection listener error: $e');
      if (!mounted) return;
      setState(() => _rtdbConnected = false);
    });
  }

  Color _connectionDotColor() {
    if (!_useRtdb) return const Color(0xFF4CAF50);
    if (_rtdbFailed) return const Color(0xFF4CAF50); // REST fallback active
    if (_rtdbConnected == true) return const Color(0xFF4CAF50);
    return const Color(0xFFF59E0B);
  }

  String _connectionLabel(S s) {
    if (!_useRtdb) return s.online;
    if (_rtdbFailed) return s.online; // REST fallback active
    if (_rtdbConnected == true) return s.activeNow;
    if (_hadFirstConnect) return s.reconnecting;
    return s.connecting;
  }

  List<String> get _quickReplies => [
    'Problema con mi viaje',
    'Me cobraron mal',
    'Quiero un reembolso',
    'Problema con mi cuenta',
    'Problema de seguridad',
  ];

  // ── Send ────────────────────────────────────────────────────────────────

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // A trip chat only needs the room id, which comes from the trip id and is
    // known before this screen is built. Support genuinely cannot send until
    // the server has handed us a chat id.
    //
    // This used to be a bare !_chatReady check that swallowed the message: the
    // text stayed in the box, nothing was sent, nothing was said. The one
    // thing worse than a slow send is a send that silently did not happen.
    final canSend = _useRtdb ? _rideId.isNotEmpty : _supportChatId != null;
    if (!canSend) {
      debugPrint('[Chat] send held — channel not up yet (rtdb=$_useRtdb)');
      if (mounted) {
        ErrorService.show(context, S.of(context).connectionIssueRetrying);
      }
      return;
    }

    _controller.clear();

    if (_useRtdb) {
      // Ensure userId is resolved before sending
      if (_myUserId.isEmpty || _myUserId == '0') {
        final id = await ApiService.getCurrentUserId();
        if (id != null && id > 0) _myUserId = id.toString();
      }
      if (_rideId.isEmpty) {
        debugPrint('[Chat] Cannot send: rideId is empty');
        return;
      }

      if (_rtdbFailed) {
        // REST-only mode: send via API and poll for updates
        if (widget.tripId != null) {
          try {
            await ApiService.sendChatMessage(tripId: widget.tripId!, message: text).timeout(const Duration(seconds: 15));
            await _fetchRestMessages(); // refresh immediately
          } catch (e) {
            debugPrint('[Chat] REST send failed: $e');
            if (mounted) {
              ErrorService.show(context, S.of(context).messageFailedToSend);
            }
          }
        }
        return;
      }

      // RTDB is the live channel: Firebase echoes the write to every
      // listener (including ours) before the server even answers, so the
      // bubble lands instantly and the driver sees it in the same beat.
      // Not awaited — awaiting held the send behind a network round-trip
      // for no benefit, since the local echo has already happened.
      unawaited(
        _chat
            .sendMessage(
          rideId: _rideId,
          senderId: _myUserId,
          senderRole: _myRole,
          text: text,
        )
            .catchError((e) {
          debugPrint('[Chat] RTDB send failed: $e');
          if (mounted) {
            ErrorService.show(context, S.of(context).messageFailedToSend);
          }
        }),
      );
      // Backend copy — persists the message and fires the FCM push.
      //
      // This used to run TWICE per message: once unawaited inside the try
      // above and again, awaited, right after. Every message was stored
      // twice and the recipient got two pushes, and the second call
      // blocked the send for a whole HTTP round-trip.
      if (widget.tripId != null) {
        unawaited(
          ApiService.sendChatMessage(tripId: widget.tripId!, message: text)
              .catchError((e) {
            debugPrint('[Chat] REST backup send failed: $e');
            return <String, dynamic>{};
          }),
        );
      }
    } else if (widget.isSupport) {
      final chatId = _supportChatId;
      if (chatId == null) {
        if (mounted) ErrorService.show(context, S.of(context).connectionIssueRetrying);
        return;
      }
      // Optimistic: show user message immediately
      setState(() {
        _supportMessages.add(
          _SupportMessage(
            id: 0,
            text: text,
            isMe: true,
            time: DateTime.now(),
            senderName: '',
            role: 'rider',
          ),
        );
        _agentTyping = true;
      });
      // force: this is the driver's own message — always follow it down.
      _scrollToBottom(force: true);
      try {
        await ApiService.sendSupportMessage(chatId, text).timeout(const Duration(seconds: 15));
        // Poll immediately to get bot response faster
        await _pollSupportMessages();
      } catch (_) {
        if (mounted) ErrorService.show(context, S.of(context).messageFailedToSend);
      }
    }
  }

  // ── Typing indicator ──────────────────────────────────────────────────

  void _onTextChanged(String text) {
    if (widget.isSupport) {
      final chatId = _supportChatId;
      if (chatId != null && text.trim().isNotEmpty) {
        unawaited(ApiService.setSupportTypingStatus(chatId, true));
        _typingTimer?.cancel();
        _typingTimer = Timer(const Duration(seconds: 3), () {
          unawaited(ApiService.setSupportTypingStatus(chatId, false));
        });
      }
      return;
    }
    if (!_useRtdb) return;
    if (text.trim().isNotEmpty) {
      _chat.setTyping(rideId: _rideId, role: _myRole, isTyping: true);
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () {
        _chat.setTyping(rideId: _rideId, role: _myRole, isTyping: false);
      });
    } else {
      _typingTimer?.cancel();
      _chat.setTyping(rideId: _rideId, role: _myRole, isTyping: false);
    }
  }

  // ── Scroll ────────────────────────────────────────────────────────────

  /// [force] scrolls even when the user has scrolled up — use it for their
  /// own sends, never for an incoming poll.
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      // Leave the driver where they are if they scrolled up to read back.
      // Unconditional animateTo meant a poll landing every 2 seconds dragged
      // the view down out from under their thumb.
      if (!force && pos.maxScrollExtent - pos.pixels > 240) return;
      _scrollController.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _callRecipient() async {
    HapticService.mediumImpact();
    // Masked callback: the server rings the caller's phone and bridges to
    // the other party — neither side ever sees the other's real number.
    final tripId = widget.tripId;
    if (tripId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).driverContacted),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
        ),
      );
      return;
    }
    final ok = await MaskedCallService.callCounterparty(tripId: tripId, role: _myRole);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? S.of(context).callingYouBack : S.of(context).driverContacted,
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).viewInsets.bottom;
    final safePad = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // neuBase, not pure black: the soft shadows below are invisible on
        // #000000 (see neu_style.dart).
        backgroundColor: neuBase,
        body: DismissKeyboard(
          child: Column(
            children: [
            // ── App bar ──
            _buildAppBar(s, topPad),

            // ── Messages ──
            Expanded(
              child: Stack(
                children: [
                  // Faint Cruise mark behind the conversation. IgnorePointer
                  // so it can never swallow a tap meant for a message.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Opacity(
                          opacity: 0.035,
                          child: Image.asset(
                            // cruise_logo.png, not logoapp.png: the latter
                            // is the same mark baked onto a black square,
                            // which on the chat's lighter neu background
                            // read as a dark box behind the watermark.
                            'assets/images/cruise_logo.png',
                            width: MediaQuery.of(context).size.width * 0.62,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  !_chatReady
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFFD4A843)))
                      : _useRtdb
                          ? _buildRtdbMessages(s)
                          : _buildSupportMessages(s),
                ],
              ),
            ),

            // ── Typing indicator (RTDB only) ──
            if (_useRtdb) _buildTypingIndicator(s),

            // ── Input bar ──
            _buildInputBar(s, bottomPad, safePad),
          ],
        ),
      ),
      ),
    );
  }

  // ── App bar ──────────────────────────────────────────────────────────

  Widget _buildAppBar(S s, double topPad) {
    return Container(
      padding: EdgeInsets.only(top: topPad + 8, bottom: 12, left: 8, right: 8),
      decoration: BoxDecoration(
        color: neuSurface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: S.of(context).back,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            splashRadius: 22,
          ),
          // Avatar — the recipient's real photo, not a letter. VerifiedAvatar
          // falls back to the initial on its own when there is no photo.
          if (widget.isSupport)
            Container(
              width: Responsive.w(36),
              height: Responsive.w(36),
              decoration: neuBox(
                radius: Responsive.w(18),
                borderColor: _gold.withValues(alpha: 0.4),
              ),
              child: Center(
                child: Icon(Icons.support_agent_rounded,
                    size: Responsive.sp(18), color: _gold),
              ),
            )
          else
            VerifiedAvatar(
              photoUrl: widget.recipientPhotoUrl,
              uid: widget.recipientId,
              role: widget.recipientRole ??
                  (_myRole == 'driver' ? 'rider' : 'driver'),
              fallbackName: widget.avatarInitial ?? widget.recipientName,
              radius: Responsive.w(18),
              isVerified: true,
            ),
          SizedBox(width: Responsive.w(10)),
          // Name + status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isSupport
                      ? s.cruiseSupport
                      : (widget.recipientName.isNotEmpty
                          ? nh.displayName(widget.recipientName)
                          : _myRole == 'driver' ? 'Rider' : 'Driver'),
                  style: TextStyle(
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Container(
                      width: Responsive.w(6),
                      height: Responsive.w(6),
                      decoration: BoxDecoration(
                        color: _connectionDotColor(),
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: Responsive.w(4)),
                    Text(
                      _connectionLabel(s),
                      style: TextStyle(
                        fontSize: Responsive.sp(11),
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!widget.isSupport) ...[
            _headerIconBtn(Icons.phone_rounded, _callRecipient, s.callAction),
            SizedBox(width: Responsive.w(8)),
            // Support, right of the call button: reaching a human should
            // not mean backing out of the conversation first.
            _headerIconBtn(
              Icons.support_agent_rounded,
              _openSupportFromChat,
              s.contactSupport,
            ),
          ],
        ],
      ),
    );
  }

  /// Header action pill — sunken neumorphic well, the shared idiom for
  /// icon buttons across the app.
  Widget _headerIconBtn(IconData icon, VoidCallback onTap, String tooltip) {
    final d = Responsive.w(36);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: d,
          height: d,
          decoration: neuBox(
            radius: d / 2,
            pressed: true,
            borderColor: _gold.withValues(alpha: 0.30),
          ),
          child: Icon(icon, color: _gold, size: Responsive.sp(18)),
        ),
      ),
    );
  }

  /// Open the Cruise support conversation without leaving this one.
  void _openSupportFromChat() {
    HapticService.selectionClick();
    Navigator.of(context).push(
      slideFromRightRoute(
        ChatScreen(
          recipientName: 'Support',
          avatarInitial: 'S',
          tripId: widget.tripId,
          isSupport: true,
          currentUserId: widget.currentUserId,
          currentRole: widget.currentRole,
        ),
      ),
    );
  }

  // ── RTDB messages (StreamBuilder) ────────────────────────────────────

  Widget _buildRtdbMessages(S s) {
    if (_rideId.isEmpty) {
      return _buildEmptyState(s);
    }

    // If RTDB failed, show messages from REST API polling
    if (_rtdbFailed) {
      return _buildRestMessages(s);
    }

    return StreamBuilder<List<ChatMessage>>(
      // The one instance opened in _initChat. Passing the same object across
      // rebuilds is what stops StreamBuilder from re-subscribing.
      stream: _messagesStream,
      initialData: const <ChatMessage>[],
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          debugPrint('[Chat] RTDB stream error: ${snapshot.error} — switching to REST polling');
          // Switch to REST fallback on next frame
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _rtdbFailed) return;
            setState(() => _rtdbFailed = true);
            _startRestPolling();
          });
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFD4A843)),
          );
        }

        final messages = snapshot.data ?? [];

        // Auto-scroll when new messages arrive
        if (messages.length != _lastMsgCount) {
          _lastMsgCount = messages.length;
          _scrollToBottom();
          // Mark incoming messages as read
          if (messages.isNotEmpty) {
            _chat.markAsRead(rideId: _rideId, readerRole: _myRole);
          }
        }

        if (messages.isEmpty) {
          return _buildEmptyState(s);
        }

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[index];
            final isMe = msg.senderId == _myUserId;
            final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
            return _buildBubble(
              text: msg.text,
              isMe: isMe,
              time: time,
              isRead: msg.read,
            );
          },
        );
      },
    );
  }

  Widget _buildRestMessages(S s) {
    if (_restMessages.isEmpty) {
      return _buildEmptyState(s);
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _restMessages.length,
      itemBuilder: (context, index) {
        final msg = _restMessages[index];
        final isMe = msg.senderId == _myUserId;
        final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
        return _buildBubble(
          text: msg.text,
          isMe: isMe,
          time: time,
          isRead: msg.read,
        );
      },
    );
  }

  // ── Support messages (polling fallback) ──────────────────────────────

  /// What to print above a support message.
  ///
  /// The backend labels its automated replies "System" (and variants like
  /// "Cruise Support System"). To the rider that reads as a machine
  /// talking, which is not who they think they are writing to — the header
  /// right above says Cruise Support. Anything system-ish is folded into
  /// that one name; a real agent's name is shown as-is.
  String _displaySenderName(String raw, S s) {
    final lower = raw.toLowerCase().trim();
    if (lower.isEmpty || lower == 'system' || lower == 'bot' ||
        lower.contains('system')) {
      return s.cruiseSupport;
    }
    return raw;
  }

  Widget _buildSupportMessages(S s) {
    return Column(
      children: [
        if (_supportError)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFFEF4444).withValues(alpha: 0.15),
            child: Row(
              children: [
                Icon(Icons.wifi_off_rounded, color: const Color(0xFFEF4444), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    S.of(context).connectionIssueRetrying,
                    style: TextStyle(
                      color: const Color(0xFFEF4444),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: _supportMessages.isEmpty
              ? _buildEmptyState(s)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: _supportMessages.length,
                  itemBuilder: (context, index) {
                    final msg = _supportMessages[index];
                    return Column(
                      crossAxisAlignment: msg.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        if (!msg.isMe && msg.senderName.isNotEmpty && (index == 0 || _supportMessages[index - 1].isMe))
                          Padding(
                            padding: const EdgeInsets.only(left: 36, bottom: 4),
                            child: Text(
                              _displaySenderName(msg.senderName, s),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                                color: _gold.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                        _buildBubble(
                          text: msg.text,
                          isMe: msg.isMe,
                          time: msg.time,
                          isRead: true,
                        ),
                      ],
                    );
                  },
                ),
        ),
        // Quick replies — BELOW the conversation, not above it. They used
        // to render before the list, so the rider met a wall of buttons
        // before the greeting that explains them. Now the welcome message
        // comes first and the shortcuts sit where the answer goes, right
        // above the input.
        if (_supportMessages.length <= 1 && _supportChatId != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.chooseATopic,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _quickReplies
                      .map((label) => GestureDetector(
                            onTap: () {
                              HapticService.selectionClick();
                              _controller.text = label;
                              _sendMessage();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 9),
                              // Raised pills — they are buttons, so they
                              // should stand off the surface.
                              decoration: neuBox(
                                radius: 20,
                                borderColor: _gold.withValues(alpha: 0.28),
                              ),
                              child: Text(
                                label,
                                style: const TextStyle(
                                  color: _gold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
        if (_agentTyping)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8, top: 4),
            child: Row(
              children: [
                Container(
                  width: 26, height: 26,
                  decoration: neuBox(
                    radius: 13,
                    pressed: true,
                    borderColor: _gold.withValues(alpha: 0.25),
                  ),
                  child: const Center(
                    child: Icon(Icons.support_agent_rounded, size: 13, color: _gold),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  // Matches the raised incoming bubble, tail corner and all.
                  decoration: BoxDecoration(
                    color: neuSurface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(18),
                    ),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        offset: const Offset(4, 4),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTypingDot(0),
                      const SizedBox(width: 4),
                      _buildTypingDot(1),
                      const SizedBox(width: 4),
                      _buildTypingDot(2),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildTypingDot(int index) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        shape: BoxShape.circle,
      ),
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────

  Widget _buildEmptyState(S s) {
    // Sits at the bottom, just above the input bar, rather than floating in
    // the middle of the screen. It is a prompt to start typing, so it belongs
    // next to the thing it is asking you to type in — and where the first
    // message will actually appear.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 30,
              color: Colors.white.withValues(alpha: 0.13),
            ),
            const SizedBox(height: 8),
            Text(
              s.writeToStart,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Typing indicator ────────────────────────────────────────────────

  Widget _buildTypingIndicator(S s) {
    return StreamBuilder<bool>(
      stream: _chat.typingStream(rideId: _rideId, otherRole: _otherRole),
      builder: (context, snapshot) {
        final isTyping = snapshot.data ?? false;
        if (!isTyping) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.only(left: 20, bottom: 4, top: 2),
          child: Text(
            '${nh.displayName(widget.recipientName)} ${s.typing}',
            style: TextStyle(
              fontSize: Responsive.sp(12),
              fontStyle: FontStyle.italic,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        );
      },
    );
  }

  // ── Input bar ───────────────────────────────────────────────────────

  Widget _buildInputBar(S s, double bottomPad, double safePad) {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: bottomPad > 0 ? 8 : safePad + 8,
      ),
      decoration: const BoxDecoration(color: neuSurface),
      child: Row(
        children: [
          Expanded(
            child: Container(
              // Sunken well — reads as a field carved into the bar.
              decoration: neuBox(radius: 24, pressed: true),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onChanged: _onTextChanged,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.isSupport ? s.describeIssue : s.typeMessage,
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 15,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 42,
              height: 42,
              // Raised gold disc: the one thing on this bar that should
              // look pressable.
              decoration: neuBox(radius: 21).copyWith(
                color: _gold,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    offset: const Offset(4, 4),
                    blurRadius: 10,
                  ),
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.25),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  // ── Message bubble ──────────────────────────────────────────────────

  Widget _buildBubble({
    required String text,
    required bool isMe,
    required DateTime time,
    required bool isRead,
  }) {
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    // Entrance: fade + rise + a slight scale, drifting in from the sender's
    // own side so a reply visibly arrives from the other person.
    return _BubbleEntrance(
      key: ValueKey('$text-${time.millisecondsSinceEpoch}-$isMe'),
      fromRight: isMe,
      child: _bubbleBody(text, isMe, timeStr, isRead),
    );
  }

  Widget _bubbleBody(String text, bool isMe, String timeStr, bool isRead) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.isSupport
                    ? _gold.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              child: Center(
                child: widget.isSupport
                    ? Icon(Icons.support_agent_rounded, size: 13, color: _gold)
                    : Text(
                        widget.avatarInitial ??
                            (widget.recipientName.isNotEmpty
                                ? widget.recipientName[0].toUpperCase()
                                : (_myRole == 'driver' ? 'R' : 'D')),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              // Raised bubbles: mine in gold, theirs on the neu surface.
              // The tail corner stays square so it still reads as coming
              // from its sender.
              decoration: BoxDecoration(
                color: isMe ? _gold : neuSurface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isMe ? 18 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 18),
                ),
                border: isMe
                    ? null
                    : Border.all(color: Colors.white.withValues(alpha: 0.04)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    offset: const Offset(4, 4),
                    blurRadius: 10,
                  ),
                  if (!isMe)
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.035),
                      offset: const Offset(-3, -3),
                      blurRadius: 8,
                    ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      color: isMe ? Colors.black : Colors.white,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 10,
                          color: isMe
                              ? Colors.black.withValues(alpha: 0.45)
                              : Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                      // Read receipt checkmarks (only on sent messages)
                      if (isMe && _useRtdb) ...[
                        const SizedBox(width: 4),
                        Icon(
                          isRead ? Icons.done_all_rounded : Icons.done_rounded,
                          size: 14,
                          color: isRead
                              ? const Color(0xFF4FC3F7)
                              : Colors.black.withValues(alpha: 0.4),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isMe) const SizedBox(width: 32),
        ],
      ),
    );
  }
}

/// Lightweight model for support-mode messages (polling fallback).
class _SupportMessage {
  final int id;
  final String text;
  final bool isMe;
  final DateTime time;
  final String senderName;
  final String role; // 'rider' | 'driver' | 'bot' | 'system' | 'dispatch'

  _SupportMessage({
    required this.id,
    required this.text,
    required this.isMe,
    required this.time,
    required this.senderName,
    required this.role,
  });
}

/// One-shot entrance for a chat bubble.
///
/// Plays once, when the bubble first enters the list — the ValueKey the
/// caller builds from the message text and timestamp is what makes Flutter
/// treat an incoming message as a new element rather than a rebuild of an
/// old one. Without that key every message would replay its entrance on
/// each stream tick.
class _BubbleEntrance extends StatefulWidget {
  const _BubbleEntrance({
    super.key,
    required this.child,
    required this.fromRight,
  });

  final Widget child;

  /// Drift in from the sender's own side, so a reply visibly arrives from
  /// the other person rather than simply materialising.
  final bool fromRight;

  @override
  State<_BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<_BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset(widget.fromRight ? 0.14 : -0.14, 0.18),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  late final Animation<double> _scale = Tween<double>(begin: 0.92, end: 1.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: _scale,
          alignment:
              widget.fromRight ? Alignment.centerRight : Alignment.centerLeft,
          child: widget.child,
        ),
      ),
    );
  }
}
