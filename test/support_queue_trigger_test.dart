import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/services/ai_support_service.dart';

/// The fake-queue trigger, pinned (user report 2026-10-04: every fresh
/// chat opened into "Finding an agent…" with the options hidden).
///
/// The old pattern list matched the WELCOME itself ("…I'll connect you
/// with an agent") and any casual AI text containing "transferi". Only the
/// backend's REAL escalation lines may open the agent queue now.
void main() {
  group('isConnectingMessage', () {
    test('never fires on the welcome messages', () {
      const welcomes = [
        "Hi Apple, I'm Sofia, your Cruise AI assistant. I can help with your payments and holds, your trips and stops, and your account. Tell me what happened. If I can't resolve it, I'll connect you with an agent.",
        "Hi Apple, I'm Sofia, your Cruise AI assistant. How can I help you today? Pick an option below or tell me what the problem is.",
        "Hi Apple, I'm Diego, your Cruise AI assistant for drivers. How can I help you today? Pick an option below or tell me what the problem is.",
        "Hola Apple, soy Sofia, tu asistente de IA de Cruise. ¿Cómo te puedo ayudar hoy? Elige una opción abajo o cuéntame cuál es el problema.",
      ];
      for (final w in welcomes) {
        expect(AiSupportService.isConnectingMessage(w), isFalse,
            reason: 'the welcome must NEVER open the queue: $w');
      }
    });

    test('never fires on casual AI conversation', () {
      const casual = [
        'I can help you with that — the hold is released automatically.',
        'Te explico: el hold se libera solo si el viaje no sucede.',
        'I can transfer your call reference to the trip if you want.',
        '¿Quieres que te cuente cómo funciona el tier de tu carro?',
      ];
      for (final c in casual) {
        expect(AiSupportService.isConnectingMessage(c), isFalse,
            reason: 'casual AI text must not fake a queue: $c');
      }
    });

    test('fires on the REAL escalation lines', () {
      const escalations = [
        'No te preocupes, Apple. Ya te transfiero a un agente especializado que te atenderá personalmente.',
        "Don't worry, Apple. I'm transferring you to a specialized agent who will assist you personally.",
        'Voy a conectarte de inmediato con un supervisor que podra resolver tu caso directamente.',
        "I'm connecting you right away with a supervisor who can resolve your case directly.",
        'He escalado tu caso al equipo de seguridad, Apple.',
        "I've escalated your case to the safety team, Apple.",
      ];
      for (final e in escalations) {
        expect(AiSupportService.isConnectingMessage(e), isTrue,
            reason: 'a real escalation must open the queue: $e');
      }
    });
  });
}
