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
      duration: const Duration(milliseconds: 4500),
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
        final y = (face.headEulerAngleY ?? 0).abs();
        final x = (face.headEulerAngleX ?? 0).abs();
        return y < 10 && x < 10;
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
    final chunkProgress = (elapsed / _holdMs).clamp(0.0, 1.0);
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
    if (elapsed >= _holdMs) {
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
        return S.of(context).holdStill;
      case _Challenge.turn:
        return S.of(context).moveHeadSlowly;
      case _Challenge.smile:
        return S.of(context).smileForPhoto;
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _camReady && _cam != null ? _buildLive() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF34C759)),
          const SizedBox(height: 16),
          Text(
            S.of(context).initializingCamera,
            style: const TextStyle(color: Colors.black54, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildLive() {
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top;
    // Circle area takes top ~55% of screen
    const circleRadius = 130.0;
    final circleCenterY = topPad + 60 + circleRadius + 20;

    // Background colors: no face → black top / gold bottom
    //                     face detected → semi-transparent top / lighter bottom
    const goldBrand = Color(0xFFE8C547);

    return AnimatedBuilder(
      animation: _bgCtrl,
      builder: (context, _) {
        final t = _bgCtrl.value;
        final topColor = Color.lerp(
          Colors.black,
          Colors.black.withValues(alpha: 0.65),
          t,
        )!;
        final bottomColor = Color.lerp(
          goldBrand.withValues(alpha: 0.92),
          const Color(0xFFF2F2F7).withValues(alpha: 0.88),
          t,
        )!;

        return Column(
          children: [
            // ── Top section: camera circle with animated background ──
            Expanded(
              flex: 55,
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
                        builder: (_, _) => CustomPaint(
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
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bottom section: animated gold / light with instructions ──
            Expanded(
              flex: 45,
              child: Container(
                width: double.infinity,
                color: bottomColor,
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            _instructionText(context),
            key: ValueKey('instr_${_challengeIndex}_$_showPhase2Intro'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 40),
        // Restart button (like Apple's "Volver a empezar")
        GestureDetector(
          onTap: () {
            setState(() {
              _challengeIndex = 0;
              _holdProgress = 0;
              _totalProgress = 0;
              _holdStart = null;
              _showPhase2Intro = false;
            });
          },
          child: Text(
            S.of(context).startOver,
            style: const TextStyle(
              color: Color(0xFF007AFF),
              fontSize: 16,
              fontWeight: FontWeight.w400,
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
        final opacity = _successCtrl.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF34C759).withValues(alpha: 0.15),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Color(0xFF34C759),
                  size: 42,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).faceVerified,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.of(context).capturingPhoto,
                style: const TextStyle(color: Colors.black45, fontSize: 15),
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
  static const _tickGap = 2.2; // degrees gap between ticks
  static const _green = Color(0xFF34C759);
  static const _gray = Color(0xFF555555);

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
    final outerR = circleRadius + 8;
    final innerR = circleRadius - 2;

    final filledTicks = (totalProgress * _tickCount).floor();
    final degreesPerTick = 360.0 / _tickCount;

    // Animated glow: the "leading edge" tick pulsates brighter
    final leadingTick = filledTicks;
    // Scan position creates a subtle sweep effect on unfilled ticks
    final scanTick = (scanPosition * _tickCount).floor() % _tickCount;

    for (var i = 0; i < _tickCount; i++) {
      final angleDeg = -90.0 + i * degreesPerTick;
      final angleRad = angleDeg * math.pi / 180;

      final isFilled = i < filledTicks;
      final isLeading = i == leadingTick && !allDone;
      // Near the leading edge, add a subtle glow trail
      final isGlowTrail =
          !allDone &&
          i >= filledTicks - 3 &&
          i < filledTicks &&
          filledTicks > 0;
      // Subtle scan shimmer on unfilled ticks
      final isScanNear = !allDone && !isFilled && (i - scanTick).abs() < 4;

      Color color;
      double strokeW;

      if (allDone) {
        color = _green;
        strokeW = 3.0;
      } else if (isLeading) {
        // Pulsating leading tick
        final pulse = (math.sin(scanPosition * math.pi * 4) + 1) / 2;
        color = Color.lerp(_green, const Color(0xFF8EF5A5), pulse)!;
        strokeW = 3.5;
      } else if (isGlowTrail) {
        // Glow trail behind leading edge — fading green
        final dist = (filledTicks - i).toDouble();
        final fade = (1 - dist / 4).clamp(0.4, 1.0);
        color = _green.withValues(alpha: fade);
        strokeW = 3.0;
      } else if (isFilled) {
        color = _green;
        strokeW = 3.0;
      } else if (isScanNear) {
        // Subtle scan shimmer
        final dist = (i - scanTick).abs().toDouble();
        final shimmerAlpha = (1 - dist / 4) * 0.3;
        color = _green.withValues(alpha: shimmerAlpha.clamp(0.05, 0.3));
        strokeW = 2.0;
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

      final paint = Paint()
        ..color = color
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(p1, p2, paint);

      // Add glow effect for filled ticks
      if ((isFilled || isLeading) && !allDone) {
        final glowPaint = Paint()
          ..color = _green.withValues(alpha: 0.15)
          ..strokeWidth = strokeW + 3
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        canvas.drawLine(p1, p2, glowPaint);
      }
    }

    // If all done, draw a glowing green circle border on top
    if (allDone) {
      // Outer glow
      canvas.drawCircle(
        center,
        circleRadius + 3,
        Paint()
          ..color = _green.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      // Solid ring
      canvas.drawCircle(
        center,
        circleRadius + 3,
        Paint()
          ..color = _green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0,
      );
    }

    // Scanning shimmer line (subtle white line that sweeps across the circle)
    if (!allDone) {
      final scanAngle = scanPosition * 2 * math.pi - math.pi / 2;
      final shimmerLength = math.pi / 4; // 45 degree arc
      final shimmerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: scanAngle - shimmerLength / 2,
          endAngle: scanAngle + shimmerLength / 2,
          colors: const [
            Color(0x00FFFFFF),
            Color(0x33FFFFFF),
            Color(0x00FFFFFF),
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
