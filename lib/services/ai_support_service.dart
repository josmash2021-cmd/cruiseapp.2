import 'dart:math';
import 'package:flutter/foundation.dart';
import '../config/agent_prompts.dart';

/// Service that wraps AI agent logic for the support chat.
///
/// All AI calls route through the existing backend support chat endpoints.
/// The backend handles bot replies, agent assignment, and phase transitions.
/// This service provides helper utilities for the frontend chat experience.
class AiSupportService {
  AiSupportService._();

  static final _rng = Random();

  /// Pick a random agent name from the pool.
  static String randomAgentName() {
    return AgentPrompts.agentNames[_rng.nextInt(AgentPrompts.agentNames.length)];
  }

  /// Calculate a realistic typing delay in milliseconds based on message length.
  /// Simulates ~25 characters per second with ±25% variance.
  static int typingDuration(String message) {
    final baseTime = ((message.length / 25).ceil() * 1000);
    final variance = _rng.nextInt((baseTime * 0.5).toInt().clamp(1, 10000)) -
        (baseTime * 0.25).toInt();
    return (baseTime + variance).clamp(3000, 20000);
  }

  /// How long the connecting indicator stays up, in seconds.
  ///
  /// Not random any more, and not the decision. The server inserts the "has
  /// joined the chat" row 8 s after announcing the handoff
  /// (_SUPERVISOR_JOINS_AFTER_S in backend/routers/support.py) and that row
  /// is what ends the wait. This number only has to match it so the
  /// indicator does not vanish before any supervisor exists.
  static int randomQueueWait() => 8;

  /// Whether a bot message signals "connecting to agent" (detecting phase transition).
  static bool isConnectingMessage(String text) {
    final lower = text.toLowerCase();
    return lower.contains('conectarte con un agente') ||
        lower.contains('transferi') ||
        lower.contains('connecting you') ||
        lower.contains('transferring you') ||
        lower.contains('connect you with') ||
        lower.contains('voy a conectarte');
  }

  /// Whether a system message signals an agent joined the chat.
  static bool isAgentJoinedMessage(String text) {
    final lower = text.toLowerCase();
    return lower.contains('se ha conectado') ||
        lower.contains('se unió al chat') ||
        lower.contains('has joined the chat') ||
        lower.contains('joined the chat');
  }

  /// Detect if a message contains a split marker.
  static List<String> splitResponse(String text) {
    return text
        .split('||SPLIT||')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Determine agent type based on user type and trip context.
  static String getAgentType({
    required String userType,
    bool hasActiveTrip = false,
    bool tripHasIssue = false,
  }) {
    if (hasActiveTrip && tripHasIssue) {
      return AgentPrompts.tripResolution;
    }
    if (userType == 'driver') {
      return AgentPrompts.driverSupport;
    }
    return AgentPrompts.riderSupport;
  }
}
