import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/haptic_service.dart';
import 'onboarding_widgets.dart';

/// Profile photo capture for the onboarding to-do flow (Lyft style).
///
/// In-app FRONT camera with an oval face guide ("Center your face in good
/// light"), capture → preview → "Use this photo" / "Retake". Confirming
/// uploads through the existing `ApiService.uploadPhoto` mechanism
/// (Firebase Storage + backend sync) and pops `true`.
class ProfilePhotoCaptureScreen extends StatefulWidget {
  const ProfilePhotoCaptureScreen({super.key});

  @override
  State<ProfilePhotoCaptureScreen> createState() =>
      _ProfilePhotoCaptureScreenState();
}

class _ProfilePhotoCaptureScreenState
    extends State<ProfilePhotoCaptureScreen> {
  CameraController? _ctrl;
  bool _initialized = false;
  bool _permissionDenied = false;
  String? _capturedPath;
  bool _capturing = false;
  bool _uploading = false;

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
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    // A selfie needs no OCR — high is plenty and initializes faster.
    _ctrl = CameraController(front, ResolutionPreset.high, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('⚠️ Profile photo camera init failed: $e');
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _capture() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await c.takePicture();
      if (mounted) setState(() => _capturedPath = xFile.path);
    } catch (e) {
      debugPrint('⚠️ Profile photo capture failed: $e');
    }
    if (mounted) setState(() => _capturing = false);
  }

  void _retake() => setState(() => _capturedPath = null);

  Future<void> _usePhoto() async {
    final path = _capturedPath;
    if (path == null || _uploading) return;
    final s = S.of(context);
    setState(() => _uploading = true);
    try {
      await ApiService.uploadPhoto(path);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      showOnboardingError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploading = false);
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
            : _capturedPath != null
            ? _buildPreview()
            : _buildCamera(),
      ),
    );
  }

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

  Widget _buildCamera() {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;
    final size = MediaQuery.of(context).size;

    return Stack(
      key: const ValueKey('camera'),
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

        // Oval face guide
        Center(
          child: Container(
            width: size.width * 0.68,
            height: size.width * 0.88,
            decoration: BoxDecoration(
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.all(
                Radius.elliptical(size.width * 0.34, size.width * 0.44),
              ),
              border: Border.all(
                color: kOnboardingGold.withValues(alpha: 0.85),
                width: 2.5,
              ),
            ),
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

        // Guide text
        Positioned(
          bottom: 150,
          left: 28,
          right: 28,
          child: Text(
            s.obPhotoGuide,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
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
      ],
    );
  }

  Widget _buildPreview() {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;

    return Container(
      key: const ValueKey('preview'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(_capturedPath!), fit: BoxFit.cover),
          Container(color: Colors.black.withValues(alpha: 0.25)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, pad.bottom + 24),
              child: Column(
                children: [
                  OnboardingGoldButton(
                    label: s.obUseThisPhoto,
                    loading: _uploading,
                    onTap: _usePhoto,
                  ),
                  OnboardingTextButton(label: s.retake, onTap: _retake),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
