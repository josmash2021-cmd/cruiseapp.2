import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import '../l10n/app_localizations.dart';

// ─── Step enum ──────────────────────────────────────────────────────────────
enum _Step { center, turnRight, turnLeft, holdStill }

// ─── Main Widget ────────────────────────────────────────────────────────────

/// Premium iOS Face ID–style biometric verification.
/// Returns `{'photo': path, 'video': path}` or `null` if cancelled.
class FaceLivenessScreen extends StatefulWidget {
  const FaceLivenessScreen({super.key});

  @override
  State<FaceLivenessScreen> createState() => _FaceLivenessScreenState();
}

class _FaceLivenessScreenState extends State<FaceLivenessScreen>
    with TickerProviderStateMixin {
  // ── Camera / ML ──────────────────────────────────────────────────────────
  CameraController? _cam;
  FaceDetector? _detector;
  bool _camReady = false;
  bool _processing = false;
  bool _finishing = false;
  int _frameSkip = 0;

  // ── Step state ───────────────────────────────────────────────────────────
  _Step _step = _Step.center;
  bool _faceDetected = false;
  double _ringProgress = 0.0; // 0..1 across all steps
  int _stepIndex = 0;         // 0..3

  // holdStill fill progress (0..1)
  double _holdProgress = 0.0;

  // ── Animation controllers ────────────────────────────────────────────────
  late final AnimationController _rotateCtrl;   // ring rotation 4s
  late final AnimationController _pulseCtrl;    // oval breathing 1.2s
  late final AnimationController _stepCtrl;     // step-text fade 0.3s
  late final AnimationController _doneCtrl;     // completion burst 0.6s

  // ── Colors ───────────────────────────────────────────────────────────────
  static const _black   = Color(0xFF000000);
  static const _gold    = Color(0xFFD4AF37);
  static const _green   = Color(0xFF34C759);
  static const _gray    = Color(0xFF282828);
  static const _white   = Colors.white;

  // ── Oval geometry ────────────────────────────────────────────────────────
  static const double _ovalW = 270.0;
  static const double _ovalH = 330.0;

  // ── Step instructions (lazy, set after context ready) ────────────────────
  List<String> get _instructions => [
    S.of(context).centerYourFace,
    S.of(context).turnHeadRight,
    S.of(context).turnHeadLeft,
    S.of(context).holdStill,
  ];

  List<IconData> get _stepIcons => [
    Icons.face_retouching_natural,
    Icons.arrow_forward_rounded,
    Icons.arrow_back_rounded,
    Icons.lock_open_rounded,
  ];

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _stepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _doneCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _initCamera();
  }

  @override
  void dispose() {
    _rotateCtrl.dispose();
    _pulseCtrl.dispose();
    _stepCtrl.dispose();
    _doneCtrl.dispose();
    _cam?.dispose();
    _detector?.close();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Camera init
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    final camStatus = await Permission.camera.request();
    if (!mounted) return;
    if (!camStatus.isGranted) {
      Navigator.of(context).pop();
      return;
    }

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: false,
        minFaceSize: 0.2,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cam = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cam!.initialize();
      if (!mounted) return;
      await _cam!.startImageStream(_onFrame);
      setState(() => _camReady = true);
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Frame processing
  // ─────────────────────────────────────────────────────────────────────────
  void _onFrame(CameraImage img) {
    if (_processing || _finishing) return;
    if (++_frameSkip % 2 != 0) return; // process every other frame
    _processing = true;
    _processFrame(img).whenComplete(() => _processing = false);
  }

  Future<void> _processFrame(CameraImage img) async {
    final inputImage = _toInputImage(img);
    if (inputImage == null) return;

    List<Face> faces;
    try {
      faces = await _detector!.processImage(inputImage);
    } catch (_) {
      return;
    }

    if (!mounted) return;

    if (faces.isEmpty) {
      _setFaceDetected(false);
      return;
    }

    _setFaceDetected(true);
    _checkStep(faces.first);
  }

  void _setFaceDetected(bool v) {
    if (_faceDetected != v) {
      setState(() => _faceDetected = v);
    }
  }

  void _checkStep(Face face) {
    final yaw   = face.headEulerAngleY ?? 0.0;
    final pitch = face.headEulerAngleX ?? 0.0;

    switch (_step) {
      case _Step.center:
        if (yaw.abs() < 15 && pitch.abs() < 15) {
          _advanceStep();
        }
        break;

      case _Step.turnRight:
        // Positive yaw = facing right from user's POV (actual right turn)
        if (yaw > 22) {
          _advanceStep();
        }
        break;

      case _Step.turnLeft:
        // Negative yaw = facing left from user's POV
        if (yaw < -22) {
          _advanceStep();
        }
        break;

      case _Step.holdStill:
        if (yaw.abs() < 12 && pitch.abs() < 12) {
          // increment hold progress
          final next = (_holdProgress + 0.04).clamp(0.0, 1.0);
          if (next != _holdProgress) {
            setState(() {
              _holdProgress = next;
              _ringProgress = (_stepIndex * 0.25) + next * 0.25;
            });
            if (next >= 1.0 && !_finishing) {
              _captureAndComplete();
            }
          }
        } else {
          // decay progress if they move
          final next = (_holdProgress - 0.03).clamp(0.0, 1.0);
          if (next != _holdProgress) {
            setState(() {
              _holdProgress = next;
              _ringProgress = (_stepIndex * 0.25) + next * 0.25;
            });
          }
        }
        break;
    }
  }

  void _advanceStep() {
    if (_finishing) return;
    HapticFeedback.mediumImpact();
    _stepCtrl.reverse().then((_) {
      if (!mounted) return;
      setState(() {
        _stepIndex++;
        _ringProgress = _stepIndex * 0.25;
        _step = _Step.values[_stepIndex];
      });
      _stepCtrl.forward();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Capture & complete
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _captureAndComplete() async {
    _finishing = true;
    HapticFeedback.heavyImpact();
    setState(() => _ringProgress = 1.0);
    _doneCtrl.forward();

    await Future.delayed(const Duration(milliseconds: 400));

    // Stop image stream before taking picture
    try { await _cam?.stopImageStream(); } catch (_) {}

    String? photoPath;
    String? videoPath;

    // Take still photo
    try {
      final photo = await _cam?.takePicture();
      photoPath = photo?.path;
    } catch (_) {}

    // Record a short video clip
    try {
      await _cam?.startVideoRecording();
      await Future.delayed(const Duration(seconds: 2));
      final video = await _cam?.stopVideoRecording();
      videoPath = video?.path;
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    Navigator.of(context).pop({'photo': photoPath, 'video': videoPath});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // InputImage helper
  // ─────────────────────────────────────────────────────────────────────────
  InputImage? _toInputImage(CameraImage img) {
    final cam = _cam;
    if (cam == null) return null;
    final rotation = InputImageRotationValue.fromRawValue(
      cam.description.sensorOrientation,
    );
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(img.format.raw);
    if (format == null) return null;

    if (img.planes.isEmpty) return null;

    final plane = img.planes[0];
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(img.width.toDouble(), img.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _black,
      body: _camReady ? _buildLive() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
    );
  }

  Widget _buildLive() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Full-screen camera
        _buildCameraFill(),

        // 2. Oval cutout overlay
        _buildOvalOverlay(),

        // 3. Face ID ring around the oval
        _buildRing(),

        // 4. Step badge top-right
        _buildStepBadge(),

        // 5. Back button top-left
        _buildBackButton(),

        // 6. Bottom instruction panel
        _buildBottomPanel(),

        // 7. Done burst overlay
        if (_finishing) _buildDoneOverlay(),
      ],
    );
  }

  // ── Camera fill ───────────────────────────────────────────────────────────
  Widget _buildCameraFill() {
    final camCtrl = _cam!;
    final previewAspect = camCtrl.value.aspectRatio;
    return LayoutBuilder(builder: (_, constraints) {
      final screenAspect = constraints.maxWidth / constraints.maxHeight;
      double scale = previewAspect / screenAspect;
      if (scale < 1) scale = 1 / scale;
      return Transform.scale(
        scale: scale,
        child: Center(child: CameraPreview(camCtrl)),
      );
    });
  }

  // ── Oval cutout ───────────────────────────────────────────────────────────
  Widget _buildOvalOverlay() {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) {
        final pulse = Curves.easeInOut.transform(_pulseCtrl.value);
        return CustomPaint(
          painter: _OvalCutoutPainter(
            ovalW: _ovalW + pulse * 4,
            ovalH: _ovalH + pulse * 5,
          ),
        );
      },
    );
  }

  // ── Ring ──────────────────────────────────────────────────────────────────
  Widget _buildRing() {
    return AnimatedBuilder(
      animation: Listenable.merge([_rotateCtrl, _pulseCtrl]),
      builder: (_, __) {
        return CustomPaint(
          painter: _FaceIDRingPainter(
            progress: _ringProgress,
            rotation: _rotateCtrl.value,
            breathe: _pulseCtrl.value,
            allDone: _finishing,
            ovalW: _ovalW,
            ovalH: _ovalH,
          ),
        );
      },
    );
  }

  // ── Step badge ────────────────────────────────────────────────────────────
  Widget _buildStepBadge() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      right: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: _gray.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.4), width: 1),
        ),
        child: Text(
          '${_stepIndex + 1} / 4',
          style: const TextStyle(
            color: _gold,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // ── Back button ───────────────────────────────────────────────────────────
  Widget _buildBackButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _gray.withValues(alpha: 0.7),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close_rounded, color: _white, size: 20),
        ),
      ),
    );
  }

  // ── Bottom panel ─────────────────────────────────────────────────────────
  Widget _buildBottomPanel() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xCC000000), Color(0xFF000000)],
            stops: [0.0, 0.35, 1.0],
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          24, 60, 24, MediaQuery.of(context).padding.bottom + 40),
        child: FadeTransition(
          opacity: _stepCtrl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gray,
                  border: Border.all(
                    color: _finishing ? _green : _gold,
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  _finishing ? Icons.check_rounded : _stepIcons[_stepIndex],
                  color: _finishing ? _green : _gold,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              // Instruction text
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _finishing
                      ? S.of(context).faceVerified
                      : _instructions[_stepIndex],
                  key: ValueKey(_finishing ? 'done' : _stepIndex),
                  style: const TextStyle(
                    color: _white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _finishing
                      ? S.of(context).capturingPhoto
                      : (_faceDetected
                          ? S.of(context).faceDetected
                          : S.of(context).positionYourFace),
                  key: ValueKey(_finishing ? 'done_sub' : '${_stepIndex}_$_faceDetected'),
                  style: TextStyle(
                    color: _white.withValues(alpha: 0.5),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              // Progress dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final done = i < _stepIndex || _finishing;
                  final active = i == _stepIndex && !_finishing;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: done
                          ? _green
                          : active
                              ? _gold
                              : _gray,
                    ),
                  );
                }),
              ),

              // Hold-still progress bar
              if (_step == _Step.holdStill && !_finishing) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _holdProgress,
                    backgroundColor: _gray,
                    valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                    minHeight: 4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Done overlay ──────────────────────────────────────────────────────────
  Widget _buildDoneOverlay() {
    return AnimatedBuilder(
      animation: _doneCtrl,
      builder: (_, __) {
        final v = Curves.elasticOut.transform(_doneCtrl.value.clamp(0.0, 1.0));
        return Center(
          child: Transform.scale(
            scale: v,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _green.withValues(alpha: 0.15),
                border: Border.all(color: _green, width: 2),
              ),
              child: const Icon(
                Icons.check_rounded,
                color: _green,
                size: 52,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Oval cutout painter ────────────────────────────────────────────────────
class _OvalCutoutPainter extends CustomPainter {
  final double ovalW;
  final double ovalH;
  const _OvalCutoutPainter({required this.ovalW, required this.ovalH});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.42);
    final ovalRect = Rect.fromCenter(center: center, width: ovalW, height: ovalH);

    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect);

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xD9000000),
    );
  }

  @override
  bool shouldRepaint(_OvalCutoutPainter old) =>
      old.ovalW != ovalW || old.ovalH != ovalH;
}

