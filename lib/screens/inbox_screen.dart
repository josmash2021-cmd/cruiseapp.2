import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';

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
  bool _loading = true;

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

// ── Messages tab ──
class _MessagesTab extends StatelessWidget {
  final AppColors c;
  const _MessagesTab({required this.c});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              color: c.textTertiary,
              size: 56,
            ),
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
              style: TextStyle(
                fontSize: 14,
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}
