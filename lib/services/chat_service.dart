import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import 'api_service.dart';

bool _isPermissionDenied(Object e) {
  if (e is FirebaseException) {
    return e.code == 'permission-denied';
  }
  return e.toString().contains('permission-denied');
}

/// True when the failure is "this app has no Firebase session", in any of
/// the shapes that takes.
///
/// `permission-denied` alone was not enough. Anonymous sign-in is disabled
/// on this project, so `signInAnonymously()` throws
/// `admin-restricted-operation` — which is not a permission-denied, so the
/// old guards rethrew it, out of an async call nobody was awaiting, into
/// the zone. That is a crash report for a condition the code already knew
/// how to survive: chat falls back to REST polling and carries on.
bool _isNoFirebaseSession(Object e) {
  if (_isPermissionDenied(e)) return true;
  if (e is FirebaseAuthException) return true;
  final s = e.toString();
  return s.contains('admin-restricted-operation') ||
      s.contains('operation-not-allowed') ||
      s.contains('network-request-failed');
}

/// Sign in if there is no session. Returns false instead of throwing.
///
/// Every caller below used to inline `await signInAnonymously()` inside its
/// own try, which meant a sign-in failure took the same path as a failed
/// write and got rethrown.
Future<bool> _ensureSession() async {
  if (FirebaseAuth.instance.currentUser != null) return true;
  try {
    await FirebaseAuth.instance.signInAnonymously();
    return FirebaseAuth.instance.currentUser != null;
  } catch (e) {
    debugPrint('[ChatService] no Firebase session: $e');
    return false;
  }
}

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

    // The REST path in ChatScreen is what actually guarantees delivery;
    // RTDB is the fast lane. Losing it costs latency, not the message.
    if (!await _ensureSession()) return;
    try {
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

      // Stop typing indicator after send. Not awaited on purpose — but an
      // unawaited future that throws goes to the zone, not to the catch
      // below, so it gets its own.
      unawaited(
        setTyping(rideId: rideId, role: senderRole, isTyping: false)
            .catchError((Object e) {
          debugPrint('[ChatService] clearing typing failed: $e');
        }),
      );
    } catch (e) {
      if (_isNoFirebaseSession(e)) {
        debugPrint('[ChatService] sendMessage denied for $rideId');
      } else {
        rethrow;
      }
    }
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

  /// Stream of unread message count (messages from the OTHER role that are
  /// unread). Combines two sources so the badge updates even when one fails:
  ///   1. RTDB live stream  — sub-100ms updates, primary source
  ///   2. REST polling      — every 8s, fallback when the driver app sent
  ///                          the message via REST only (RTDB unavailable)
  /// Emits the max of both at any moment so a stale "0" from one side never
  /// hides a real unread on the other.
  Stream<int> unreadCountStream({
    required String rideId,
    required String readerRole,
  }) {
    final controller = StreamController<int>.broadcast();
    int rtdbCount = 0;
    int restCount = 0;
    void emit() {
      if (!controller.isClosed) {
        controller.add(rtdbCount > restCount ? rtdbCount : restCount);
      }
    }

    // ── Source 1: RTDB live ─────────────────────────────────────
    StreamSubscription<DatabaseEvent>? rtdbSub;
    try {
      rtdbSub = _db
          .ref('chats/$rideId/messages')
          .orderByChild('read')
          .equalTo(false)
          .onValue
          .listen(
        (event) {
          if (event.snapshot.value == null) {
            rtdbCount = 0;
          } else {
            final data =
                Map<String, dynamic>.from(event.snapshot.value as Map);
            rtdbCount = data.values.where((v) {
              final msg = Map<String, dynamic>.from(v as Map);
              return msg['senderRole'] != readerRole;
            }).length;
          }
          emit();
        },
        onError: (e) {
          debugPrint('[Chat] unread RTDB error: $e — REST fallback only');
        },
      );
    } catch (e) {
      debugPrint('[Chat] unread RTDB setup failed: $e');
    }

    // ── Source 2: REST polling ──────────────────────────────────
    final tripId = int.tryParse(rideId);
    Timer? pollTimer;
    Future<void> pollOnce() async {
      if (tripId == null) return;
      try {
        // peek=true so we don't auto-mark messages as read just by polling
        // the count — that would zero the badge before the rider opens
        // the chat.
        final messages =
            await ApiService.getChatMessages(tripId, peek: true);
        restCount = messages.where((m) {
          final senderRole = (m['sender_role'] ?? m['senderRole'] ?? '')
              .toString()
              .toLowerCase();
          final read = (m['is_read'] ?? m['read']) == true;
          return !read && senderRole != readerRole;
        }).length;
        emit();
      } catch (_) {
        // Silently keep last value — RTDB is still trying.
      }
    }

    if (tripId != null) {
      // Kick off immediately, then every 8s for the lifetime of the stream.
      pollOnce();
      pollTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => pollOnce(),
      );
    }

    controller.onCancel = () {
      rtdbSub?.cancel();
      pollTimer?.cancel();
    };

    return controller.stream;
  }

  // ── Typing ────────────────────────────────────────────────────────────────

  /// Set typing indicator for the current user's role.
  Future<void> setTyping({
    required String rideId,
    required String role,
    required bool isTyping,
  }) async {
    // A typing dot is the most disposable thing in the app. It is never
    // worth an exception.
    if (!await _ensureSession()) return;
    try {
      await _db.ref('chats/$rideId/typing/$role').set(isTyping);
    } catch (e) {
      if (_isNoFirebaseSession(e)) {
        debugPrint('[ChatService] setTyping denied for $rideId/$role');
      } else {
        rethrow;
      }
    }
  }

  /// Stream the other person's typing state.
  Stream<bool> typingStream({
    required String rideId,
    required String otherRole,
  }) {
    return _db
        .ref('chats/$rideId/typing/$otherRole')
        .onValue
        // A rejected listener throws into the zone the same way a rejected
        // write does, and this one is watching a dot.
        .handleError((Object e) {
          debugPrint('[ChatService] typing stream rejected: $e');
        })
        .map((e) => (e.snapshot.value as bool?) ?? false);
  }

  // ── Read receipts ─────────────────────────────────────────────────────────

  /// Mark all unread messages from the OTHER person as read.
  Future<void> markAsRead({
    required String rideId,
    required String readerRole,
  }) async {
    if (!await _ensureSession()) return;
    try {
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
    } catch (e) {
      if (_isPermissionDenied(e)) {
        debugPrint('[ChatService] markAsRead permission denied for $rideId');
      } else {
        rethrow;
      }
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
