import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../widgets/capture_camera_view.dart';
import 'onboarding_widgets.dart';

/// Profile photo capture for the onboarding to-do flow (Lyft style).
///
/// The SHARED in-app camera design (`CaptureCameraView` — owner spec
/// 2026-10-23: every camera wears the license-capture layout), FRONT lens,
/// capture → preview → "Use this photo" / "Retake". Confirming uploads
/// through the existing `ApiService.uploadPhoto` mechanism (Firebase
/// Storage + backend sync) and pops `true`. The camera permission prompt
/// and lifecycle live inside the shared view.
class ProfilePhotoCaptureScreen extends StatefulWidget {
  const ProfilePhotoCaptureScreen({super.key});

  @override
  State<ProfilePhotoCaptureScreen> createState() =>
      _ProfilePhotoCaptureScreenState();
}

class _ProfilePhotoCaptureScreenState
    extends State<ProfilePhotoCaptureScreen> {
  String? _capturedPath;
  bool _uploading = false;

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
    final s = S.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF14141A),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _capturedPath != null ? _buildPreview() : _buildCamera(s),
      ),
    );
  }

  Widget _buildCamera(S s) {
    // The shared license-capture design (owner spec 2026-10-23), FRONT lens.
    return CaptureCameraView(
      key: const ValueKey('camera'),
      title: s.captureProfilePhotoTitle,
      hint: s.obPhotoGuide,
      frontCamera: true,
      onPhoto: (path) => setState(() => _capturedPath = path),
      onCancel: () => Navigator.of(context).pop(),
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
