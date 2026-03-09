import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../l10n/app_localizations.dart';

/// Full-page chat screen used for both driver messaging and support chat.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.recipientName,
    this.recipientPhone,
    this.isSupport = false,
    this.avatarInitial,
    this.tripId,
  });

  final String recipientName;
  final String? recipientPhone;
  final bool isSupport;
  final String? avatarInitial;
  final int? tripId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _gold = Color(0xFFE8C547);
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMessage> _messages = [];
  Timer? _pollTimer;
  int? _myUserId;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat() async {
    _myUserId = await ApiService.getCurrentUserId();
    if (widget.tripId != null) {
      await _fetchMessages();
      // Poll every 3 seconds for new messages
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _fetchMessages(),
      );
    } else if (widget.isSupport) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = S.of(context);
        _messages.add(
          _ChatMessage(text: s.chatWelcome, isMe: false, time: DateTime.now()),
        );
        setState(() {});
      });
    }
  }

  Future<void> _fetchMessages() async {
    if (widget.tripId == null) return;
    try {
      final msgs = await ApiService.getChatMessages(widget.tripId!);
      if (!mounted) return;
      setState(() {
        _messages.clear();
        for (final m in msgs) {
          _messages.add(
            _ChatMessage(
              text: (m['message'] ?? '') as String,
              isMe: m['sender_id'] == _myUserId,
              time:
                  DateTime.tryParse((m['created_at'] ?? '') as String) ??
                  DateTime.now(),
            ),
          );
        }
      });
      _scrollToBottom();
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(_ChatMessage(text: text, isMe: true, time: DateTime.now()));
      _controller.clear();
    });
    _scrollToBottom();

    if (widget.tripId != null) {
      try {
        await ApiService.sendChatMessage(tripId: widget.tripId!, message: text);
      } catch (_) {}
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _callDriver() async {
    HapticFeedback.mediumImpact();
    final phone = widget.recipientPhone;
    if (phone != null && phone.isNotEmpty) {
      final uri = Uri(scheme: 'tel', path: phone);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).viewInsets.bottom;
    final safePad = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0E14),
        body: Column(
          children: [
            // ── App bar ──
            Container(
              padding: EdgeInsets.only(
                top: topPad + 8,
                bottom: 12,
                left: 8,
                right: 8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF161820),
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
                  // Back button
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                    splashRadius: 22,
                  ),
                  // Avatar
                  Container(
                    width: 36,
                    height: 36,
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
                          ? Icon(
                              Icons.support_agent_rounded,
                              size: 18,
                              color: _gold,
                            )
                          : Text(
                              widget.avatarInitial ??
                                  widget.recipientName[0].toUpperCase(),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Name + status
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isSupport
                              ? s.cruiseSupport
                              : widget.recipientName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              widget.isSupport ? s.online : s.activeNow,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Phone call button (only for driver chat)
                  if (!widget.isSupport && widget.recipientPhone != null)
                    IconButton(
                      onPressed: _callDriver,
                      icon: Icon(Icons.phone_rounded, color: _gold, size: 22),
                      splashRadius: 22,
                    ),
                ],
              ),
            ),

            // ── Messages list ──
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  return _buildBubble(msg);
                },
              ),
            ),

            // ── Input bar ──
            Container(
              padding: EdgeInsets.only(
                left: 12,
                right: 8,
                top: 8,
                bottom: bottomPad > 0 ? 8 : safePad + 8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF161820),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: widget.isSupport
                              ? s.describeIssue
                              : s.typeMessage,
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
                      decoration: BoxDecoration(
                        color: _gold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: Colors.black,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(_ChatMessage msg) {
    final isMe = msg.isMe;
    final timeStr =
        '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
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
                            widget.recipientName[0].toUpperCase(),
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
                    msg.text,
                    style: TextStyle(
                      fontSize: 14,
                      color: isMe ? Colors.black : Colors.white,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe
                          ? Colors.black.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.3),
                    ),
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

class _ChatMessage {
  final String text;
  final bool isMe;
  final DateTime time;

  _ChatMessage({required this.text, required this.isMe, required this.time});
}
