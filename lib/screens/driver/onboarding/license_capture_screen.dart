import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/haptic_service.dart';
import '../../../utils/app_platform.dart';
import '../../../widgets/doc_guidelines_view.dart';
import '../../../widgets/neu_style.dart';
import 'onboarding_widgets.dart';

/// Driver's license capture for the onboarding to-do flow (Lyft style).
///
/// In-app camera (never the native camera app): a guidelines page (real
/// photo of the driver's state license) comes before EACH side —
/// guide → front camera → guide → back camera — then the camera closes
/// and the screen shows both thumbnails with a gold Submit button. Submit
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

enum _LicensePhase { guideFront, camFront, guideBack, camBack, review }

class _LicenseCaptureScreenState extends State<LicenseCaptureScreen> {
  /// See class doc — pinned by test/camera_kyc_guard_test.dart semantics.
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

  CameraController? _ctrl;
  bool _initialized = false;
  bool _permissionDenied = false;
  _LicensePhase _phase = _LicensePhase.guideFront;
  String _stateCode = 'AL';
  String? _frontPath;
  String? _backPath;
  bool _capturing = false;
  bool _submitting = false;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    _loadStateCode();
  }

  /// The guidelines page shows a photo of the driver's own state license;
  /// `drive_state` comes from the profile picked at the drive-city step.
  Future<void> _loadStateCode() async {
    try {
      final me = await ApiService.getCurrentUser();
      final st = me?['drive_state']?.toString();
      if (st != null && st.isNotEmpty && mounted) {
        setState(() => _stateCode = st.toUpperCase());
      }
    } catch (_) {
      // Keep the AL default — a missing profile never blocks capture.
    }
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

  /// Guidelines "Next" — open the camera for the side being guided.
  /// The permission request fires HERE, not at screen open, so the guide
  /// page is never gated behind a system dialog.
  void _startCamera() {
    final front = _phase == _LicensePhase.guideFront;
    setState(
      () => _phase = front ? _LicensePhase.camFront : _LicensePhase.camBack,
    );
    // Front → back keeps the same controller alive; only boot the camera
    // when there isn't one (first entry, or after a review retake).
    if (!_initialized) _initCamera();
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
        if (_phase == _LicensePhase.camFront) {
          _frontPath = xFile.path;
          _phase = _LicensePhase.guideBack;
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
      if (side == _LicensePhase.camFront) {
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
      backgroundColor: neuBase,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _permissionDenied
            ? _buildDenied()
            : switch (_phase) {
                _LicensePhase.guideFront => _buildGuide(front: true),
                _LicensePhase.guideBack => _buildGuide(front: false),
                _LicensePhase.review => _buildReview(),
                _ => _buildCamera(),
              },
      ),
    );
  }

  // ── Guidelines page before EACH side (front, then back) ──
  Widget _buildGuide({required bool front}) {
    return Container(
      key: ValueKey(_phase),
      color: neuBase,
      child: SafeArea(
        child: DocGuidelinesView(
          docType: 'license',
          stateCode: _stateCode,
          side: front ? 'front' : 'back',
          onNext: _startCamera,
          // Front guide's X leaves the flow; the back guide steps back to
          // the front guide instead of dropping the whole capture.
          onClose: front
              ? null
              : () => setState(() => _phase = _LicensePhase.guideFront),
        ),
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

  // ── Live camera (front / back) — Lyft layout: rounded preview card on
  // top, copy + shutter on the app's standard grey below. ──
  Widget _buildCamera() {
    final s = S.of(context);
    final isFront = _phase == _LicensePhase.camFront;
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;

    final preview = _initialized && _ctrl != null
        ? FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _ctrl!.value.previewSize!.height,
              height: _ctrl!.value.previewSize!.width,
              child: CameraPreview(_ctrl!),
            ),
          )
        : const ColoredBox(
            color: Colors.black,
            child: Center(
              child: CircularProgressIndicator(
                color: kOnboardingGold,
                strokeWidth: 2.5,
              ),
            ),
          );

    return Container(
      key: ValueKey(_phase),
      color: neuBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: pad.top + 12),
          // ── Rounded preview card (~57% of the screen) ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: size.height * 0.57,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview,
                    // X top-left, over the preview
                    Positioned(
                      top: 12,
                      left: 12,
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
                  ],
                ),
              ),
            ),
          ),
          // ── Copy on the grey base ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
              child: Column(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      isFront ? s.obLicenseFrontText : s.obLicenseBackText,
                      key: ValueKey(isFront),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    s.obLicenseFrontHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 14.5,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ── Gold shutter + flash toggle ──
          Padding(
            padding: EdgeInsets.only(bottom: pad.bottom + 28, top: 8),
            child: SizedBox(
              height: 74,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  GestureDetector(
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
                  Positioned(
                    right: 36,
                    child: GestureDetector(
                      onTap: _toggleFlash,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: neuSurface,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
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
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Review + Submit ──
  Widget _buildReview() {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;

    return Container(
      key: const ValueKey('review'),
      color: neuBase,
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
                  _AspectThumb(
                    path: _frontPath!,
                    label: s.obLicenseFrontTitle,
                    onRetake: () => _retakeSide(_LicensePhase.camFront),
                  ),
                  const SizedBox(height: 16),
                  _AspectThumb(
                    path: _backPath!,
                    label: s.obLicenseBackTitle,
                    onRetake: () => _retakeSide(_LicensePhase.camBack),
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
}

/// Review thumbnail sized to the REAL aspect ratio of the captured file —
/// the frame follows the photo, so the image fills it completely with no
/// cropping and no side bands.
class _AspectThumb extends StatefulWidget {
  const _AspectThumb({
    required this.path,
    required this.label,
    required this.onRetake,
  });

  final String path;
  final String label;
  final VoidCallback onRetake;

  @override
  State<_AspectThumb> createState() => _AspectThumbState();
}

class _AspectThumbState extends State<_AspectThumb> {
  double? _aspect; // width / height of the captured photo
  ImageStreamListener? _listener;
  ImageStream? _stream;

  @override
  void initState() {
    super.initState();
    _resolveAspect();
  }

  void _resolveAspect() {
    final stream = FileImage(
      File(widget.path),
    ).resolve(const ImageConfiguration());
    _stream = stream;
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) return;
        setState(
          () => _aspect = info.image.width / info.image.height,
        );
      },
      onError: (_, __) {
        stream.removeListener(listener);
        // Leave _aspect null — the fixed-height fallback below shows.
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final aspect = _aspect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
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
              child: aspect == null
                  ? Container(
                      width: double.infinity,
                      height: 190,
                      color: neuSurface,
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: kOnboardingGold,
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  : AspectRatio(
                      aspectRatio: aspect,
                      child: Image.file(
                        File(widget.path),
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: GestureDetector(
                onTap: widget.onRetake,
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
