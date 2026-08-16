import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider-verification feature:
///   1. The home hero always paints "Where to?" — no verificationBlocked
///      card branch; the tap gates through _ensureVerified.
///   2. The schedule booking screen gates confirmation through
///      _ensureVerified too (same pattern as the home hero).
///   3. The ID scan keeps the FULL OCR text and submitVerification ships it
///      as id_ocr_text so the backend can match the document name.
///   4. SocketService listens to account_status_changed (blocked/deleted/
///      deactivated/approved) — the 300 s poll stays as fallback.
///   5. The deactivated screen offers a support chat shortcut.
///   6. The new rejection string exists in ES and EN.
///
/// Source-grep style, like picker_camera_guard_test.dart: these paths need
/// live Mapbox/camera surfaces, so what a unit test CAN pin is that the
/// wiring is in place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('home hero has no verification card branch', () {
    final src =
        File('lib/screens/home_screen_widgets.dart').readAsStringSync();

    test('verificationBlocked is gone from the hero build', () {
      final hero = RegExp(r'Widget _buildHeroCTA\(\) \{');
      final start = hero.firstMatch(src)!.end;
      final block = src.substring(start, start + 4000);
      expect(block.contains('verificationBlocked'), isFalse,
          reason: 'the hero must always paint "Where to?" — the '
              '"Verification pending / Verify now" card branch was removed');
    });

    test('the hero tap still gates through _ensureVerified', () {
      final hero = RegExp(r'Widget _buildHeroCTA\(\) \{');
      final start = hero.firstMatch(src)!.end;
      final block = src.substring(start, start + 4000);
      expect(block.contains('_ensureVerified()'), isTrue,
          reason: 'without the tap gate an unverified rider reaches the '
              'booking flow straight from the hero');
    });
  });

  group('schedule booking is verification-gated', () {
    final src =
        File('lib/screens/schedule_booking_screen.dart').readAsStringSync();

    test('_book() calls _ensureVerified before confirming', () {
      expect(src.contains('Future<bool> _ensureVerified()'), isTrue,
          reason: 'the schedule flow needs the same gate as the home hero');
      final book = RegExp(r'Future<void> _book\(\) async \{');
      final start = book.firstMatch(src)!.end;
      final block = src.substring(start, start + 300);
      expect(block.contains('_ensureVerified()'), isTrue,
          reason: 'an unverified rider could confirm a scheduled booking');
      expect(src.contains('IdentityVerificationScreen'), isTrue,
          reason: 'the gate must open the verification flow');
    });
  });

  group('ID OCR text reaches the backend', () {
    final verify =
        File('lib/screens/identity_verification_screen.dart').readAsStringSync();
    final api = File('lib/services/api_service.dart').readAsStringSync();

    test('the scanner keeps the full OCR text of the capture', () {
      expect(verify.contains('_capturedOcrText = ocr.text;'), isTrue,
          reason: 'only the keyword check survives — the name match on the '
              'backend needs the full OCR text');
      expect(verify.contains('onOcrText'), isTrue,
          reason: 'the scanner must hand the OCR text up to the parent');
    });

    test('submitVerification ships id_ocr_text', () {
      final fn = RegExp(r'submitVerification\(');
      final start = fn.firstMatch(api)!.end;
      final block = api.substring(start, start + 900);
      expect(block.contains('idOcrText'), isTrue,
          reason: 'submitVerification must accept the optional OCR text');
      expect(block.contains("'id_ocr_text'"), isTrue,
          reason: 'the field name on the wire is id_ocr_text');
      expect(verify.contains('idOcrText: _idOcrText'), isTrue,
          reason: 'the verification screen must pass the captured OCR text');
    });

    test('name_mismatch / ocr_unreadable retries from the doc guidelines', () {
      expect(verify.contains("'name_mismatch'"), isTrue);
      expect(verify.contains("'ocr_unreadable'"), isTrue);
      expect(verify.contains('verificationFailedName'), isTrue,
          reason: 'the rejection step must show the new localized message');
    });
  });

  group('socket account_status_changed', () {
    final src = File('lib/services/socket_service.dart').readAsStringSync();

    test('listens and exposes a stream', () {
      expect(src.contains("'account_status_changed'"), isTrue,
          reason: 'the backend already emits it — without the listener the '
              'app only notices on the 300 s poll');
      expect(src.contains('accountStatusStream'), isTrue,
          reason: 'home/main react through the exposed stream, following '
              'the existing stream pattern of this file');
    });

    test('home reacts to the push', () {
      final home = File('lib/screens/home_screen.dart').readAsStringSync();
      expect(home.contains('accountStatusStream'), isTrue);
      expect(home.contains('AccountDeactivatedScreen'), isTrue);
    });
  });

  group('deactivated screen support chat', () {
    final src =
        File('lib/screens/account_deactivated_screen.dart').readAsStringSync();

    test('has a FloatingActionButton opening ChatScreen support', () {
      expect(src.contains('FloatingActionButton'), isTrue);
      expect(src.contains('ChatScreen'), isTrue,
          reason: 'a deactivated rider must still reach support');
      expect(src.contains('logOut'), isTrue,
          reason: 'Log out must stay on the screen');
    });
  });

  group('localized strings', () {
    final src =
        File('lib/l10n/app_localizations.dart').readAsStringSync();

    test('verificationFailedName exists in ES and EN', () {
      final getter = RegExp(r'String get verificationFailedName =>');
      final start = getter.firstMatch(src)!.end;
      final block = src.substring(start, start + 500);
      expect(block.contains('No hemos podido verificar tu identidad'), isTrue,
          reason: 'missing the ES copy');
      expect(block.contains('We could not verify your identity'), isTrue,
          reason: 'missing the EN copy');
    });

    test('tryAgain and contactSupport getters exist', () {
      expect(src.contains('String get tryAgain =>'), isTrue);
      expect(src.contains('String get contactSupport =>'), isTrue);
    });
  });
}