// ─── Face ID animated ring painter ─────────────────────────────────────────
class _FaceIDRingPainter extends CustomPainter {
  final double progress;   // 0..1
  final double rotation;   // 0..1 animation value
  final double breathe;    // 0..1 animation value
  final bool allDone;
  final double ovalW;
  final double ovalH;

  static const _dashCount = 80;
  static const _green     = Color(0xFF34C759);
  static const _gold      = Color(0xFFD4AF37);
  static const _goldBr    = Color(0xFFE8C547);
  static const _gray      = Color(0xFF2A2A2A);

  const _FaceIDRingPainter({
    required this.progress,
    required this.rotation,
    required this.breathe,
    required this.allDone,
    required this.ovalW,
    required this.ovalH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.42);
    final b = Curves.easeInOut.transform(breathe);

    // Padding around the oval
    final radiusX = ovalW / 2 + 10 + b * 3;
    final radiusY = ovalH / 2 + 10 + b * 4;

    final rotationOffset = rotation * 2 * math.pi;
    final filledDashes = (progress * _dashCount).round();

    final degreesPerDash = 2 * math.pi / _dashCount;

    for (var i = 0; i < _dashCount; i++) {
      final angle = -math.pi / 2 + i * degreesPerDash + rotationOffset;
      final isFilled = i < filledDashes;

      // Point on the oval perimeter
      final px = center.dx + radiusX * math.cos(angle);
      final py = center.dy + radiusY * math.sin(angle);

      // Tangent direction for dash orientation
      final tpx = center.dx + (radiusX + 8) * math.cos(angle);
      final tpy = center.dy + (radiusY + 8) * math.sin(angle);

      Color color;
      double strokeW;

      if (allDone) {
        color = _green;
        strokeW = 3.0;
      } else if (isFilled) {
        // Leading edge glow
        final isLeading = i == filledDashes - 1;
        if (isLeading) {
          final pulse = (math.sin(rotation * math.pi * 8) + 1) / 2;
          color = Color.lerp(_green, const Color(0xFF8EF5A5), pulse)!;
          strokeW = 3.5;
        } else {
          final dist = filledDashes - i;
          final fade = (1 - dist / 8.0).clamp(0.3, 1.0);
          color = _green.withValues(alpha: fade);
          strokeW = 3.0;
        }
      } else {
        color = _gray;
        strokeW = 2.0;
      }

      // Draw radial dash from inner to outer point
      final innerX = center.dx + (radiusX - 6) * math.cos(angle);
      final innerY = center.dy + (radiusY - 6) * math.sin(angle);
      final outerX = center.dx + (radiusX + 2) * math.cos(angle);
      final outerY = center.dy + (radiusY + 2) * math.sin(angle);

      canvas.drawLine(
        Offset(innerX, innerY),
        Offset(outerX, outerY),
        Paint()
          ..color = color
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );

      // Glow on filled dashes
      if (isFilled && !allDone) {
        canvas.drawLine(
          Offset(innerX, innerY),
          Offset(outerX, outerY),
          Paint()
            ..color = _green.withValues(alpha: 0.15)
            ..strokeWidth = strokeW + 4
            ..strokeCap = StrokeCap.round
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
    }

    // All done: glowing green oval ring
    if (allDone) {
      final ovalRect = Rect.fromCenter(
        center: center,
        width: ovalW + 20,
        height: ovalH + 20,
      );
      canvas.drawOval(
        ovalRect,
        Paint()
          ..color = _green.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawOval(
        ovalRect,
        Paint()
          ..color = _green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    // Breathing glow ring
    if (!allDone) {
      final glowAlpha = 0.05 + b * 0.1;
      final ovalRect = Rect.fromCenter(
        center: center,
        width: ovalW + 22,
        height: ovalH + 22,
      );
      canvas.drawOval(
        ovalRect,
        Paint()
          ..color = _goldBr.withValues(alpha: glowAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 + b * 2
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  @override
  bool shouldRepaint(_FaceIDRingPainter old) =>
      old.progress != progress ||
      old.rotation != rotation ||
      old.breathe != breathe ||
      old.allDone != allDone;
}
