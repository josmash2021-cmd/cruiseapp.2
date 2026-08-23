import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/haptic_service.dart';
import '../../../utils/app_platform.dart';
import 'onboarding_widgets.dart';

/// Driver's license capture for the onboarding to-do flow (Lyft style).
///
/// In-app camera (never the native camera app): front side first, then a
/// smooth ~300 ms crossfade to the back side, then the camera closes and
/// the screen shows both thumbnails with a gold Submit button. Submit
/// uploads both photos through the SAME mechanism the legacy signup uses
/// (`ApiService.submitVerification` with base64 `license_front` /
/// `license_back`) and pops `true`.
///
/// Capture preset mirrors `license_scanner_screen.dart` / the camera guard
/// tests: Android `max` (720p stills at `high` are too soft for OCR),
/// iOS `ultraHigh` — NEVER `max` (the plugin's `.max` still path raises a
/// native NSException on iOS 16+ and closes the app).
class LicenseCaptureScreen extends StatefulWidget {
  const LicenseCaptureScreen({super.key});

  @override
  State<LicenseCaptureScreen> createState() => _LicenseCaptureScreenState();
}

enum _LicensePhase { front, back, review }

class _LicenseCaptureScreenState extends State<LicenseCaptureScreen> {
  /// See class doc — pinned by test/camera_kyc_guard_test.dart semantics.
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

  CameraController? _ctrl;
  bool _initialized = false;
  bool _permissionDenied = false;
  _LicensePhase _phase = _LicensePhase.front;
  String? _frontPath;
  String? _backPath;
  bool _capturing = false;
  bool _submitting = false;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final rear = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    // max on Android / ultraHigh on iOS — see class doc, never iOS max.
    _ctrl = CameraController(rear, _capturePreset, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      await _ctrl!.setFlashMode(FlashMode.off);
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('⚠️ Onboarding license camera init failed: $e');
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        _ctrl?.dispose();
        _ctrl = CameraController(rear, _capturePreset, enableAudio: false);
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        await _ctrl!.setFlashMode(FlashMode.off);
        if (mounted) setState(() => _initialized = true);
      } catch (_) {
        if (mounted) Navigator.of(context).pop();
      }
    }
  }

  Future<void> _toggleFlash() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    await c.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  Future<void> _capture() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await c.takePicture();
      if (!mounted) return;
      setState(() {
        if (_phase == _LicensePhase.front) {
          _frontPath = xFile.path;
          _phase = _LicensePhase.back;
        } else {
          _backPath = xFile.path;
          _phase = _LicensePhase.review;
        }
      });
      // The camera is done once both sides are captured — release it so
      // the review screen doesn't hold the sensor.
      if (_phase == _LicensePhase.review) {
        await c.dispose();
        _ctrl = null;
        _initialized = false;
      }
    } catch (e) {
      debugPrint('⚠️ License capture failed: $e');
    }
    if (mounted) setState(() => _capturing = false);
  }

  Future<void> _retakeSide(_LicensePhase side) async {
    setState(() {
      _phase = side;
      if (side == _LicensePhase.front) {
        _frontPath = null;
        _backPath = null;
      } else {
        _backPath = null;
      }
    });
    await _initCamera();
  }

  Future<void> _submit() async {
    final front = _frontPath;
    final back = _backPath;
    if (front == null || back == null || _submitting) return;
    final s = S.of(context);
    setState(() => _submitting = true);
    try {
      // Same upload mechanism as driver_signup_screen._uploadDocuments:
      // base64 photos inside submitVerification (POST /auth/verify-request).
      await ApiService.submitVerification({
        'id_document_type': 'driver_license',
        'license_front': base64Encode(await File(front).readAsBytes()),
        'license_back': base64Encode(await File(back).readAsBytes()),
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showOnboardingError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showOnboardingError(context, s.connectionError);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _permissionDenied
            ? _buildDenied()
            : _phase == _LicensePhase.review
            ? _buildReview()
            : _buildCamera(),
      ),
    );
  }

  // ── Permission denied — path to system Settings ──
  Widget _buildDenied() {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;
    return Container(
      key: const ValueKey('denied'),
      color: kOnboardingNavy,
      padding: EdgeInsets.fromLTRB(28, pad.top + 8, 28, pad.bottom + 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
          const Spacer(),
          const Icon(
            Icons.photo_camera_outlined,
            color: kOnboardingGold,
            size: 56,
          ),
          const SizedBox(height: 20),
          Text(
            s.obCameraDeniedTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            s.obCameraDeniedMsg,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const Spacer(),
          OnboardingGoldButton(label: s.openSettings, onTap: openAppSettings),
        ],
      ),
    );
  }

  // ── Live camera (front / back) ──
  Widget _buildCamera() {
    final s = S.of(context);
    final isFront = _phase == _LicensePhase.front;
    final pad = MediaQuery.of(context).padding;

    return Stack(
      key: ValueKey(_phase),
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
            child: CircularProgressIndicator(
              color: kOnboardingGold,
              strokeWidth: 2.5,
            ),
          ),

        // X top-left
        Positioned(
          top: pad.top + 12,
          left: 16,
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),

        // Title + instructions
        Positioned(
          top: pad.top + 24,
          left: 72,
          right: 72,
          child: Column(
            children: [
              Text(
                isFront ? s.obLicenseFrontTitle : s.obLicenseBackTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                isFront ? s.obLicenseFrontText : s.obLicenseBackText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13.5,
                  shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),

        // Hint above the shutter
        Positioned(
          bottom: 150,
          left: 28,
          right: 28,
          child: Text(
            s.obLicenseFrontHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 13,
              height: 1.4,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
            ),
          ),
        ),

        // Gold circular capture button
        Positioned(
          bottom: 48,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _initialized ? _capture : null,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kOnboardingGold,
                  boxShadow: [
                    BoxShadow(
                      color: kOnboardingGold.withValues(alpha: 0.45),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: _capturing
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: CircularProgressIndicator(
                          color: Colors.black,
                          strokeWidth: 2.5,
                        ),
                      )
                    : const Icon(
                        Icons.camera_alt_rounded,
                        color: Colors.black,
                        size: 32,
                      ),
              ),
            ),
          ),
        ),

        // Flash toggle — bottom-right
        Positioned(
          bottom: 60,
          right: 28,
          child: GestureDetector(
            onTap: _toggleFlash,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _flashMode == FlashMode.off
                    ? Icons.flash_off_rounded
                    : Icons.flash_on_rounded,
                color: _flashMode == FlashMode.off
                    ? Colors.white
                    : kOnboardingGold,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Review + Submit ──
  Widget _buildReview() {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;

    return Container(
      key: const ValueKey('review'),
      color: kOnboardingNavy,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Text(
                    s.obIntroLicenseTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _thumb(
                    path: _frontPath!,
                    label: s.obLicenseFrontTitle,
                    onRetake: () => _retakeSide(_LicensePhase.front),
                  ),
                  const SizedBox(height: 16),
                  _thumb(
                    path: _backPath!,
                    label: s.obLicenseBackTitle,
                    onRetake: () => _retakeSide(_LicensePhase.back),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, pad.bottom + 16),
            child: OnboardingGoldButton(
              label: s.obSubmitButton,
              loading: _submitting,
              onTap: _submit,
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb({
    required String path,
    required String label,
    required VoidCallback onRetake,
  }) {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                File(path),
                width: double.infinity,
                height: 190,
                fit: BoxFit.cover,
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: GestureDetector(
                onTap: onRetake,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Text(
                    s.retake,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
