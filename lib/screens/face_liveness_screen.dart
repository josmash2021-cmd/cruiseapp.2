import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../config/app_theme.dart';

/// Real-time biometric face liveness screen.
///
/// Uses the front camera + Google ML Kit face detection (on-device, free)
/// to verify a real human is present through 3 challenges:
///   1. CENTER  — Look straight at the camera
///   2. TURN    — Turn your head to the side
///   3. BLINK   — Blink both eyes
///
/// Returns the path to the captured selfie, or null if cancelled.
class FaceLivenessScreen extends StatefulWidget {
  const FaceLivenessScreen({super.key});

  @override
  State<FaceLivenessScreen> createState() => _FaceLivenessScreenState();
}

enum _Challenge { center, turn, blink }

class _FaceLivenessScreenState extends State<FaceLivenessScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  // Camera & ML Kit
  CameraController? _cam;
  FaceDetector? _detector;
  bool _camReady = false;
  bool _detecting = false;
  bool _capturing = false;
  bool _allDone = false;

  // Challenge state
  int _challengeIndex = 0;
  double _holdProgress = 0.0; // 0..1
  DateTime? _holdStart;
  static const _holdMs = 700; // ms to hold pose before advancing

  // Smoothed camera image throttle
  int _frameCount = 0;

  // Animations
  late AnimationController _successCtrl;
  late AnimationController _pulseCtrl;

  final _challenges = [_Challenge.center, _Challenge.turn, _Challenge.blink];

  static const _instructions = {
    _Challenge.center: _ChallengeInfo(
      icon: Icons.face_rounded,
      title: 'Look straight at the camera',
      hint: 'Center your face in the oval',
    ),
    _Challenge.turn: _ChallengeInfo(
      icon: Icons.switch_left_rounded,
      title: 'Slowly turn your head to the side',
      hint: 'Turn left or right, then back',
    ),
    _Challenge.blink: _ChallengeInfo(
      icon: Icons.visibility_off_rounded,
      title: 'Blink both eyes',
      hint: 'Close and reopen your eyes',
    ),
  };

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _successCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
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
          enableClassification: true, // eye open, smiling probabilities
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
    // Process every 6th frame (~5fps) to save CPU/battery
    _frameCount++;
    if (_frameCount % 6 != 0) return;
    if (_detecting || _allDone || !mounted) return;
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
        _resetHold();
        return;
      }

      final face = faces.first;
      final challenge = _challenges[_challengeIndex];
      if (_checkChallenge(challenge, face)) {
        _advanceHold();
      } else {
        _resetHold();
      }
    } catch (_) {
      // Ignore per-frame errors
    }
  }

  bool _checkChallenge(_Challenge challenge, Face face) {
    switch (challenge) {
      case _Challenge.center:
        // Face looking straight: both Euler angles small
        final y = (face.headEulerAngleY ?? 0).abs();
        final x = (face.headEulerAngleX ?? 0).abs();
        final z = (face.headEulerAngleZ ?? 0).abs();
        return y < 12 && x < 12 && z < 15;

      case _Challenge.turn:
        // Head turned significantly to either side
        final y = (face.headEulerAngleY ?? 0).abs();
        return y > 20;

      case _Challenge.blink:
        // Both eyes closed
        final left = face.leftEyeOpenProbability ?? 1.0;
        final right = face.rightEyeOpenProbability ?? 1.0;
        return left < 0.3 && right < 0.3;
    }
  }

  void _advanceHold() {
    _holdStart ??= DateTime.now();
    final elapsed = DateTime.now().difference(_holdStart!).inMilliseconds;
    final progress = (elapsed / _holdMs).clamp(0.0, 1.0);
    if (mounted) setState(() => _holdProgress = progress);

    if (elapsed >= _holdMs) {
      _nextChallenge();
    }
  }

  void _resetHold() {
    if (_holdStart != null || _holdProgress > 0) {
      _holdStart = null;
      if (mounted) setState(() => _holdProgress = 0);
    }
  }

  void _nextChallenge() {
    _holdStart = null;
    if (_challengeIndex < _challenges.length - 1) {
      setState(() {
        _challengeIndex++;
        _holdProgress = 0;
      });
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
    });
    await _successCtrl.forward();

    try {
      await _cam?.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 300));
      final photo = await _cam?.takePicture();
      if (mounted) Navigator.of(context).pop(photo?.path);
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

    // Combine all planes into a single byte buffer
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
    _pulseCtrl.dispose();
    _successCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    _detector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _camReady && _cam != null ? _buildLive() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: _gold),
          SizedBox(height: 16),
          Text(
            'Initializing camera...',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildLive() {
    final info = _allDone ? null : _instructions[_challenges[_challengeIndex]]!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Camera preview ──
        CameraPreview(_cam!),

        // ── Oval overlay with cutout ──
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, _) => CustomPaint(
            painter: _OvalPainter(
              progress: _holdProgress,
              allDone: _allDone,
              pulse: _pulseCtrl.value,
            ),
          ),
        ),

        // ── Top bar ──
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _iconButton(
                  Icons.close,
                  onTap: () => Navigator.of(context).pop(null),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Face Verification',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 40),
              ],
            ),
          ),
        ),

        // ── Step dots ──
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 56),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_challenges.length, (i) {
                  final done = _allDone || i < _challengeIndex;
                  final active = !_allDone && i == _challengeIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 28 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: done
                          ? _gold
                          : (active ? Colors.white : Colors.white30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),

        // ── Bottom instruction card ──
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 52),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.92),
                  Colors.transparent,
                ],
              ),
            ),
            child: _allDone ? _buildSuccess() : _buildInstruction(info!),
          ),
        ),
      ],
    );
  }

  Widget _buildInstruction(_ChallengeInfo info) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Icon badge
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _gold.withValues(alpha: 0.15),
            border: Border.all(color: _gold.withValues(alpha: 0.4), width: 1.5),
          ),
          child: Icon(info.icon, color: _gold, size: 26),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            info.title,
            key: ValueKey(info.title),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          info.hint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
        if (_holdProgress > 0.05) ...[
          const SizedBox(height: 16),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _holdProgress),
            duration: const Duration(milliseconds: 150),
            builder: (_, v, child) => ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: v,
                backgroundColor: Colors.white12,
                color: _gold,
                minHeight: 5,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _successCtrl,
          builder: (context, child) {
            final scale = Curves.elasticOut.transform(
              _successCtrl.value.clamp(0.0, 1.0),
            );
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green.withValues(alpha: 0.2),
                  border: Border.all(color: Colors.green, width: 2),
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.green,
                  size: 34,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Liveness Verified!',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Capturing your photo...',
          style: TextStyle(color: Colors.white60, fontSize: 14),
        ),
      ],
    );
  }

  Widget _iconButton(IconData icon, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

// ─── Oval overlay painter ───────────────────────────────────────────────────
class _OvalPainter extends CustomPainter {
  final double progress;
  final bool allDone;
  final double pulse;

  const _OvalPainter({
    required this.progress,
    required this.allDone,
    required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const ovalW = 230.0;
    const ovalH = 300.0;
    final center = Offset(size.width / 2, size.height * 0.42);
    final ovalRect = Rect.fromCenter(
      center: center,
      width: ovalW,
      height: ovalH,
    );

    // Dark overlay with oval cutout
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.58),
    );

    // Oval border
    final borderColor = allDone
        ? Colors.green
        : Color.lerp(
            Colors.white.withValues(alpha: 0.35 + pulse * 0.2),
            const Color(0xFFE8C547),
            progress,
          )!;
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Progress arc on top of border
    if (progress > 0.02 && !allDone) {
      canvas.drawArc(
        ovalRect.inflate(2),
        -3.14159 / 2,
        2 * 3.14159 * progress,
        false,
        Paint()
          ..color = const Color(0xFFE8C547)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_OvalPainter old) =>
      old.progress != progress || old.allDone != allDone || old.pulse != pulse;
}

// ─── Challenge metadata ──────────────────────────────────────────────────────
class _ChallengeInfo {
  final IconData icon;
  final String title;
  final String hint;

  const _ChallengeInfo({
    required this.icon,
    required this.title,
    required this.hint,
  });
}
