import 'local_cache.dart';

/// Last-known support chat + transcript, so CruiseSupportChatScreen can paint
/// its first frame from memory/disk and refresh in the background
/// (2026-10-29 owner spec: "el chat de soporte tiene que abrir al instante").
///
/// Two layers: a process-wide memory map (free, instant) on top of the Hive
/// box behind [LocalCache] (synchronous reads, survives a cold start). Both
/// are written whenever the server answers, never read as truth — the poll
/// that follows replaces anything stale.
class SupportChatCache {
  SupportChatCache._();

  static const _lastKey = 'support_chat:last';
  static String _msgKey(int chatId) => 'support_chat:msgs:$chatId';

  /// Keep the transcript bounded: an old chat can hold hundreds of rows and
  /// the first frame only needs the recent tail.
  static const int maxMessages = 150;

  static Map<String, dynamic>? _memLast;
  static final Map<int, List<Map<String, dynamic>>> _memMsgs = {};

  /// The chat the user last had open: `{id, user_id, agent_name,
  /// agent_avatar, bot_phase, status, role}`. Null when nothing was ever
  /// cached. Callers compare `user_id` with the logged-in account before
  /// painting it — the box outlives a logout.
  static Map<String, dynamic>? lastChat() {
    final mem = _memLast;
    if (mem != null) return mem;
    final raw = LocalCache.get<dynamic>(_lastKey);
    if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);
      _memLast = m;
      return m;
    }
    return null;
  }

  /// Chat id of [lastChat], or null.
  static int? lastChatId() => (lastChat()?['id'] as num?)?.toInt();

  /// Cached raw message rows for [chatId] (same shape the API returns),
  /// oldest first. Empty when nothing is cached. Synchronous.
  static List<Map<String, dynamic>> messages(int chatId) {
    final mem = _memMsgs[chatId];
    if (mem != null) return mem;
    final raw = LocalCache.get<dynamic>(_msgKey(chatId));
    if (raw is List) {
      final list = <Map<String, dynamic>>[
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
      _memMsgs[chatId] = list;
      return list;
    }
    return const [];
  }

  /// Remember the chat payload the server returned for this user.
  static void saveChat(Map<String, dynamic> chat, {required String role}) {
    final id = (chat['id'] as num?)?.toInt();
    if (id == null) return;
    final m = <String, dynamic>{
      'id': id,
      'user_id': chat['user_id']?.toString(),
      'agent_name': chat['agent_name'],
      'agent_avatar': chat['agent_avatar'],
      'bot_phase': chat['bot_phase'],
      'status': chat['status'],
      'role': role,
    };
    _memLast = m;
    // Fire-and-forget: a disk write must never sit on the chat's path.
    LocalCache.set(_lastKey, m).catchError((_) {});
  }

  /// Remember the server's transcript for [chatId]. Only plain JSON values
  /// are stored, so Hive can persist them without adapters.
  static void saveMessages(int chatId, List<dynamic> rows) {
    final list = <Map<String, dynamic>>[
      for (final r in rows)
        if (r is Map)
          <String, dynamic>{
            'id': r['id'],
            'message': r['message'],
            'sender_role': r['sender_role'],
            'sender_name': r['sender_name'],
            'created_at': r['created_at'],
            'is_read': r['is_read'],
          },
    ];
    final tail = list.length > maxMessages
        ? list.sublist(list.length - maxMessages)
        : list;
    _memMsgs[chatId] = tail;
    LocalCache.set(_msgKey(chatId), tail).catchError((_) {});
  }

  /// Drop a chat's transcript (the server closed it and started a new one).
  static void forget(int chatId) {
    _memMsgs.remove(chatId);
    LocalCache.delete(_msgKey(chatId)).catchError((_) {});
    if (lastChatId() == chatId) {
      _memLast = null;
      LocalCache.delete(_lastKey).catchError((_) {});
    }
  }
}
