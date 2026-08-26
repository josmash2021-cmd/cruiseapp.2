import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/haptic_service.dart';
import '../utils/app_platform.dart';
import 'credit_card_screen.dart';

/// Card details read off the physical card by the scanner. Only the OCR
/// text is used — no card photo ever leaves the device or is uploaded.
class ScannedCard {
  final String number; // digits only
  final int? expMonth;
  final int? expYear; // 4-digit

  const ScannedCard({required this.number, this.expMonth, this.expYear});

  /// Brand guessed from the BIN prefix (good enough for the brand badge;
  /// Stripe still reads the authoritative brand from the card field).
  String get brand {
    if (number.startsWith('4')) return 'visa';
    if (number.startsWith('5')) return 'mastercard';
    if (number.startsWith('3')) return 'amex';
    if (number.startsWith('6')) return 'discover';
    return 'card';
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Card Scan — Lyft-style scan-first add card (spec 2026-08-24).
//
//  Opens BEFORE the manual form when the rider adds a card. Lyft layout
//  (2026-08-25): black top bar, the camera clipped inside a thin-bordered
//  card-ratio frame with the hint centred in it, and the "Scan your card"
//  copy + dark "Type details instead" button below on black. ML Kit text
//  recognition runs on a ~2/s throttle until a Luhn-valid number + expiry
//  date are read, then the manual form opens pre-filled (CVV/ZIP are
//  always typed — never scanned). "Type details instead" skips to the
//  empty form. Nothing but the OCR text is used; no card photo is
//  uploaded.
// ═══════════════════════════════════════════════════════════════════

class CardScanScreen extends StatefulWidget {
  /// Default flow (full-screen picker): on a successful read this screen
  /// is REPLACED by CreditCardScreen pre-filled, and the form's result
  /// pops back to the caller. With [returnResult] (in-sheet add card)
  /// the scanner pops instead with the [ScannedCard], the string
  /// `'manual'` when the rider chose "Type details instead", or null on
  /// close — the caller decides which form to open.
  final bool returnResult;

  const CardScanScreen({super.key, this.returnResult = false});

  @override
  State<CardScanScreen> createState() => _CardScanScreenState();
}

class _CardScanScreenState extends State<CardScanScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF14141A);

  /// Same preset policy as the KYC / license scanners: max on Android so
  /// the OCR frame is legible, ultraHigh on iOS because the plugin's
  /// `.max` still path raises a native NSException on iOS 16+.
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

  CameraController? _ctrl;
  bool _initialized = false;
  bool _permissionDenied = false;
  FlashMode _flashMode = FlashMode.off;

