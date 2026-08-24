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
//  Opens BEFORE the manual form when the rider adds a card. Camera
//  preview with a gold card-sized guide frame; ML Kit text recognition
//  runs on a ~2/s throttle until a Luhn-valid number + expiry date are
//  read, then the manual form opens pre-filled (CVV/ZIP are always
//  typed — never scanned). "Type details instead" skips to the empty
//  form. Nothing but the OCR text is used; no card photo is uploaded.
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
  static const _navy = Color(0xFF0A1128);

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
      if (card != null && mounted && !_handingOff) {
        _handingOff = true;
        _scanTimer?.cancel();
        HapticService.lightImpact();
        if (widget.returnResult) {
          Navigator.of(context).pop(card);
        } else {
          await _openForm(prefill: card);
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
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_initialized && _ctrl != null)
          Center(child: CameraPreview(_ctrl!))
        else
          const Center(
            child: CircularProgressIndicator(color: _gold),
          ),

        // Dark veil above/below the guide frame.
        Container(color: Colors.black.withValues(alpha: 0.35)),

        // Guide frame + hint, centered.
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: MediaQuery.of(context).size.width * 0.82,
                // ISO 7810 card ratio.
                height:
                    MediaQuery.of(context).size.width * 0.82 / 1.586,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _gold, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.25),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                s.holdCardToScan,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),

        // Top bar: X left, centered title, flash toggle right.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _circleButton(
                    Icons.close_rounded, () => Navigator.of(context).pop()),
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
        ),

        // Bottom: security note + manual entry escape.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
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
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        s.typeDetailsInstead,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          color: _gold,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
