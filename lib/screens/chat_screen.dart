import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/chat_message.dart';
import '../services/api_service.dart';
import '../services/chat_service.dart';
import '../services/error_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;

/// Full-page chat screen — real-time via Firebase RTDB for trip chats,
/// REST API polling for support chat.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.recipientName,
    this.recipientPhone,
    this.isSupport = false,
    this.avatarInitial,
    this.tripId,
    this.currentUserId,
    this.currentRole,
  });

  /// The trip ID of the currently active chat screen (if any).
  /// Used to suppress push notifications while the user is in this chat.
  static int? activeTripId;

  final String recipientName;
  final String? recipientPhone;
  final bool isSupport;
  final String? avatarInitial;
  final int? tripId;

  /// Current user's ID (as String). If null, resolved from ApiService.
  final String? currentUserId;

  /// 'driver' or 'rider'. If null, defaults to 'rider'.
  final String? currentRole;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static final _nonPhoneCharRe = RegExp(r'[^0-9+]');
  static const _gold = Color(0xFFE8C547);
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _chat = ChatService();

  String _myUserId = '';
  String _myRole = 'rider';
  String get _otherRole => _myRole == 'driver' ? 'rider' : 'driver';
  String get _rideId => widget.tripId?.toString() ?? '';

  bool _useRtdb = false; // true for trip chats, false for support
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

  // ── REST fallback messages (used when RTDB fails) ──
  final List<ChatMessage> _restMessages = [];
  Timer? _restPollTimer;

  // ── Typing ──
  Timer? _typingTimer;
  String? _recipientPhone;
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
    _recipientPhone = widget.recipientPhone?.trim();

    // Resolve user ID
    if (widget.currentUserId != null && widget.currentUserId!.isNotEmpty) {
      _myUserId = widget.currentUserId!;
    } else {
      final id = await ApiService.getCurrentUserId();
      _myUserId = (id ?? 0).toString();
    }
    _myRole = widget.currentRole ?? 'rider';

    // Ensure Firebase Auth is signed in so RTDB rules (auth != null) pass
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (e) {
      debugPrint('[Chat] Firebase Auth sign-in failed: $e');
    }

    // Decide mode: RTDB for trip chats, polling for support
    if (!widget.isSupport && widget.tripId != null) {
      _useRtdb = true;
      _startConnectionListener();
      // Mark existing messages as read when opening
      _chat.markAsRead(rideId: _rideId, readerRole: _myRole);
      if ((_recipientPhone ?? '').isEmpty) {
        unawaited(_resolveRecipientPhone());
      }
    } else if (widget.isSupport) {
      _useRtdb = false;
      await _initSupportChat();
    }

    _chatReady = true;
    if (mounted) setState(() {});
  }

  // ── Support chat init + polling ────────────────────────────────────────

  Future<void> _initSupportChat() async {
    try {
      final locale = Localizations.localeOf(context).languageCode;
      final result = await ApiService.createSupportChat(locale: locale);
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
      final msgs = await ApiService.getSupportMessages(chatId);
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

      final newCount = parsed.length;
      if (newCount != _supportMessages.length) {
        final hasNewBotMsg = parsed.any((m) => !m.isMe);
        setState(() {
          _supportMessages
            ..clear()
            ..addAll(parsed);
          if (hasNewBotMsg) _agentTyping = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[Chat] Support poll error: $e');
    }
  }

  Future<void> _resolveRecipientPhone() async {
    final tripId = widget.tripId;
    if (tripId == null) return;
    try {
      final status = await ApiService.getDispatchStatus(tripId);
      final trip = (status['trip'] is Map)
          ? Map<String, dynamic>.from((status['trip'] as Map).cast<String, dynamic>())
          : <String, dynamic>{};
      final isDriver = _myRole == 'driver';
      final resolved = (isDriver
              ? (trip['rider_phone'] ?? trip['passengerPhone'] ?? trip['passenger_phone'])
              : (trip['driver_phone'] ?? trip['driverPhone']))
          ?.toString()
          .trim();
      if (!mounted || resolved == null || resolved.isEmpty) return;
      setState(() => _recipientPhone = resolved);
    } catch (_) {}
  }

  @override
  void dispose() {
    ChatScreen.activeTripId = null;
    _pollTimer?.cancel();
    _typingTimer?.cancel();
    _restPollTimer?.cancel();
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
  }

  Future<void> _fetchRestMessages() async {
    if (widget.tripId == null) return;
    try {
      final msgs = await ApiService.getChatMessages(widget.tripId!);
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

    if (!_chatReady) {
      debugPrint('[Chat] send blocked — chat not ready yet');
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
            await ApiService.sendChatMessage(tripId: widget.tripId!, message: text);
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

      try {
        await _chat.sendMessage(
          rideId: _rideId,
          senderId: _myUserId,
          senderRole: _myRole,
          text: text,
        );
        // Also notify backend so it sends FCM push to the other person
        if (widget.tripId != null) {
          unawaited(ApiService.sendChatMessage(tripId: widget.tripId!, message: text).catchError((_) => <String, dynamic>{}));
        }
      } catch (e) {
        debugPrint('[Chat] RTDB send failed: $e');
        if (mounted) {
          ErrorService.show(context, S.of(context).messageFailedToSend);
        }
      }
      // Also persist via REST API (triggers FCM push notification to recipient)
      if (widget.tripId != null) {
        try {
          await ApiService.sendChatMessage(tripId: widget.tripId!, message: text);
        } catch (e) {
          debugPrint('[Chat] REST backup send failed: $e');
        }
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
      _scrollToBottom();
      try {
        await ApiService.sendSupportMessage(chatId, text);
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _callRecipient() async {
    HapticService.mediumImpact();
    if ((_recipientPhone ?? '').isEmpty) {
      await _resolveRecipientPhone();
    }
    final phone = (_recipientPhone ?? '').replaceAll(_nonPhoneCharRe, '');
    if (phone.isEmpty) {
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
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
        backgroundColor: Colors.black,
        body: Column(
          children: [
            // ── App bar ──
            _buildAppBar(s, topPad),

            // ── Messages ──
            Expanded(
              child: !_chatReady
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4A843)))
                  : _useRtdb ? _buildRtdbMessages(s) : _buildSupportMessages(s),
            ),

            // ── Typing indicator (RTDB only) ──
            if (_useRtdb) _buildTypingIndicator(s),

            // ── Input bar ──
            _buildInputBar(s, bottomPad, safePad),
          ],
        ),
      ),
    );
  }

  // ── App bar ──────────────────────────────────────────────────────────

  Widget _buildAppBar(S s, double topPad) {
    return Container(
      padding: EdgeInsets.only(top: topPad + 8, bottom: 12, left: 8, right: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1F),
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
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            splashRadius: 22,
          ),
          // Avatar
          Container(
            width: Responsive.w(36),
            height: Responsive.w(36),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.isSupport
                  ? _gold.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.1),
              border: Border.all(
                color: widget.isSupport
                    ? _gold.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
            ),
            child: Center(
              child: widget.isSupport
                  ? Icon(Icons.support_agent_rounded, size: Responsive.sp(18), color: _gold)
                  : Text(
                      widget.avatarInitial ??
                          (widget.recipientName.isNotEmpty
                              ? widget.recipientName[0].toUpperCase()
                              : (_myRole == 'driver' ? 'R' : 'D')),
                      style: TextStyle(
                        fontSize: Responsive.sp(14),
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
            ),
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
          if (!widget.isSupport)
            IconButton(
              onPressed: _callRecipient,
              icon: Icon(Icons.phone_rounded, color: _gold, size: 22),
              splashRadius: 22,
            ),
        ],
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
      stream: _chat.messagesStream(_rideId),
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
        if (_supportMessages.length <= 1 && _supportChatId != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _quickReplies.map((label) => GestureDetector(
                onTap: () {
                  _controller.text = label;
                  _sendMessage();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE8C547).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFFE8C547),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              )).toList(),
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
                            padding: const EdgeInsets.only(left: 36, bottom: 2),
                            child: Text(
                              msg.senderName,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFFE8C547).withValues(alpha: 0.7),
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
        if (_agentTyping)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8, top: 4),
            child: Row(
              children: [
                Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                  ),
                  child: const Center(
                    child: Icon(Icons.support_agent_rounded, size: 13, color: Color(0xFFE8C547)),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(18),
                    ),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 48,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 12),
          Text(
            s.writeToStart,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
            ),
          ),
        ],
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
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1F),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
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
              decoration: const BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
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
              decoration: BoxDecoration(
                color: isMe ? _gold : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isMe ? 18 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 18),
                ),
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
