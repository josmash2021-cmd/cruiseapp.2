import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/neu_style.dart';
import '../home_screen.dart';

/// Driver Inbox – tabs: All, Messages, Alerts.
class DriverInboxScreen extends StatefulWidget {
  const DriverInboxScreen({super.key});

  @override
  State<DriverInboxScreen> createState() => _DriverInboxScreenState();
}

class _DriverInboxScreenState extends State<DriverInboxScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);

  late final TabController _tabCtrl;
  bool _loading = true;
  List<_InboxItem> _items = [];

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _tabCtrl = TabController(length: 3, vsync: this);
    _fetchNotifications();
  }

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  Future<void> _fetchNotifications() async {
    setState(() => _loading = true);
    try {
      final notifs = await ApiService.getNotifications();
      if (!mounted) return;
      setState(() {
        _items = notifs.map((n) {
          final type = _typeFromString((n['notif_type'] ?? 'alert') as String);
          return _InboxItem(
            id: (n['id'] as num?)?.toInt() ?? 0,
            type: type,
            title: (n['title'] ?? '') as String,
            body: (n['body'] ?? '') as String,
            time: _formatTime((n['created_at'] ?? '') as String),
            icon: _iconForType(type),
            iconColor: _colorForType(type),
            unread: n['is_read'] != true,
          );
        }).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  InboxType _typeFromString(String s) {
    switch (s) {
      case 'message':
        return InboxType.message;
      default:
        return InboxType.alert;
    }
  }

  IconData _iconForType(InboxType t) {
    switch (t) {
      case InboxType.message:
        return Icons.support_agent_rounded;
      case InboxType.alert:
        return Icons.trending_up_rounded;
    }
  }

  Color _colorForType(InboxType t) {
    switch (t) {
      case InboxType.message:
        return const Color(0xFF2196F3);
      case InboxType.alert:
        return const Color(0xFF4CAF50);
    }
  }

  /// How long ago, in the phone's language.
  ///
  /// Past the hour it carries the minutes with it — "1 h 5 min", not
  /// "1h". A driver reading why their rating moved is trying to match the
  /// notice to a trip they remember, and an hour rounded off matches
  /// nothing. Every string was also hardcoded English until now.
  String _formatTime(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final s = S.of(context);
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative || diff.inMinutes < 1) return s.agoJustNow;
    if (diff.inMinutes < 60) return s.agoMinutes(diff.inMinutes);
    if (diff.inHours < 24) {
      final mins = diff.inMinutes % 60;
      return mins == 0
          ? s.agoHours(diff.inHours)
          : s.agoHoursMinutes(diff.inHours, mins);
    }
    if (diff.inDays == 1) return s.agoYesterday;
    if (diff.inDays < 7) return s.agoDays(diff.inDays);
    // "Last week" stayed on screen for a notice from four months back.
    return s.agoWeeks((diff.inDays / 7).floor());
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  List<_InboxItem> _filtered(int tabIndex) {
    switch (tabIndex) {
      case 1:
        return _items.where((i) => i.type == InboxType.message).toList();
      case 2:
        return _items.where((i) => i.type == InboxType.alert).toList();
      default:
        return _items;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      // neuBase, not pure black: neumorphic shadows are two lights, one dark
      // and one pale, and over #000000 the dark one has nowhere to go — every
      // raised surface flattens into the background.
      backgroundColor: neuBase,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 20),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    s.inbox,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () async {
                      HapticService.selectionClick();
                      setState(() {
                        for (final i in _items) {
                          i.unread = false;
                        }
                      });
                      try {
                        await ApiService.markAllNotificationsRead();
                      } catch (_) {}
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: neuBox(radius: 12),
                      child: Text(
                        s.markAllRead,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Tab bar ──
            Container(
              height: 38,
              margin: const EdgeInsets.symmetric(horizontal: 20),
              child: TabBar(
                controller: _tabCtrl,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: _gold,
                unselectedLabelColor: Colors.white.withValues(alpha: 0.5),
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                // The selected filter is a raised neu plate with a gold rim,
                // not a white slab. A solid white pill was the brightest
                // thing on a screen whose content is the point.
                indicator: neuBox(
                  radius: 20,
                  borderColor: _gold.withValues(alpha: 0.30),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                padding: EdgeInsets.zero,
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                tabs: [
                  _tabChip(s.allFilter, _items.where((i) => i.unread).length),
                  _tabChip(
                    s.messages,
                    _items
                        .where((i) => i.type == InboxType.message && i.unread)
                        .length,
                  ),
                  _tabChip(
                    s.alertsTab,
                    _items
                        .where((i) => i.type == InboxType.alert && i.unread)
                        .length,
                  ),
                  // Updates and Deals are gone. The backend has never sent a
                  // notif_type of "update" or "deal" — it sends level_up,
                  // level_down, trip, driver_report, refund_request and
                  // account_deletion — so both tabs were guaranteed empty
                  // from the day they were added, and an empty tab is a
                  // promise the app cannot keep.
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Content ──
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: List.generate(3, (tabIndex) {
                  if (_loading) {
                    return const Center(
                      child: CircularProgressIndicator(color: _gold),
                    );
                  }
                  final items = _filtered(tabIndex);
                  if (items.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inbox_rounded,
                            color: Colors.white.withValues(alpha: 0.15),
                            size: 56,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.noMessages,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.3),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemExtent: 88,
                    itemCount: items.length,
                    itemBuilder: (_, i) => TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 300 + (i * 50)),
                      curve: Curves.easeOut,
                      builder: (context, value, child) => Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, 16 * (1 - value)),
                          child: child,
                        ),
                      ),
                      child: _buildItem(items[i]),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip(String label, int count) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Color(0xFF2196F3),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(_InboxItem item) {
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        if (item.unread) {
          setState(() => item.unread = false);
          if (item.id > 0) {
            ApiService.markNotificationRead(item.id).catchError((_) => null);
          }
        }
        _showItemDetail(item);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(16),
        // Unread is raised with a gold rim; read is the same plate pressed
        // into the page. Depth carries the state, so the row still reads as
        // unread at a glance without a second colour doing the work.
        decoration: item.unread
            ? neuBox(radius: 16, borderColor: _gold.withValues(alpha: 0.28))
            : neuBox(radius: 16, pressed: true),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              // A sunken well, the established place for an icon in this
              // system — the tinted square it replaces was the only flat
              // colour left on the row.
              decoration: neuBox(radius: 13, pressed: true),
              child: Icon(item.icon, color: item.iconColor, size: 22),
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
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight:
                                item.unread ? FontWeight.w800 : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.unread)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF2196F3),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.body,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 13,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.time,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.25),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
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

  void _showItemDetail(_InboxItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: item.iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(item.icon, color: item.iconColor, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              item.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              item.time,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              item.body,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 15,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

enum InboxType { message, alert }

class _InboxItem {
  final int id;
  final InboxType type;
  final String title;
  final String body;
  final String time;
  final IconData icon;
  final Color iconColor;
  bool unread;

  _InboxItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.time,
    required this.icon,
    required this.iconColor,
    required this.unread,
  });
}
