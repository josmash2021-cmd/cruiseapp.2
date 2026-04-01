import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';

/// Singleton service for real-time chat between driver and rider using
/// Firebase Realtime Database. Messages are delivered in < 100ms.
///
/// RTDB structure:
/// ```
/// chats/{rideId}/messages/{msgId}: { senderId, senderRole, text, timestamp, read }
/// chats/{rideId}/typing/{driver|rider}: bool
/// chats/{rideId}/lastMessage: String
/// chats/{rideId}/lastTimestamp: int
/// ```
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final _db = FirebaseDatabase.instance;

  // ── Send ──────────────────────────────────────────────────────────────────

  /// Send a message. Returns immediately — Firebase handles delivery.
  Future<void> sendMessage({
    required String rideId,
    required String senderId,
    required String senderRole,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final chatRef = _db.ref('chats/$rideId');
    final msgRef = chatRef.child('messages').push();

    // Write message + update last-message metadata in one multi-path update
    // for atomicity.
    await _db.ref().update({
      'chats/$rideId/messages/${msgRef.key}/senderId': senderId,
      'chats/$rideId/messages/${msgRef.key}/senderRole': senderRole,
      'chats/$rideId/messages/${msgRef.key}/text': trimmed,
      'chats/$rideId/messages/${msgRef.key}/timestamp': ServerValue.timestamp,
      'chats/$rideId/messages/${msgRef.key}/read': false,
      'chats/$rideId/lastMessage': trimmed,
      'chats/$rideId/lastTimestamp': ServerValue.timestamp,
    });

    // Stop typing indicator after send
    setTyping(rideId: rideId, role: senderRole, isTyping: false);
  }

  // ── Streams ───────────────────────────────────────────────────────────────

  /// Real-time stream of all messages in a chat, ordered by timestamp.
  Stream<List<ChatMessage>> messagesStream(String rideId) {
    return _db
        .ref('chats/$rideId/messages')
        .orderByChild('timestamp')
        .limitToLast(200)
        .onValue
        .map((event) {
      if (event.snapshot.value == null) return <ChatMessage>[];
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      return data.entries
          .map((e) =>
              ChatMessage.fromMap(e.key, Map<String, dynamic>.from(e.value as Map)))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    });
  }

  /// Stream of unread message count (messages from the OTHER role that are unread).
  Stream<int> unreadCountStream({
    required String rideId,
    required String readerRole,
  }) {
    return _db
        .ref('chats/$rideId/messages')
        .orderByChild('read')
        .equalTo(false)
        .onValue
        .map((event) {
      if (event.snapshot.value == null) return 0;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      return data.values.where((v) {
        final msg = Map<String, dynamic>.from(v as Map);
        return msg['senderRole'] != readerRole;
      }).length;
    });
  }

  // ── Typing ────────────────────────────────────────────────────────────────

  /// Set typing indicator for the current user's role.
  Future<void> setTyping({
    required String rideId,
    required String role,
    required bool isTyping,
  }) async {
    await _db.ref('chats/$rideId/typing/$role').set(isTyping);
  }

  /// Stream the other person's typing state.
  Stream<bool> typingStream({
    required String rideId,
    required String otherRole,
  }) {
    return _db
        .ref('chats/$rideId/typing/$otherRole')
        .onValue
        .map((e) => (e.snapshot.value as bool?) ?? false);
  }

  // ── Read receipts ─────────────────────────────────────────────────────────

  /// Mark all unread messages from the OTHER person as read.
  Future<void> markAsRead({
    required String rideId,
    required String readerRole,
  }) async {
    final snapshot = await _db
        .ref('chats/$rideId/messages')
        .orderByChild('read')
        .equalTo(false)
        .get();

    if (snapshot.value == null) return;

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    final updates = <String, dynamic>{};

    for (final entry in data.entries) {
      final msg = Map<String, dynamic>.from(entry.value as Map);
      if (msg['senderRole'] != readerRole) {
        updates['chats/$rideId/messages/${entry.key}/read'] = true;
      }
    }

    if (updates.isNotEmpty) {
      await _db.ref().update(updates);
    }
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  /// Delete the entire chat node when a ride ends (keeps RTDB lean).
  Future<void> deleteChat(String rideId) async {
    try {
      await _db.ref('chats/$rideId').remove();
      debugPrint('[Chat] deleted chat for ride $rideId');
    } catch (e) {
      debugPrint('[Chat] deleteChat error: $e');
    }
  }
}
