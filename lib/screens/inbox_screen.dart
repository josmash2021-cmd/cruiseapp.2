import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';
import '../widgets/verified_avatar.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            // ── Back button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: c.textPrimary,
                    size: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                s.inbox,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Tabs ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller: _tabCtrl,
                  indicator: BoxDecoration(
                    color: const Color(0xFF2A2D38),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(3),
                  dividerColor: Colors.transparent,
                  labelColor: c.textPrimary,
                  unselectedLabelColor: c.textSecondary,
                  labelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  tabs: [
                    Tab(text: s.notifications),
                    Tab(text: s.messages),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Tab content ──
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _NotificationsTab(c: c),
                  _MessagesTab(c: c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Notifications tab — reads from LocalDataService ──
class _NotificationsTab extends StatefulWidget {
  final AppColors c;
  const _NotificationsTab({required this.c});
  @override
  State<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<_NotificationsTab> {
  static const _gold = Color(0xFFE8C547);

  List<AppNotificationItem> _notifications = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await LocalDataService.getNotifications();
    if (!mounted) return;
    // If no saved notifications, seed a welcome one
    if (items.isEmpty) {
      await LocalDataService.addNotification(
        title: 'Welcome to Cruise!',
        message: 'Enjoy 15% off your first 3 rides. Use code CRUISE15.',
        type: 'promo',
      );
      final seeded = await LocalDataService.getNotifications();
      if (!mounted) return;
      setState(() {
        _notifications = seeded;
        _loading = false;
      });
    } else {
      setState(() {
        _notifications = items;
        _loading = false;
      });
    }
  }

  Future<void> _markAllRead() async {
    await LocalDataService.markNotificationsAsRead();
    await _load();
  }

  Future<void> _dismiss(int index) async {
    setState(() => _notifications.removeAt(index));
    // Persist the updated list
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'notifications_v1',
      jsonEncode(_notifications.map((n) => n.toJson()).toList()),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'promo':
        return Icons.local_offer_rounded;
      case 'safety':
        return Icons.shield_outlined;
      case 'payment':
        return Icons.credit_card_rounded;
      case 'trip':
        return Icons.directions_car_rounded;
      case 'update':
        return Icons.update_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = widget.c;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_notifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_off_outlined,
              color: c.textTertiary,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              s.noNotifications,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.allCaughtUp,
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
          ],
        ),
      );
    }

    final hasUnread = _notifications.any((n) => !n.read);

    return Column(
      children: [
        if (hasUnread)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: _markAllRead,
                child: Text(
                  s.markAllRead,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _gold,
                  ),
                ),
              ),
            ),
          ),
        if (hasUnread) const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            cacheExtent: 300,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: _notifications.length,
            itemBuilder: (ctx, i) {
              final item = _notifications[i];
              return Dismissible(
                key: Key(item.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                onDismissed: (_) => _dismiss(i),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: item.read
                          ? null
                          : Border.all(color: _gold.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: !item.read
                                ? _gold.withValues(alpha: 0.12)
                                : c.bg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _iconForType(item.type),
                            color: !item.read ? _gold : c.textSecondary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.title,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: item.read
                                            ? FontWeight.w600
                                            : FontWeight.w700,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (!item.read)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: const BoxDecoration(
                                        color: _gold,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.message,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: c.textSecondary,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _timeAgo(item.createdAt),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Messages tab — reads from Firestore inbox_chats ──
class _MessagesTab extends StatefulWidget {
  final AppColors c;
  const _MessagesTab({required this.c});

  @override
  State<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<_MessagesTab> {
  static const _gold = Color(0xFFE8C547);

  String get _uid => UserSession.currentUid;
  String get _docId => 'sql_$_uid';

  StreamSubscription? _chatSub;
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cleanExpiredChats();
    _attachListener();
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    super.dispose();
  }

  void _attachListener() {
    if (_uid.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    _chatSub?.cancel();
    _chatSub = FirebaseFirestore.instance
        .collection('users')
        .doc(_docId)
        .collection('inbox_chats')
        .orderBy('createdAt', descending: true)
        .limit(30)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final now = Timestamp.now();
      setState(() {
        _chats = snap.docs
            .map((d) {
              final data = d.data();
              data['id'] = d.id;
              return data;
            })
            .where((chat) {
              final expiresAt = chat['expiresAt'] as Timestamp?;
              return expiresAt == null || expiresAt.compareTo(now) > 0;
            })
            .toList();
        _loading = false;
      });
    }, onError: (e) {
      debugPrint('[Inbox] messages listener error: $e');
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _cleanExpiredChats() async {
    if (_uid.isEmpty) return;
    try {
      final expired = await FirebaseFirestore.instance
          .collection('users')
          .doc(_docId)
          .collection('inbox_chats')
          .where('expiresAt', isLessThan: Timestamp.now())
          .get();

      if (expired.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in expired.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    } catch (e) {
      debugPrint('[Inbox] cleanup error: $e');
    }
  }

  String _timeRemaining(Timestamp expiresAt) {
    final diff = expiresAt.toDate().difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inHours > 0) {
      return 'Expires in ${diff.inHours}h ${diff.inMinutes % 60}m';
    }
    return 'Expires in ${diff.inMinutes}m';
  }

  String _formatDate(Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate();
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _openConversation(Map<String, dynamic> chat) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ConversationDetailScreen(chat: chat),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = widget.c;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }

    if (_chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade600),
              const SizedBox(height: 16),
              Text(
                s.noMessagesYet,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.messagesWillAppear,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: c.textSecondary, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: _chats.length,
      itemBuilder: (ctx, i) {
        final chat = _chats[i];
        final driverName = chat['driverName'] as String? ?? 'Driver';
        final lastMsg = chat['lastMessage'] as String? ?? '';
        final msgCount = chat['messageCount'] as int? ?? 0;
        final driverPhoto = chat['driverPhotoUrl'] as String? ?? '';
        final expiresAt = chat['expiresAt'] as Timestamp?;
        final createdAt = chat['createdAt'] as Timestamp?;

        return GestureDetector(
          onTap: () => _openConversation(chat),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                // Driver avatar
                VerifiedAvatar(
                  photoUrl: driverPhoto.isNotEmpty ? driverPhoto : null,
                  radius: 22,
                  fallbackName: driverName,
                  uid: (chat['driverId'] ?? chat['driver_id'])?.toString(),
                  role: 'driver',
                  isVerified: false,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              driverName.split(' ').first,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: c.textPrimary,
                              ),
                            ),
                          ),
                          if (msgCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$msgCount',
                                style: const TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        lastMsg,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textSecondary),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            _formatDate(createdAt),
                            style: TextStyle(fontSize: 11, color: c.textTertiary),
                          ),
                          const Spacer(),
                          if (expiresAt != null)
                            Text(
                              _timeRemaining(expiresAt),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange.shade300,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full conversation detail screen — read-only view of trip chat messages.
class _ConversationDetailScreen extends StatelessWidget {
  final Map<String, dynamic> chat;
  const _ConversationDetailScreen({required this.chat});

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final driverName = (chat['driverName'] as String? ?? 'Driver').split(' ').first;
    final messages = (chat['messages'] as List<dynamic>?) ?? [];

    // Sort by timestamp
    final sorted = List<Map<String, dynamic>>.from(
      messages.map((m) => Map<String, dynamic>.from(m as Map)),
    )..sort((a, b) =>
        ((a['timestamp'] as int?) ?? 0).compareTo((b['timestamp'] as int?) ?? 0));

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: c.textPrimary, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          driverName,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: c.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: sorted.isEmpty
          ? Center(
              child: Text(
                'No messages in this conversation',
                style: TextStyle(color: c.textSecondary),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: sorted.length,
              itemBuilder: (ctx, i) {
                final msg = sorted[i];
                final isDriver = msg['senderRole'] == 'driver';
                final text = msg['text'] as String? ?? '';
                final ts = msg['timestamp'] as int? ?? 0;
                final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                final time = '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';

                return Align(
                  alignment: isDriver ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDriver
                          ? c.surface
                          : _gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(14),
                        topRight: const Radius.circular(14),
                        bottomLeft: Radius.circular(isDriver ? 4 : 14),
                        bottomRight: Radius.circular(isDriver ? 14 : 4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: isDriver
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.end,
                      children: [
                        Text(
                          text,
                          style: TextStyle(
                            fontSize: 14,
                            color: c.textPrimary,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 10,
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
