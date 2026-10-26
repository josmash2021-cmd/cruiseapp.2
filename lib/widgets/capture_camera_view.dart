import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/haptic_service.dart';
import '../utils/app_platform.dart';

/// The ONE in-app capture camera design (owner spec 2026-10-23: "así como es
/// esa cámara, así quiero que estén las demás"): the license-capture page
/// layout — rounded preview card (~57% of the screen), X INSIDE the frame,
/// title + hint below, gold shutter + flash toggle.
///
/// Self-contained: owns the permission prompt and the camera lifecycle and
/// reports through callbacks — a host can embed it in its own state machine
/// or push it as a full route. NEVER copy this layout into another screen.
///
/// Used by: the driver documents (insurance / registration / inspection),
/// the legacy signup camera, and the profile photo capture. The license
/// capture and the selfie check already wear this design.
class CaptureCameraView extends StatefulWidget {
  final String title;
  final String hint;

  /// Front lens for face photos (profile); the rear lens (default) for
  /// documents.
  final bool frontCamera;
  final ValueChanged<String> onPhoto;
  final VoidCallback onCancel;

  const CaptureCameraView({
    super.key,
    required this.title,
    required this.hint,
    this.frontCamera = false,
    required this.onPhoto,
    required this.onCancel,
  });

  @override
  State<CaptureCameraView> createState() => _CaptureCameraViewState();
}

class _CaptureCameraViewState extends State<CaptureCameraView> {
  static const _gold = Color(0xFFE8C547);

  /// The capture preset shared with every camera in the app: iOS ultraHigh
  /// NEVER max (the plugin's .max still path raises a native NSException on
  /// iOS 16+ and closes the app); Android keeps max.
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

  CameraController? _ctrl;
  bool _initialized = false;
  bool _capturing = false;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    // Null-swap: the route exit animation rebuilds AFTER dispose() — with
    // the field null the build never touches a disposed controller
    // (Crashlytics 2026-10-17: "Disposed CameraController").
    final c = _ctrl;
    _ctrl = null;
    c?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (status.isPermanentlyDenied) {
      if (mounted) _showPermanentlyDenied();
      return;
    }
    if (!status.isGranted) {
      if (mounted) widget.onCancel();
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) widget.onCancel();
      return;
    }
    final lens = widget.frontCamera
        ? cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
            orElse: () => cameras.first)
        : cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first);
    _ctrl = CameraController(lens, _capturePreset, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('⚠️ Capture camera init failed: $e');
      // Retry once after a short delay.
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        final old = _ctrl;
        _ctrl = null;
        await old?.dispose();
        _ctrl = CameraController(lens, _capturePreset, enableAudio: false);
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        if (mounted) setState(() => _initialized = true);
      } catch (_) {
        if (mounted) widget.onCancel();
      }
    }
  }

  void _showPermanentlyDenied() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of(ctx).cameraPermissionPermanentlyDenied),
        content: Text(S.of(ctx).cameraPermissionPermanentlyDeniedMsg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onCancel();
            },
            child: Text(S.of(ctx).cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: Text(S.of(ctx).openSettings),
          ),
        ],
      ),
    );
  }

  Future<void> _capture() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await c.takePicture();
      if (!mounted) return;
      widget.onPhoto(xFile.path);
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Flash toggle — front cameras usually lack a torch unit: a failed write
  /// just leaves the mode as-is.
  Future<void> _toggleFlash() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await c.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
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
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: pad.top + 12),
        // Rounded preview card (~57% of the screen) — the X rides INSIDE the
        // frame.
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
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                      onTap: widget.onCancel,
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
        // Copy below the preview.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
            child: Column(
              children: [
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.hint,
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
        // Gold shutter + flash toggle.
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
                      color: _gold,
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.45),
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
                        color: const Color(0xFF1C1C24),
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
                            : _gold,
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
    );
  }
}
