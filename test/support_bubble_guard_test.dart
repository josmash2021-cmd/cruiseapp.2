import 'dart:io';

import 'package:cruise_app/services/support_bubble_controller.dart';
import 'package:cruise_app/widgets/animated_count_badge.dart';
import 'package:cruise_app/widgets/support_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rider's floating support bubble (owner 2026-11-07): when support
/// writes to a rider — or the rider writes to support — a bubble floats over
/// every screen and a tap opens the chat. Riders only, never a blur over
/// the map (#43), never the message text, never polled in the background.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// The `{…}` body that follows [signature] (brace-matched).
  String body(String src, String signature) {
    final at = src.indexOf(signature);
    expect(at, isNonNegative, reason: 'missing: $signature');
    final head = RegExp(r'\)\s*(async\s*)?\{').firstMatch(src.substring(at))!;
    final open = at + head.end - 1;
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
    }
    fail('unbalanced body after $signature');
  }

  final mainDart = read('lib/main.dart');
  final bubble = read('lib/widgets/support_bubble.dart');
  final ctrl = read('lib/services/support_bubble_controller.dart');

  // ── Source guards ──

  test('mounted once above every route, with the route observer', () {
    expect(mainDart, contains('child: SupportBubbleOverlay('));
    expect(mainDart, contains('controller: SupportBubbleController.instance,'));
    expect(mainDart, contains('_navigateToSupportChat(chatId: chatId)'));
    expect(mainDart, contains('              _supportBubbleRouteObserver,'));
    expect(mainDart,
        contains('route is PopupRoute || isAuthRouteName(route.settings.name)'));
  });

  test('no BackdropFilter / blur anywhere in the bubble (rule #43)', () {
    expect(bubble, isNot(contains('BackdropFilter')));
    expect(bubble, isNot(contains('ImageFilter')));
    expect(bubble, isNot(contains('GlassSurface')));
    expect(bubble, contains('color: neuBase,'));
  });

  test('the preview never carries the message text', () {
    expect(bubble, contains('s.supportBubblePreviewTitle'));
    expect(bubble, contains('s.supportBubblePreviewBody'));
    final api = read('lib/services/api_service.dart');
    final fn = body(api, 'getSupportActive() async');
    expect(fn, isNot(contains("['text']")));
  });

  test('foreground support push: bubble for riders, banner otherwise', () {
    final handler = mainDart.substring(
      mainDart.indexOf('FirebaseMessaging.onMessage.listen('),
      mainDart.indexOf('FirebaseMessaging.onMessageOpenedApp.listen('),
    );
    final branch = handler.substring(handler.indexOf(
        "if (type == 'support_message' || type == 'support_followup') {"));
    expect(branch.substring(0, branch.indexOf('return;')),
        contains('_showSupportPush(message'));
    final fn = body(mainDart, 'Future<void> _showSupportPush(');
    final ask = fn.indexOf('.handleForegroundPush(');
    final banner = fn.indexOf('_showPushBanner(');
    expect(ask, isNonNegative);
    expect(banner, greaterThan(ask), reason: 'banner only when not handled');
    expect(fn, contains('if (handledByBubble) return;'));
    final handle = body(ctrl, 'Future<bool> handleForegroundPush(');
    expect(handle, contains("if (mode != 'rider') return false;"));
    expect(handle, contains('if (!_overlayMounted) return false;'));
  });

  test('hidden while a support chat screen is open', () {
    final help = read('lib/screens/help_screen.dart');
    final chatState = help.substring(
        help.indexOf('class _CruiseSupportChatScreenState'));
    expect(body(chatState, 'void initState()'),
        contains('SupportBubbleController.instance.supportChatOpened();'));
    expect(body(chatState, 'void dispose()'),
        contains('SupportBubbleController.instance.supportChatClosed();'));
    final chat = read('lib/screens/chat_screen.dart');
    expect(body(chat, 'void initState()'),
        contains('if (widget.isSupport) SupportBubbleController.instance.supportChatOpened();'));
    expect(body(chat, 'void dispose()'),
        contains('if (widget.isSupport) SupportBubbleController.instance.supportChatClosed();'));
    expect(ctrl, contains('_supportChatsOpen == 0 &&'));
  });

  test('polls only in the foreground', () {
    final tick = body(ctrl, 'void _ensurePolling()');
    expect(tick, contains('!_inForeground'));
    expect(tick, contains('if (!_inForeground || !_inForegroundFn()) return;'));
    final life = body(ctrl, 'void appLifecycleChanged(AppLifecycleState state)');
    expect(life, contains('_stopPolling();'));
    expect(ctrl, contains('const kSupportBubblePollEvery = Duration(seconds: 45);'));
  });

  // ── Controller behaviour ──

  group('controller', () {
    late int fetches;
    late SupportActiveSnapshot? answer;
    late String mode;
    late bool front;

    SupportBubbleController make() => SupportBubbleController(
          fetch: () async {
            fetches++;
            return answer;
          },
          readMode: () async => mode,
          inForeground: () => front,
          loadDismissed: () async => null,
          saveDismissed: (_) async {},
        );

    setUp(() {
      fetches = 0;
      answer = (chatId: 7, unread: 1, lastId: 10, lastFromSupport: true);
      mode = 'rider';
      front = true;
    });

    test('driver mode: never asks, never shows, never polls, banner stays',
        () async {
      mode = 'driver';
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      expect(fetches, 0);
      expect(c.visible, isFalse);
      expect(c.isPolling, isFalse);
      expect(await c.handleForegroundPush(), isFalse);
      c.overlayUnmounted();
    });

    test('rider: visible with a live chat, handles the push', () async {
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      expect(c.visible, isTrue);
      expect(c.isPolling, isTrue);
      expect(await c.handleForegroundPush(), isTrue);
      c.overlayUnmounted();
      expect(c.isPolling, isFalse);
    });

    test('no chat = no bubble; the push falls back to the banner', () async {
      answer = (chatId: null, unread: 0, lastId: null, lastFromSupport: false);
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      expect(c.visible, isFalse);
      expect(await c.handleForegroundPush(), isFalse);
      c.overlayUnmounted();
    });

    test('support chat open: hidden, push handled, no preview after close',
        () async {
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      c.supportChatOpened();
      expect(c.visible, isFalse);
      answer = (chatId: 7, unread: 0, lastId: 12, lastFromSupport: true);
      expect(await c.handleForegroundPush(), isTrue);
      final seq = c.previewSeq;
      c.supportChatClosed();
      await c.refresh();
      expect(c.visible, isTrue);
      expect(c.previewSeq, seq, reason: 'read in the chat already');
      c.overlayUnmounted();
    });

    test('splash / dialog on top: hidden', () async {
      final c = make()..topRouteChanged(blocks: true);
      c.overlayMounted();
      await c.refresh();
      expect(c.visible, isFalse);
      c.topRouteChanged(blocks: false);
      expect(c.visible, isTrue);
      c.overlayUnmounted();
    });

    test('background stops the poll; resume asks again', () async {
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      expect(c.isPolling, isTrue);
      front = false;
      c.appLifecycleChanged(AppLifecycleState.paused);
      expect(c.isPolling, isFalse);
      front = true;
      final before = fetches;
      c.appLifecycleChanged(AppLifecycleState.resumed);
      await c.refresh();
      expect(fetches, greaterThan(before));
      expect(c.isPolling, isTrue);
      c.overlayUnmounted();
    });

    test('dismissed until a newer message; that one previews', () async {
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      c.dismiss();
      expect(c.visible, isFalse);
      await c.refresh();
      expect(c.visible, isFalse, reason: 'same last message');
      final seq = c.previewSeq;
      answer = (chatId: 7, unread: 2, lastId: 11, lastFromSupport: true);
      await c.refresh();
      expect(c.visible, isTrue);
      expect(c.previewSeq, seq + 1);
      expect(c.previewHaptic, isTrue);
      c.overlayUnmounted();
    });

    test("the rider's own message brings no preview", () async {
      final c = make()..topRouteChanged(blocks: false);
      c.overlayMounted();
      await c.refresh();
      final seq = c.previewSeq;
      answer = (chatId: 7, unread: 0, lastId: 11, lastFromSupport: false);
      await c.refresh();
      expect(c.previewSeq, seq);
      c.overlayUnmounted();
    });

    test('first look previews once only with unread > 0', () async {
      answer = (chatId: 7, unread: 0, lastId: 10, lastFromSupport: true);
      final quiet = make()..topRouteChanged(blocks: false);
      quiet.overlayMounted();
      await quiet.refresh();
      expect(quiet.previewSeq, 0);
      quiet.overlayUnmounted();

      answer = (chatId: 7, unread: 3, lastId: 10, lastFromSupport: true);
      final loud = make()..topRouteChanged(blocks: false);
      loud.overlayMounted();
      await loud.refresh();
      expect(loud.previewSeq, 1);
      expect(loud.previewHaptic, isFalse);
      await loud.refresh();
      expect(loud.previewSeq, 1, reason: 'once');
      loud.overlayUnmounted();
    });
  });

  // ── The widget ──

  group('widget', () {
    late SupportBubbleController c;
    late SupportActiveSnapshot? answer;
    late List<int> opened;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      c = SupportBubbleController(
        fetch: () async => answer,
        readMode: () async => 'rider',
        inForeground: () => true,
        loadDismissed: () async => null,
        saveDismissed: (_) async {},
      )..topRouteChanged(blocks: false);
      await tester.pumpWidget(MaterialApp(
        home: const Scaffold(backgroundColor: Colors.black),
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            child!,
            Positioned.fill(
              child: SupportBubbleOverlay(
                controller: c,
                observeLifecycle: false,
                onOpen: opened.add,
              ),
            ),
          ],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // The preview's first frame after its delayed start.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    setUp(() {
      opened = [];
      answer = (chatId: 7, unread: 2, lastId: 10, lastFromSupport: true);
    });

    testWidgets('shows with the unread badge; a tap opens the chat',
        (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('support-bubble')), findsOneWidget);
      expect(find.byIcon(Icons.support_agent_rounded), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // First look with unread > 0: the generic preview, no message text.
      expect(find.text('Support wrote to you'), findsOneWidget);
      expect(find.text('Tap to open the chat'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Support wrote to you'), findsNothing,
          reason: 'the preview leaves after 4.5 s');
      // Right edge, 12 px in, centre near 45 % of the height.
      final r = tester.getRect(find.byKey(const ValueKey('support-bubble')));
      expect(r.right, closeTo(390 - kSupportBubbleEdgeMargin, 0.5));
      expect(r.center.dy, closeTo(844 * 0.45, 1));
      await tester.tap(find.byKey(const ValueKey('support-bubble')));
      expect(opened, [7]);
    });

    testWidgets('badge hidden at 0', (tester) async {
      answer = (chatId: 7, unread: 0, lastId: 10, lastFromSupport: false);
      await pump(tester);
      expect(find.byKey(const ValueKey('support-bubble')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AnimatedCountBadge), matching: find.byType(Text)),
          findsNothing);
      expect(find.text('Support wrote to you'), findsNothing);
    });

    testWidgets('released mid-screen it springs to the nearest edge',
        (tester) async {
      await pump(tester);
      final start =
          tester.getCenter(find.byKey(const ValueKey('support-bubble')));
      final g = await tester.startGesture(start);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset(start.dx - 28.0 * i, start.dy - 10.0 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      final r = tester.getRect(find.byKey(const ValueKey('support-bubble')));
      expect(r.left, closeTo(kSupportBubbleEdgeMargin, 0.5));
    });

    testWidgets('dropped on the close target it hides until a newer message',
        (tester) async {
      await pump(tester);
      final start =
          tester.getCenter(find.byKey(const ValueKey('support-bubble')));
      final g = await tester.startGesture(start);
      const target = Offset(
          195, 844 - kSupportBubbleDismissBottom - kSupportBubbleDismissSize / 2);
      for (var i = 1; i <= 12; i++) {
        await g.moveTo(Offset.lerp(start, target, i / 12)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('support-bubble-dismiss')),
          findsOneWidget);
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('support-bubble')), findsNothing);
      expect(find.byKey(const ValueKey('support-bubble-dismiss')),
          findsNothing);
      expect(c.visible, isFalse);

      // Same message: stays hidden.
      await c.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('support-bubble')), findsNothing);

      // Support writes again: back, with the preview, at its old spot.
      answer = (chatId: 7, unread: 3, lastId: 11, lastFromSupport: true);
      await c.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('support-bubble')), findsOneWidget);
      expect(find.text('Support wrote to you'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final r = tester.getRect(find.byKey(const ValueKey('support-bubble')));
      expect(r.right, closeTo(390 - kSupportBubbleEdgeMargin, 0.5));
    });
  });
}
