/// A single chat message between driver and rider (stored in Firebase RTDB).
class ChatMessage {
  final String id;
  final String senderId;
  final String senderRole;
  final String text;
  final int timestamp;
  final bool read;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderRole,
    required this.text,
    required this.timestamp,
    required this.read,
  });

  factory ChatMessage.fromMap(String id, Map<String, dynamic> map) {
    return ChatMessage(
      id: id,
      senderId: (map['senderId'] ?? '').toString(),
      senderRole: (map['senderRole'] ?? '') as String,
      text: (map['text'] ?? '') as String,
      timestamp: (map['timestamp'] as int?) ?? 0,
      read: (map['read'] as bool?) ?? false,
    );
  }

  bool get isDriver => senderRole == 'driver';
}
