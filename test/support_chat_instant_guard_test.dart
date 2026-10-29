import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/l10n/app_localizations.dart';

/// Guardian for the 2026-10-29 owner requests around support + cancel:
///  1. Help sheet row reads "Live chat support" / "Chat de soporte en vivo".
///  2. The rider cancel dialog is ONE language (title, body, both buttons all
///     via S.of) with the owner's copy, and the fee body is parameterised so
///     it cannot drift from the backend's 2 min / $5.00 rule.
///  3. The support chat opens instantly: first frame from the on-device cache
///     (no awaited network before the first build), network in the
///     background behind a thin inline strip, chat created lazily on send.
///  4. A "Cruise Support" push tap opens the chat screen directly with the
///     chat id from the payload (background and terminated state).
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final l10n = _read('lib/l10n/app_localizations.dart');
  final help = _read('lib/screens/help_screen.dart');
  final card = _read('lib/widgets/tracking/driver_info_card.dart');
  final buttons = _read('lib/widgets/tracking/trip_action_buttons.dart');
  final mainDart = _read('lib/main.dart');
  final cache = _read('lib/services/support_chat_cache.dart');
  final supportPy = _read('backend/routers/support.py');

  group('1. live chat label', () {
    test('liveChat copy (EN + ES)', () {
      final en = S(const Locale('en'));
      final es = S(const Locale('es'));
      expect(en.liveChat, 'Live chat support');
      expect(es.liveChat, 'Chat de soporte en vivo');
    });

    test('the Help sheet row and the driver menu both use the getter', () {
      expect(help, contains('S.of(context).liveChat'));
      expect(_read('lib/screens/driver/driver_menu_screen.dart'),
          contains('S.of(context).liveChat'));
    });
  });

  group('2. cancel dialog copy and localisation', () {
    test('owner copy, both languages', () {
      final en = S(const Locale('en'));
      final es = S(const Locale('es'));
      expect(es.cancelTripConfirm,
          '¿Estás seguro que quieres cancelar el viaje?');
      expect(en.cancelTripConfirm, 'Are you sure you want to cancel the trip?');
      expect(es.yesCancelTrip, 'Sí, cancelar viaje');
      expect(en.yesCancelTrip, 'Yes, cancel trip');
      expect(es.noContinueTrip, 'No, continuar');
      expect(en.noContinueTrip, 'No, continue');
    });

    test('fee body is localised AND parameterised (fee + free minutes)', () {
      final en = S(const Locale('en'));
      final es = S(const Locale('es'));
      final enBody = en.cancelAfterAssignBody(freeMinutes: 2, fee: '5.00');
      final esBody = es.cancelAfterAssignBody(freeMinutes: 2, fee: '5.00');
      expect(enBody, contains('first 2 minutes'));
      expect(enBody, contains(r'$5.00 cancellation fee'));
      expect(esBody, contains('primeros 2 minutos'));
      expect(esBody, contains(r'tarifa de cancelación de $5.00'));
      expect(esBody, isNot(contains('already on the way')),
          reason: 'the ES body must not fall back to English');
    });

    test('driver_info_card dialog: every string goes through S.of', () {
      expect(card, isNot(contains("'¿Cancelar viaje?'")),
          reason: 'the hardcoded Spanish title is gone');
      expect(card, isNot(contains("'No, continuar'")),
          reason: 'the hardcoded Spanish "No" button is gone');
      expect(card, contains('S.of(context).cancelTripConfirm'));
      expect(card, contains('S.of(context).noContinueTrip'));
      expect(card, contains('S.of(context).yesCancelTrip'));
      expect(
          card,
          contains('S.of(context).cancelAfterAssignBody(\n'
              '                        freeMinutes: kRiderCancelFreeMinutes,\n'
              '                        fee: kRiderCancelFeeUsd,'));
      // Top-level, not static const (CLAUDE.md rule 16: part files).
      expect(card, contains('\nconst int kRiderCancelFreeMinutes = 2;'));
      expect(card, contains("\nconst String kRiderCancelFeeUsd = '5.00';"));
    });

    test('the constants match the backend rule (>2 min → 5.0)', () {
      final trips = _read('backend/routers/trips.py');
      expect(trips, contains('if minutes_elapsed > 2:\n'
          '            cancellation_fee = 5.0'));
    });

    test('trip_action_buttons dialog uses the localised No button', () {
      expect(buttons, contains('S.of(context).noContinueTrip'));
      expect(buttons, contains('S.of(context).cancelTripConfirm'));
      expect(buttons, contains('S.of(context).yesCancelTrip'));
      expect(buttons, isNot(contains("child: Text(\n                  'No',")));
    });

    test('no getter-style cancelAfterAssignBody remains anywhere', () {
      expect(l10n, isNot(contains('String get cancelAfterAssignBody')));
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = _read(f.path);
        expect(src, isNot(contains('cancelAfterAssignBody,')),
            reason: '${f.path} still calls the old getter');
        expect(src, isNot(contains('cancelAfterAssignBody;')),
            reason: '${f.path} still calls the old getter');
      }
    });
  });

  group('3. support chat opens instantly (cache-first)', () {
    test('first frame is hydrated synchronously in initState', () {
      final initState = help.indexOf('  void initState() {',
          help.indexOf('class _CruiseSupportChatScreenState'));
      final initStateEnd = help.indexOf('  @override', initState + 10);
      final body = help.substring(initState, initStateEnd);
      expect(body, contains('_hydrateFromCache();'));
      expect(body, isNot(contains('await ')),
          reason: 'nothing awaited before the first build');
      expect(body.indexOf('_hydrateFromCache();'),
          lessThan(body.indexOf('addPostFrameCallback')),
          reason: 'cache before the network kicks off');
    });

    test('hydration reads cache synchronously, never S.of / network', () {
      final start = help.indexOf('  void _hydrateFromCache() {');
      final end = help.indexOf('\n  }\n', start);
      final body = help.substring(start, end);
      expect(body, contains('SupportChatCache.lastChat()'));
      expect(body, contains('SupportChatCache.messages(id)'));
      expect(body, contains('UserSession.userIdSync()'),
          reason: 'scoped to the logged-in account');
      expect(body, isNot(contains('await ')));
      expect(body, isNot(contains('ApiService.')));
      expect(body, isNot(contains('S.of(')));
    });

    test('the network work runs after the first frame, in _initChat', () {
      expect(help, contains('addPostFrameCallback((_) {\n'
          '      if (!mounted) return;\n'
          '      _initChat();'));
      final start = help.indexOf('  Future<void> _initChat() async {');
      final end = help.indexOf('  Future<bool> _ensureChat() async {');
      final body = help.substring(start, end);
      expect(body, contains('_setState(() => _syncing = true);'));
      expect(body, contains('await ApiService.getSupportChats();'),
          reason: 'open-chat lookup without creating one');
      expect(body, contains('final ok = await _ensureChat();'));
      expect(body, contains('await _loadMessages();'));
      expect(body, contains('_setState(() => _syncing = false);'));
      expect(body, isNot(contains('await ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 4))')));
    });

    test('no full-screen spinner: thin inline strip instead', () {
      expect(help, isNot(contains('_buildLoadingState')));
      expect(help, isNot(contains('_loading')));
      expect(help, contains('if (_syncing) _buildSyncStrip(),'));
      expect(help, contains('Expanded(child: _buildBody()),'));
      expect(help, contains('S.of(context).syncingLabel'));
      expect(S(const Locale('es')).syncingLabel, 'actualizando…');
      expect(S(const Locale('en')).syncingLabel, 'updating…');
    });

    test('chat is created lazily on send / attach, not on open', () {
      final start = help.indexOf('  Future<void> _sendMessage(');
      final end = help.indexOf('  // ── Scroll', start);
      final send = help.substring(start, end);
      expect(send, contains('created = await _ensureChat();'));
      expect(send, isNot(contains('await _initChat()')));
      final up = help.indexOf('  Future<void> _uploadAttachment(');
      final upBody = help.substring(up, help.indexOf('\n  }\n', up));
      expect(upBody, contains('await _ensureChat();'));
      expect(upBody, isNot(contains('await _initChat()')));
      // The lookup-then-bail path: nothing open → no POST on open.
      expect(help, contains('if (!hasOpen) {'));
    });

    test('cache is written on every server answer and scoped per user', () {
      expect(help, contains('SupportChatCache.saveMessages(chatId, msgs);'));
      expect(help, contains('SupportChatCache.saveChat(chat, role: _userRole);'));
      expect(cache, contains("'user_id': chat['user_id']?.toString()"));
      expect(cache, contains('LocalCache.get<dynamic>'),
          reason: 'Hive-backed synchronous reads');
      expect(cache, contains('static const int maxMessages = 150;'));
    });

    test('first server answer merges plainly (push tap shows the message)', () {
      expect(help, contains('final firstSync = !_firstSyncDone;'));
      expect(help, contains('if (!firstSync &&\n'
          '          _phase != _ChatPhase.queue &&'));
    });

    test('house rules: _setState helper, maybeOf outside build', () {
      final cls = help.substring(
          help.indexOf('class _CruiseSupportChatScreenState'));
      expect(cls, contains('void _setState(VoidCallback fn) {\n'
          '    if (mounted) setState(fn);'));
      expect(cls, contains('ScaffoldMessenger.maybeOf(context)?.showSnackBar'));
      expect(cls, contains("Localizations.maybeLocaleOf(context)?.languageCode ?? 'en'"));
    });
  });

  group('4. support push deep link', () {
    test('main.dart passes the chat id from the payload to the screen', () {
      expect(mainDart, contains('_navigateToSupportChat(\n'
          "      chatId: int.tryParse(message.data['chat_id']?.toString() ?? ''),"));
      expect(mainDart, contains('CruiseSupportChatScreen(chatId: chatId)'));
      expect(help, contains('final int? chatId;'));
      expect(help, contains('final id = widget.chatId ?? lastId;'));
    });

    test('terminated state: the push waits for the splash to hand over', () {
      expect(mainDart, contains('bool _isSplashOnTop(NavigatorState nav)'));
      expect(mainDart, contains('_isSplashOnTop(nav)'));
      expect(mainDart, contains('topName == splashRouteName'));
      // Both entry points still route here.
      expect(mainDart, contains('FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap)'));
      expect(mainDart, contains('getInitialMessage().then((msg) {'));
    });

    test('the backend push data carries chat_id for both support types', () {
      expect(supportPy, contains('data={"type": "support_message", "chat_id": str(chat.id)}'));
      expect(supportPy, contains('data={"type": "support_followup", "chat_id": str(chat_id)}'));
    });
  });
}
