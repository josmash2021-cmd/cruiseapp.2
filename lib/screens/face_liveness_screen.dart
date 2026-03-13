import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import '../l10n/app_localizations.dart';

/// Apple Face ID–style biometric verification screen.
///
/// Two phases like the real Face ID setup:
///   Phase 1: Position your face in the circle (center + blink)
///   Phase 2: Move your head slowly to complete the circle (turn + smile)
///
/// Progress is shown as segmented tick marks around a circle,
/// filling in green as each challenge passes.
///
/// Returns a map with 'photo' and 'video' paths, or null if cancelled.
class FaceLivenessScreen extends StatefulWidget {
  const FaceLivenessScreen({super.key});

  @override
  State<FaceLivenessScreen> createState() => _FaceLivenessScreenState();
}

enum _Challenge { center, blink, turn, smile }

class _FaceLivenessScreenState extends State<FaceLivenessScreen>
    with TickerProviderStateMixin {
  // Camera & ML Kit
  CameraController? _cam;
  FaceDetector? _detector;
  bool _camReady = false;
  bool _detecting = false;
  bool _capturing = false;
  bool _allDone = false;
  bool _recording = false;

  // Challenge state
  int _challengeIndex = 0;
  double _holdProgress = 0.0;
  DateTime? _holdStart;
  static const _holdMs = 1200;
  int _frameCount = 0;
  bool _blinkDetected = false; // Tracks blink event (eyes were closed)

  // Total progress across all challenges (0..1)
  double _totalProgress = 0.0;

  // Phase tracking: phase 1 = center+blink, phase 2 = turn+smile
  int get _phase => _challengeIndex < 2 ? 1 : 2;
  bool _showPhase2Intro = false;

  // Face detection state for background transition
  bool _faceDetected = false;
  late AnimationController _bgCtrl;

  // Animations
  late AnimationController _successCtrl;
  late AnimationController _scanCtrl;

  final _challenges = [
    _Challenge.center,
    _Challenge.blink,
    _Challenge.turn,
    _Challenge.smile,
  ];

  @override
  void initState() {
    super.initState();
    _bgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat();
    _successCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (status.isPermanentlyDenied) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of(ctx).cameraPermissionPermanentlyDenied),
            content: Text(S.of(ctx).cameraPermissionPermanentlyDeniedMsg),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).pop(null);
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
      return;
    }
    if (!status.isGranted) {
      if (mounted) Navigator.of(context).pop(null);
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) Navigator.of(context).pop(null);
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: false,
          minFaceSize: 0.2,
          performanceMode: FaceDetectorMode.fast,
        ),
      );

      final ctrl = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await ctrl.initialize();
      if (!mounted) return;

      _cam = ctrl;
      setState(() => _camReady = true);
      await ctrl.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('[FaceLiveness] camera init error: $e');
      if (mounted) Navigator.of(context).pop(null);
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 6 != 0) return;
    if (_detecting || _allDone || _showPhase2Intro || !mounted) return;
    _detecting = true;
    _processFrame(image).whenComplete(() => _detecting = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    final inputImage = _toInputImage(image);
    if (inputImage == null) return;
    try {
      final faces = await _detector!.processImage(inputImage);
      if (!mounted || _allDone) return;
      if (faces.isEmpty) {
        _setFaceDetected(false);
        _resetHold();
        return;
      }
      _setFaceDetected(true);
      final face = faces.first;
      if (_checkChallenge(_challenges[_challengeIndex], face)) {
        _advanceHold();
      } else {
        _resetHold();
      }
    } catch (_) {}
  }

  bool _checkChallenge(_Challenge challenge, Face face) {
    switch (challenge) {
      case _Challenge.center:
        final y = (face.headEulerAngleY ?? 0).abs();
        final x = (face.headEulerAngleX ?? 0).abs();
        final z = (face.headEulerAngleZ ?? 0).abs();
        return y < 12 && x < 12 && z < 15;
      case _Challenge.blink:
        final leftEye = face.leftEyeOpenProbability ?? 1.0;
        final rightEye = face.rightEyeOpenProbability ?? 1.0;
        final eyesClosed = leftEye < 0.3 && rightEye < 0.3;
        final eyesOpen = leftEye > 0.6 && rightEye > 0.6;
        if (eyesClosed) _blinkDetected = true;
        // Complete when eyes reopen after being closed (full blink cycle)
        return _blinkDetected && eyesOpen;
      case _Challenge.turn:
        final y = (face.headEulerAngleY ?? 0).abs();
        return y > 20;
      case _Challenge.smile:
        final smile = face.smilingProbability ?? 0.0;
        return smile > 0.7;
    }
  }

  void _advanceHold() {
    _holdStart ??= DateTime.now();
    final elapsed = DateTime.now().difference(_holdStart!).inMilliseconds;
    // Blink is event-based — complete instantly once detected
    final holdDuration = _challenges[_challengeIndex] == _Challenge.blink
        ? 200
        : _holdMs;
    final chunkProgress = (elapsed / holdDuration).clamp(0.0, 1.0);
    if (mounted) {
      setState(() {
        _holdProgress = chunkProgress;
        // Total progress = completed challenges + current progress within this challenge
        _totalProgress =
            ((_challengeIndex + chunkProgress) / _challenges.length).clamp(
              0.0,
              1.0,
            );
      });
    }
    if (elapsed >= holdDuration) {
      _nextChallenge();
    }
  }

  void _resetHold() {
    if (_holdStart != null || _holdProgress > 0) {
      _holdStart = null;
      if (mounted) {
        setState(() {
          _holdProgress = 0;
          _totalProgress = (_challengeIndex / _challenges.length).clamp(
            0.0,
            1.0,
          );
        });
      }
    }
  }

  void _setFaceDetected(bool detected) {
    if (_faceDetected == detected) return;
    _faceDetected = detected;
    if (detected) {
      _bgCtrl.forward();
    } else {
      _bgCtrl.reverse();
    }
  }

  void _nextChallenge() {
    _holdStart = null;
    if (_challengeIndex < _challenges.length - 1) {
      final nextIdx = _challengeIndex + 1;
      // Show phase 2 transition between phase 1 and 2
      if (nextIdx == 2) {
        setState(() {
          _challengeIndex = nextIdx;
          _holdProgress = 0;
          _totalProgress = (nextIdx / _challenges.length).clamp(0.0, 1.0);
          _showPhase2Intro = true;
        });
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _showPhase2Intro = false);
        });
      } else {
        setState(() {
          _challengeIndex = nextIdx;
          _holdProgress = 0;
          _totalProgress = (nextIdx / _challenges.length).clamp(0.0, 1.0);
        });
      }
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    if (_capturing) return;
    setState(() {
      _capturing = true;
      _allDone = true;
      _holdProgress = 1.0;
      _totalProgress = 1.0;
    });

    try {
      await _cam?.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 200));
      final photo = await _cam?.takePicture();

      // Record verification video — captures user face after challenges complete
      String? videoPath;
      try {
        await _cam?.startVideoRecording();
        _recording = true;
      } catch (e) {
        debugPrint('[FaceLiveness] video start error: $e');
      }

      await _successCtrl.forward();
      // Record for ~3 seconds total to capture clear face verification
      await Future.delayed(const Duration(milliseconds: 2500));

      if (_recording) {
        try {
          final videoFile = await _cam?.stopVideoRecording();
          videoPath = videoFile?.path;
        } catch (e) {
          debugPrint('[FaceLiveness] video stop error: $e');
        }
        _recording = false;
      }

      if (mounted) {
        Navigator.of(context).pop({'photo': photo?.path, 'video': videoPath});
      }
    } catch (e) {
      debugPrint('[FaceLiveness] capture error: $e');
      if (mounted) Navigator.of(context).pop(null);
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final camera = _cam?.description;
    if (camera == null) return null;
    final rotation = InputImageRotationValue.fromRawValue(
      camera.sensorOrientation,
    );
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final Uint8List bytes;
    if (image.planes.length == 1) {
      bytes = image.planes[0].bytes;
    } else {
      final buf = BytesBuilder();
      for (final plane in image.planes) {
        buf.add(plane.bytes);
      }
      bytes = buf.toBytes();
    }
    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _bgCtrl.dispose();
    _scanCtrl.dispose();
    _successCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    _detector?.close();
    super.dispose();
  }

  // ─── Instruction text ──────────────────────────────────────────────────

  String _instructionText(BuildContext context) {
    if (_showPhase2Intro) {
      return S.of(context).moveHeadSlowly;
    }
    switch (_challenges[_challengeIndex]) {
      case _Challenge.center:
        return S.of(context).positionFaceInFrame;
      case _Challenge.blink:
        return S.of(context).blinkBothEyes;
      case _Challenge.turn:
        return S.of(context).moveHeadSlowly;
      case _Challenge.smile:
        return S.of(context).smileForPhoto;
    }
  }

  IconData _challengeIcon() {
    switch (_challenges[_challengeIndex]) {
      case _Challenge.center:
        return Icons.center_focus_strong_rounded;
      case _Challenge.blink:
        return Icons.visibility_rounded;
      case _Challenge.turn:
        return Icons.rotate_left_rounded;
      case _Challenge.smile:
        return Icons.sentiment_very_satisfied_rounded;
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: _camReady && _cam != null ? _buildLive() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A0A0A), Color(0xFF1A1A1A)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFE8C547).withValues(alpha: 0.1),
                border: Border.all(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.face_rounded,
                color: Color(0xFFE8C547),
                size: 40,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              S.of(context).initializingCamera,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: Color(0xFFE8C547),
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLive() {
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top;
    const circleRadius = 130.0;
    final circleCenterY = topPad + 60 + circleRadius + 20;

    return AnimatedBuilder(
      animation: _bgCtrl,
      builder: (context, _) {
        final t = _bgCtrl.value;
        final topColor = Color.lerp(
          const Color(0xFF0A0A0A),
          const Color(0xFF0A0A0A).withValues(alpha: 0.85),
          t,
        )!;

        return Column(
          children: [
            // ── Top section: camera circle ──
            Expanded(
              flex: 58,
              child: Container(
                color: topColor,
                child: Stack(
                  children: [
                    // Camera preview clipped to circle
                    Positioned.fill(
                      child: _buildCirclePreview(circleRadius, circleCenterY),
                    ),
                    // Tick marks overlay
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _scanCtrl,
                        builder: (_, __) => CustomPaint(
                          painter: _FaceIDTickPainter(
                            totalProgress: _totalProgress,
                            allDone: _allDone,
                            scanPosition: _scanCtrl.value,
                            circleRadius: circleRadius,
                            circleCenterY: circleCenterY,
                          ),
                        ),
                      ),
                    ),
                    // Close button
                    Positioned(
                      top: topPad + 8,
                      left: 16,
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(null),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            color: Colors.white70,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    // Phase indicator badge
                    if (!_allDone)
                      Positioned(
                        top: topPad + 14,
                        right: 16,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Container(
                            key: ValueKey('phase_$_phase'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFE8C547,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(
                                  0xFFE8C547,
                                ).withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              '${_challengeIndex + 1} / ${_challenges.length}',
                              style: const TextStyle(
                                color: Color(0xFFE8C547),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ── Bottom section: instructions ──
            Expanded(
              flex: 42,
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Color(0xFF141414),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _allDone
                    ? _buildDoneSection()
                    : _buildInstructionSection(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCirclePreview(double radius, double centerY) {
    final camAspect = _cam!.value.aspectRatio;
    final previewAspect = 1 / camAspect;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final screenAspect = w / h;
        final scale = screenAspect > previewAspect
            ? w / (h * previewAspect)
            : h / (w / previewAspect);
        return ClipPath(
          clipper: _CircleClipper(
            center: Offset(w / 2, centerY),
            radius: radius,
          ),
          child: Transform.scale(
            scale: scale,
            child: Center(
              child: AspectRatio(
                aspectRatio: previewAspect,
                child: CameraPreview(_cam!),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInstructionSection() {
    const gold = Color(0xFFE8C547);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Challenge icon with animated ring
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: Container(
            key: ValueKey('icon_${_challengeIndex}_$_showPhase2Intro'),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: gold.withValues(alpha: 0.1),
              border: Border.all(
                color: gold.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            child: Icon(
              _showPhase2Intro ? Icons.swap_horiz_rounded : _challengeIcon(),
              color: gold,
              size: 28,
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Instruction text
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            _instructionText(context),
            key: ValueKey('instr_${_challengeIndex}_$_showPhase2Intro'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              height: 1.3,
              letterSpacing: -0.3,
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Sub-instruction
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            _challenges[_challengeIndex] == _Challenge.blink
                ? (_blinkDetected ? '' : '👁')
                : '',
            key: ValueKey('sub_${_challengeIndex}_$_blinkDetected'),
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),

        // Challenge progress dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_challenges.length, (i) {
            final isActive = i == _challengeIndex;
            final isDone = i < _challengeIndex || _allDone;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: isActive ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: isDone
                    ? const Color(0xFF34C759)
                    : isActive
                    ? gold
                    : Colors.white.withValues(alpha: 0.15),
              ),
            );
          }),
        ),
        const SizedBox(height: 32),

        // Restart button
        GestureDetector(
          onTap: () {
            setState(() {
              _challengeIndex = 0;
              _holdProgress = 0;
              _totalProgress = 0;
              _holdStart = null;
              _showPhase2Intro = false;
              _blinkDetected = false;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              S.of(context).startOver,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDoneSection() {
    return AnimatedBuilder(
      animation: _successCtrl,
      builder: (context, _) {
        final t = _successCtrl.value.clamp(0.0, 1.0);
        final scale = 0.6 + 0.4 * Curves.elasticOut.transform(t);
        return Opacity(
          opacity: t,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF34C759).withValues(alpha: 0.2),
                        const Color(0xFF34C759).withValues(alpha: 0.05),
                      ],
                    ),
                    border: Border.all(
                      color: const Color(0xFF34C759).withValues(alpha: 0.4),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF34C759).withValues(alpha: 0.25),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Color(0xFF34C759),
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                S.of(context).faceVerified,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).capturingPhoto,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Circle clipper for camera preview ─────────────────────────────────────
class _CircleClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;
  _CircleClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(_CircleClipper old) =>
      old.center != center || old.radius != radius;
}

// ─── Apple Face ID tick-mark painter with animated glow ────────────────────
class _FaceIDTickPainter extends CustomPainter {
  final double totalProgress;
  final bool allDone;
  final double scanPosition;
  final double circleRadius;
  final double circleCenterY;

  static const _tickCount = 72;
  static const _green = Color(0xFF34C759);
  static const _gray = Color(0xFF2A2A2A);
  static const _gold = Color(0xFFE8C547);

  const _FaceIDTickPainter({
    required this.totalProgress,
    required this.allDone,
    required this.scanPosition,
    required this.circleRadius,
    required this.circleCenterY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, circleCenterY);
    final outerR = circleRadius + 10;
    final innerR = circleRadius - 1;

    final filledTicks = (totalProgress * _tickCount).floor();
    final degreesPerTick = 360.0 / _tickCount;

    final leadingTick = filledTicks;
    final scanTick = (scanPosition * _tickCount).floor() % _tickCount;

    for (var i = 0; i < _tickCount; i++) {
      final angleDeg = -90.0 + i * degreesPerTick;
      final angleRad = angleDeg * math.pi / 180;

      final isFilled = i < filledTicks;
      final isLeading = i == leadingTick && !allDone;
      final isGlowTrail =
          !allDone &&
          i >= filledTicks - 6 &&
          i < filledTicks &&
          filledTicks > 0;
      final isScanNear = !allDone && !isFilled && (i - scanTick).abs() < 8;

      Color color;
      double strokeW;

      if (allDone) {
        color = _green;
        strokeW = 3.0;
      } else if (isLeading) {
        // Pulso más suave y fluido
        final pulse = (math.sin(scanPosition * math.pi * 3) + 1) / 2;
        final smoothPulse = pulse * pulse * (3 - 2 * pulse); // Smoothstep
        color = Color.lerp(_green, const Color(0xFF8EF5A5), smoothPulse)!;
        strokeW = 3.5 + smoothPulse * 0.5;
      } else if (isGlowTrail) {
        final dist = (filledTicks - i).toDouble();
        final fade = (1 - dist / 7).clamp(0.3, 1.0);
        color = _green.withValues(alpha: fade);
        strokeW = 3.0;
      } else if (isFilled) {
        color = _green;
        strokeW = 3.0;
      } else if (isScanNear) {
        // Efecto de ola más suave y amplio
        final dist = (i - scanTick).abs().toDouble();
        final waveInfluence = 1 - (dist / 8);
        final wave = (math.sin(scanPosition * math.pi * 2 - dist * 0.3) + 1) / 2;
        final smoothWave = wave * wave * (3 - 2 * wave); // Smoothstep
        final shimmerAlpha = waveInfluence * smoothWave * 0.35;
        color = _gold.withValues(alpha: shimmerAlpha.clamp(0.02, 0.35));
        strokeW = 2.0 + shimmerAlpha * 1.5;
      } else {
        color = _gray;
        strokeW = 2.0;
      }

      final p1 = Offset(
        center.dx + outerR * math.cos(angleRad),
        center.dy + outerR * math.sin(angleRad),
      );
      final p2 = Offset(
        center.dx + innerR * math.cos(angleRad),
        center.dy + innerR * math.sin(angleRad),
      );

      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = color
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );

      // Glow effect for filled ticks
      if ((isFilled || isLeading) && !allDone) {
        canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = _green.withValues(alpha: 0.12)
            ..strokeWidth = strokeW + 4
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
    }

    // All done: glowing green circle
    if (allDone) {
      canvas.drawCircle(
        center,
        circleRadius + 4,
        Paint()
          ..color = _green.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawCircle(
        center,
        circleRadius + 4,
        Paint()
          ..color = _green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    // Scanning shimmer arc (golden sweep)
    if (!allDone) {
      final scanAngle = scanPosition * 2 * math.pi - math.pi / 2;
      final shimmerLength = math.pi / 3;
      final shimmerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: scanAngle - shimmerLength / 2,
          endAngle: scanAngle + shimmerLength / 2,
          colors: const [
            Color(0x00E8C547),
            Color(0x22E8C547),
            Color(0x00E8C547),
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(scanAngle - shimmerLength / 2),
        ).createShader(Rect.fromCircle(center: center, radius: circleRadius));
      canvas.drawCircle(center, circleRadius, shimmerPaint);
    }
  }

  @override
  bool shouldRepaint(_FaceIDTickPainter old) =>
      old.totalProgress != totalProgress ||
      old.allDone != allDone ||
      old.scanPosition != scanPosition;
}