  final _textRecognizer = TextRecognizer();
  Timer? _scanTimer;
  bool _scanning = false;
  bool _handingOff = false; // a card was found; navigation in flight
  // Lyft-grade accuracy: the same card (number + expiry) must be read on
  // two consecutive passes before the hand-off — kills one-frame OCR
  // misreads.
  ScannedCard? _pendingCard;
  // Auto-torch: after ~4 s without a confirmed read the card is probably in
  // low light — the torch turns on by itself (the toggle stays in sync).
  int _missedTicks = 0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    final rear = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _ctrl = CameraController(rear, _capturePreset, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      await _ctrl!.setFlashMode(FlashMode.off);
      if (mounted) {
        setState(() => _initialized = true);
        _startScanning();
      }
    } catch (e) {
      debugPrint('[CardScan] camera init failed: $e');
      if (mounted) setState(() => _permissionDenied = true);
    }
  }

  /// ~2 OCR passes per second. takePicture (not the image stream) — same
  /// approach as LicenseScannerScreen: no per-platform rotation math, and
  /// the _scanning guard keeps passes from piling up on slow devices.
  void _startScanning() {
    // ML Kit has no web implementation — the preview still shows and the
    // rider uses "Type details instead".
    if (kIsWeb) return;
    _scanTimer = Timer.periodic(
      const Duration(milliseconds: 550),
      (_) => _scanFrame(),
    );
  }

  Future<void> _scanFrame() async {
    if (_ctrl == null ||
        !_ctrl!.value.isInitialized ||
        _scanning ||
        _handingOff ||
        !mounted) {
      return;
    }
    _scanning = true;
    try {
      final xFile = await _ctrl!.takePicture();
      final result = await _textRecognizer
          .processImage(InputImage.fromFilePath(xFile.path));
      try {
        File(xFile.path).deleteSync();
      } catch (_) {}
      final card = _parseCard(result.text);
      if (card != null && !_handingOff) {
        _missedTicks = 0;
        // Second consecutive identical read → confirmed, hand off.
        if (_pendingCard != null &&
            _pendingCard!.number == card.number &&
            _pendingCard!.expMonth == card.expMonth &&
            _pendingCard!.expYear == card.expYear) {
          _handingOff = true;
          _scanTimer?.cancel();
          HapticService.lightImpact();
          if (!mounted) {
            _scanning = false;
            return;
          }
          if (widget.returnResult) {
            Navigator.of(context).pop(card);
          } else {
            await _openForm(prefill: card);
          }
        } else {
          // First hit — hold it; the next frame must repeat it.
          _pendingCard = card;
        }
      } else {
        _pendingCard = null;
        _missedTicks++;
        if (_missedTicks >= 8 &&
            _flashMode == FlashMode.off &&
            _ctrl != null &&
            _ctrl!.value.isInitialized) {
          // ~4 s without a read — low light, torch on automatically.
          _flashMode = FlashMode.torch;
          try {
            await _ctrl!.setFlashMode(_flashMode);
            if (mounted) setState(() {});
          } catch (_) {}
        }
      }
    } catch (_) {
      // Transient OCR/capture hiccup — next tick retries.
    }
    _scanning = false;
  }

  /// Pulls a Luhn-valid 13–19 digit number and a MM/YY(YY) expiry out of
  /// the raw OCR text. Both are required before the hand-off — a number
  /// alone is usually right, the date is what keeps a false positive off
  /// the form.
  ScannedCard? _parseCard(String text) {
    // Number: long digit runs, spaces/dashes between groups allowed.
    String? number;
    for (final m in RegExp(r'\d[\d\s\-]{11,30}\d').allMatches(text)) {
      final digits = m.group(0)!.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 13 && digits.length <= 19 && _luhnOk(digits)) {
        number = digits;
        break;
      }
    }
    if (number == null) return null;

    // Expiry: MM/YY or MM-YYYY style, month 01–12.
    int? month;
    int? year;
    for (final m
        in RegExp(r'(\d{2})\s*[/\-.]\s*(\d{2})(\d{2})?').allMatches(text)) {
      final mm = int.tryParse(m.group(1)!);
      if (mm == null || mm < 1 || mm > 12) continue;
      var yy = int.parse(m.group(2)!);
      if (m.group(3) != null) yy = int.parse('${m.group(2)}${m.group(3)}');
      final fullYear = yy < 100 ? 2000 + yy : yy;
      final now = DateTime.now();
      // Accept this month forward; a card expiring this year/month counts.
      if (fullYear > now.year ||
          (fullYear == now.year && mm >= now.month)) {
        month = mm;
        year = fullYear;
        break;
      }
    }
    if (month == null || year == null) return null;
    return ScannedCard(number: number, expMonth: month, expYear: year);
  }

  static bool _luhnOk(String digits) {
    var sum = 0;
    var doubleIt = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var d = digits.codeUnitAt(i) - 48;
      if (doubleIt) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
      doubleIt = !doubleIt;
    }
    return sum % 10 == 0;
  }

  void _typeInstead() {
    HapticService.selectionClick();
    if (widget.returnResult) {
      Navigator.of(context).pop('manual');
    } else {
      _openForm();
    }
  }

  /// Replaces this screen with the manual form so the form's result
  /// ("brand:last4") pops straight back to whoever pushed the scanner.
  Future<void> _openForm({ScannedCard? prefill}) async {
    _scanTimer?.cancel();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CreditCardScreen(
          scannedNumber: prefill?.number,
          scannedExpMonth: prefill?.expMonth,
          scannedExpYear: prefill?.expYear,
        ),
      ),
    );
  }

  Future<void> _toggleFlash() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    await _ctrl!.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _textRecognizer.close();
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: _permissionDenied ? _buildDenied() : _buildScanner(),
    );
  }

  // ── Permission denied — same "Open Settings" pattern as onboarding ──

  Widget _buildDenied() {
    final s = S.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _circleButton(
                Icons.close_rounded,
                () => Navigator.of(context).pop(),
              ),
            ),
            const Spacer(),
            const Icon(Icons.photo_camera_outlined,
                color: _gold, size: 56),
            const SizedBox(height: 20),
            Text(
              s.cameraPermissionPermanentlyDenied,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              s.cameraPermissionRequiredForCard,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () {
                HapticService.selectionClick();
                openAppSettings();
              },
              child: Container(
                width: double.infinity,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s.openSettings,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFF1A1400),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _typeInstead,
              child: Text(
                s.typeDetailsInstead,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  // ── Scanner ──

  Widget _buildScanner() {
    final s = S.of(context);
    final frameW = MediaQuery.of(context).size.width - 32;
    // ISO 7810 card ratio.
    final frameH = frameW / 1.586;
    return SafeArea(
      child: Column(
        children: [
          // Top bar: bare X left, centered title, flash toggle right.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.close_rounded,
                        color: Colors.white, size: 26),
                  ),
                ),
                Expanded(
                  child: Text(
                    s.scanCardTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _circleButton(
                  _flashMode == FlashMode.torch
                      ? Icons.flash_on_rounded
                      : Icons.flash_off_rounded,
                  _toggleFlash,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // The camera IS the frame (Lyft layout 2026-08-25): preview
          // clipped to the card ratio with a thin light border, hint
          // centred inside — no full-screen veil, no gold glow.
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: frameW,
              height: frameH,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.55),
                  width: 1.5,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_initialized && _ctrl != null)
                    SizedBox.expand(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: _ctrl!.value.previewSize!.height,
                          height: _ctrl!.value.previewSize!.width,
                          child: CameraPreview(_ctrl!),
                        ),
                      ),
                    )
                  else
                    const Center(
                      child: CircularProgressIndicator(color: _gold),
                    ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        s.holdCardToScan,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 8)
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 28),
          Text(
            s.scanYourCardHeading,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            s.scanCardNumberVisible,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              s.scanCardSafestWay,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.50),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),

          const Spacer(),

          // Bottom: security note + manual entry escape (dark grey, white
          // text — no gold, Lyft-style).
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        color: Colors.white.withValues(alpha: 0.75),
                        size: 15),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        s.paymentInfoStoredSecurely,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _typeInstead,
                  child: Container(
                    width: double.infinity,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      s.typeDetailsInstead,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
