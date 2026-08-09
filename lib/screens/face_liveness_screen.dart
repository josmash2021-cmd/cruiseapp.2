import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import '../l10n/app_localizations.dart';
import '../services/haptic_service.dart';
import '../utils/app_platform.dart';
import '../utils/face_oval_fit.dart';
import '../widgets/neu_style.dart';

// ─── Step enum ──────────────────────────────────────────────────────────────
enum _Step { center, turnRight, turnLeft, holdStill }

/// Why the face is not yet framed — drives the small hint line under the
/// subtitle. `framed` shows nothing: the blur and the ring already say it.
enum _FaceFeedback { noFace, tooFar, tooClose, offCenter, framed, detectorError }

/// How starting the camera failed, when it did. Shown as an in-screen error
/// instead of the silent pop that used to leave the driver on the signup
/// form wondering what happened.
enum _CameraFailure { permission, init }

// ─── Main Widget ────────────────────────────────────────────────────────────

/// Premium iOS Face ID–style biometric verification.
/// Returns `{'photo': path, 'video': path}` or `null` if cancelled.
class FaceLivenessScreen extends StatefulWidget {
  const FaceLivenessScreen({super.key});

  @override
  State<FaceLivenessScreen> createState() => _FaceLivenessScreenState();
}

class _FaceLivenessScreenState extends State<FaceLivenessScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── Camera / ML ──────────────────────────────────────────────────────────
  CameraController? _cam;
  FaceDetector? _detector;
  bool _camReady = false;
  bool _processing = false;
  bool _finishing = false;
  int _frameSkip = 0;

  /// Upright size of the first streamed frame — the REAL texture size.
  /// `previewSize` reports the negotiated session format (e.g. 1920×1080
  /// landscape) while the texture at ResolutionPreset.medium is 480×640,
  /// so the preview is sized from this once it lands (see _buildCameraFill).
  Size? _streamFrameSize;

  // ── Step state ───────────────────────────────────────────────────────────
  _Step _step = _Step.center;
  bool _faceDetected = false;

  /// The face is not just present, it is inside the oval and about the right
  /// size. This is what gates the steps and drives the blur.
  bool _faceInOval = false;

  /// So the detector's rejection is reported once, not sixty times a second.
  bool _detectorErrorLogged = false;

  /// Consecutive detector rejections. A long streak means the detector is
  /// rejecting every frame on this device, not failing to find a face —
  /// that is when the on-screen error appears. One success clears it.
  int _detectorFailures = 0;

  /// Coarse framing of the detected face, for the hint line. Starts at
  /// noFace because that is the truth until the first frame comes back.
  _FaceFeedback _feedback = _FaceFeedback.noFace;

  /// Set when the camera could not be started at all.
  _CameraFailure? _cameraFailure;

  /// The screen the preview is laid out in, captured during build so the
  /// camera callback can map face boxes without touching context.
  Size? _screen;

  double _ringProgress = 0.0; // 0..1 across all steps
  int _stepIndex = 0;         // 0..3

  // holdStill fill progress (0..1)
  double _holdProgress = 0.0;

  // Video recording state (starts at step 2)
  bool _isRecording = false;

  // Brightness detection for smart flash
  double _lastBrightness = 1.0; // 0..1, default bright

  // ── Animation controllers ────────────────────────────────────────────────
  late final AnimationController _pulseCtrl;    // oval breathing 1.2s
  late final AnimationController _stepCtrl;     // step-text fade 0.3s
  late final AnimationController _doneCtrl;     // completion burst 0.6s
  late final AnimationController _blurCtrl;     // surroundings soften 0.35s
  late final AnimationController _sweepCtrl;    // ring highlight travel 2.4s

  /// The ring's progress, eased toward [_ringProgress] instead of jumping.
  /// A step landing is a quarter of the ring at once; tweened, it reads as
  /// the ring filling rather than a bar stepping.
  late final AnimationController _fillCtrl;
  double _fillFrom = 0.0;

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
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _stepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
    _blurCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _sweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _fillCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
      value: 1,
    );
    _doneCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Every looping ticker, or they keep waking the device behind a
      // screen that is not even visible.
      _sweepCtrl.stop();
      _pulseCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      _sweepCtrl.repeat();
      _pulseCtrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseCtrl.dispose();
    _stepCtrl.dispose();
    _doneCtrl.dispose();
    _blurCtrl.dispose();
    _sweepCtrl.dispose();
    _fillCtrl.dispose();
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
      // Used to just pop, which from the driver's side read as "the button
      // did nothing". Say why, and offer the way to system settings.
      setState(() => _cameraFailure = _CameraFailure.permission);
      return;
    }

    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: false,
        // 0.1, not 0.2: at 0.2 a face smaller than a fifth of the frame is
        // never even REPORTED, so anyone holding the phone at a normal
        // arm's length sat on "Position your face" forever. Acceptance is
        // still the oval-fit gate's call (faceFitsOval), so framing
        // strictness is unchanged — this only lets the detector see
        // farther faces well enough to hint "move closer".
        minFaceSize: 0.1,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (_) {
      if (mounted) setState(() => _cameraFailure = _CameraFailure.init);
      return;
    }
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).noCameraAvailable)),
        );
      }
      return;
    }
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cam = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      // nv21 on Android, NOT yuv420. The ML Kit plugin's own Android
      // converter (InputImageConverter.java) accepts only NV21 and YV12 and
      // answers anything else with "ImageFormat is not supported" — which
      // this screen was catching and discarding, so on Android every single
      // frame failed and no face was ever detected. With nv21 requested,
      // CameraX hands back one plane holding the complete NV21 buffer, which
      // is exactly what the detector wants.
      imageFormatGroup: AppPlatform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cam!.initialize();
      if (!mounted) return;
      // Reset zoom to 1.0 — no digital zoom
      try { await _cam!.setZoomLevel(1.0); } catch (_) {}
      await _cam!.startImageStream(_onFrame);
      if (mounted) setState(() => _camReady = true);
    } catch (_) {
      if (mounted) setState(() => _cameraFailure = _CameraFailure.init);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Frame processing
  // ─────────────────────────────────────────────────────────────────────────
  void _onFrame(CameraImage img) {
    if (_streamFrameSize == null) {
      // One rebuild so the preview FittedBox switches from the previewSize
      // fallback to the real texture size (see _buildCameraFill).
      _streamFrameSize = Size(img.width.toDouble(), img.height.toDouble());
      if (mounted) setState(() {});
    }
    if (_processing || _finishing) return;
    if (++_frameSkip % 2 != 0) return; // process every other frame
    _processing = true;
    _processFrame(img).whenComplete(() => _processing = false);
  }

  Future<void> _processFrame(CameraImage img) async {
    // Sample brightness from Y channel (YUV420) or first plane (BGRA)
    _updateBrightness(img);

    final inputImage = _toInputImage(img);
    if (inputImage == null) return;

    List<Face> faces;
    try {
      faces = await _detector!.processImage(inputImage);
      // One success clears the streak; the error line, if it was showing,
      // is replaced by the normal framing hint below.
      _detectorFailures = 0;
    } catch (e) {
      // Logged, once, deliberately. A silent catch here is what hid the
      // Android format bug: every frame threw "ImageFormat is not supported"
      // and the screen just sat there looking like it was working.
      if (!_detectorErrorLogged) {
        _detectorErrorLogged = true;
        debugPrint('[FaceLiveness] detector rejected every frame: $e');
      }
      // And once the streak is long enough that this is plainly every frame
      // rather than a dropped one, the screen says so. The stream keeps
      // running — the very next frame could still succeed.
      if (++_detectorFailures >= 30) {
        _setFeedback(_FaceFeedback.detectorError);
      }
      return;
    }

    if (!mounted) return;

    if (faces.isEmpty) {
      _setFeedback(_FaceFeedback.noFace);
      _setFaceFramed(false);
      return;
    }

    final framing = _framingFor(faces.first, img);
    _setFeedback(framing);
    _setFaceFramed(framing == _FaceFeedback.framed);
    if (_faceInOval) _checkStep(faces.first);
  }

  /// How the detected face sits against the oval the person is being shown —
  /// not merely whether a face exists somewhere in the frame.
  ///
  /// The old check was "a face exists", which passed a face twice the size
  /// of the oval and half off the side of it. Acceptance itself is still
  /// [faceFitsOval]'s call, unchanged; the other branches only explain
  /// WHICH of its tolerances failed, reusing its exact thresholds (26% of
  /// the oval off-centre, face/oval width outside 0.42–1.15), so the hint
  /// always names what the gate is still waiting for.
  _FaceFeedback _framingFor(Face face, CameraImage img) {
    final screen = _screen;
    final preview = _cam?.value.previewSize;
    if (screen == null || preview == null) return _FaceFeedback.noFace;
    final upright = uprightFrameSize(
      Size(img.width.toDouble(), img.height.toDouble()),
      _rotationDegrees(),
    );
    // The box arrives in the STREAM frame; map it into the frame the person
    // is actually shown before mapping to the screen. iOS shows the stream
    // buffer itself (the connection rotates natively); Android shows the
    // previewSize surface — typically 640×480 vs 1280×720, so mapping the
    // box straight from the stream frame reads ~1.33× too big and
    // "too close" never clears.
    final displayed = displayedFrameSize(
      streamed: Size(img.width.toDouble(), img.height.toDouble()),
      rotationDegrees: _rotationDegrees(),
      preview: preview,
      isAndroid: AppPlatform.isAndroid,
    );
    final onScreen = mapImageRectToScreen(
      scaleBoxBetweenFrames(face.boundingBox, upright, displayed),
      displayed,
      screen,
    );
    if (onScreen == null || onScreen.isEmpty) return _FaceFeedback.noFace;
    final oval = _ovalRect(screen);
    _logFitGeometry(upright, displayed, onScreen.width / oval.width);
    if (faceFitsOval(onScreen, oval)) return _FaceFeedback.framed;
    final ratio = onScreen.width / oval.width;
    if (ratio < 0.42) return _FaceFeedback.tooFar;   // faceFitsOval's minimum
    if (ratio > 1.15) return _FaceFeedback.tooClose; // its maximum
    // The width is inside the gate, so the centring is what failed.
    return _FaceFeedback.offCenter;
  }

  DateTime _lastFitLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// One geometry line a second at most — the camera callback fires per
  /// frame, and without this cap the log is unusable.
  void _logFitGeometry(Size stream, Size displayed, double ratio) {
    final now = DateTime.now();
    if (now.difference(_lastFitLog) < const Duration(seconds: 1)) return;
    _lastFitLog = now;
    debugPrint('[FaceFit] stream=${stream.width}x${stream.height} '
        'preview=${displayed.width}x${displayed.height} '
        'rot=${_rotationDegrees()} ratio=${ratio.toStringAsFixed(2)} '
        'feedback=$_feedback');
  }

  static Rect _ovalRect(Size screen) => Rect.fromCenter(
        center: Offset(screen.width / 2, screen.height * 0.42),
        width: _ovalW,
        height: _ovalH,
      );

  /// Moves the ring to [target] over time rather than snapping to it.
  void _animateRingTo(double target) {
    if (target == _ringProgress) return;
    _fillFrom = _ringValue;
    _ringProgress = target;
    _fillCtrl
      ..value = 0
      ..forward();
  }

  /// Where the ring is drawn right now, between the last value and the one
  /// it is heading for.
  double get _ringValue =>
      _fillFrom +
      (_ringProgress - _fillFrom) *
          Curves.easeOutCubic.transform(_fillCtrl.value);

  void _setFeedback(_FaceFeedback v) {
    // Called from the camera callback, which can outlive the widget.
    if (!mounted || _feedback == v) return;
    setState(() => _feedback = v);
  }

  String _feedbackText(BuildContext context) {
    final s = S.of(context);
    switch (_feedback) {
      case _FaceFeedback.noFace:
        return s.faceFeedbackNoFace;
      case _FaceFeedback.tooFar:
        return s.faceFeedbackMoveCloser;
      case _FaceFeedback.tooClose:
        return s.faceFeedbackMoveAway;
      case _FaceFeedback.offCenter:
        return s.faceFeedbackCenter;
      case _FaceFeedback.detectorError:
        return s.faceDetectionError;
      case _FaceFeedback.framed:
        return '';
    }
  }

  void _setFaceFramed(bool v) {
    if (_faceInOval == v) return;
    setState(() {
      _faceInOval = v;
      _faceDetected = v;
    });
    // Everything outside the oval softens once they are framed, so the blur
    // is not decoration — it is the app saying "yes, that is what I am
    // looking at".
    if (v) {
      _blurCtrl.forward();
    } else {
      _blurCtrl.reverse();
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
            setState(() => _holdProgress = next);
            // The hold is continuous already, so it drives the ring directly
            // — tweening a value that changes every frame would lag behind
            // the person's own steadiness.
            _fillFrom = _ringProgress = (_stepIndex * 0.25) + next * 0.25;
            _fillCtrl.value = 1;
            if (next >= 1.0 && !_finishing) {
              _captureAndComplete();
            }
          }
        } else {
          // decay progress if they move
          final next = (_holdProgress - 0.03).clamp(0.0, 1.0);
          if (next != _holdProgress) {
            setState(() => _holdProgress = next);
            _fillFrom = _ringProgress = (_stepIndex * 0.25) + next * 0.25;
            _fillCtrl.value = 1;
          }
        }
        break;
    }
  }

  void _advanceStep() {
    if (_finishing) return;
    HapticService.mediumImpact();
    _stepCtrl.reverse().then((_) {
      if (!mounted) return;
      setState(() {
        _stepIndex++;
        _step = _Step.values[_stepIndex];
      });
      _animateRingTo(_stepIndex * 0.25);
      _stepCtrl.forward();
      // Start video recording at step 2 (turnRight, index 1)
      if (_stepIndex == 1 && !_isRecording) {
        _startRecording();
      }
    });
  }

  /// Start video recording alongside image stream (best-effort).
  Future<void> _startRecording() async {
    try {
      await _cam?.startVideoRecording();
      _isRecording = true;
    } catch (_) {
      // Some platforms don't support simultaneous stream + recording
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Capture & complete
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _captureAndComplete() async {
    _finishing = true;
    HapticService.heavyImpact();
    setState(() => _ringProgress = 1.0);
    _doneCtrl.forward();

    await Future.delayed(const Duration(milliseconds: 400));

    // Stop image stream before capture
    try { await _cam?.stopImageStream(); } catch (_) {}

    // Smart flash: only enable torch if scene is dark (< 80/255 ≈ 0.31)
    final isDark = _lastBrightness < 0.31;
    if (isDark) {
      try { await _cam?.setFlashMode(FlashMode.torch); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
    }

    String? photoPath;
    String? videoPath;

    // Take still photo
    try {
      final photo = await _cam?.takePicture();
      photoPath = photo?.path;
    } catch (_) {}

    // Turn off flash immediately after capture
    if (isDark) {
      try { await _cam?.setFlashMode(FlashMode.off); } catch (_) {}
    }

    // Stop video recording (started at step 2)
    if (_isRecording) {
      try {
        final video = await _cam?.stopVideoRecording();
        videoPath = video?.path;
        _isRecording = false;
      } catch (_) {}
    } else {
      // Fallback: record a short clip if recording wasn't started earlier
      try {
        await _cam?.startVideoRecording();
        await Future.delayed(const Duration(seconds: 2));
        final video = await _cam?.stopVideoRecording();
        videoPath = video?.path;
      } catch (_) {}
    }

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    Navigator.of(context).pop({'photo': photoPath, 'video': videoPath});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Brightness detection (smart flash)
  // ─────────────────────────────────────────────────────────────────────────
  void _updateBrightness(CameraImage img) {
    if (img.planes.isEmpty) return;
    final bytes = img.planes[0].bytes;
    if (bytes.isEmpty) return;

    // Sample center region of Y-plane (luminance) — every 50th pixel for speed
    final w = img.width;
    final h = img.height;
    final cx = w ~/ 2, cy = h ~/ 2;
    final halfW = math.min(50, w ~/ 4);
    final halfH = math.min(50, h ~/ 4);
    int sum = 0, count = 0;
    for (var y = cy - halfH; y < cy + halfH; y += 5) {
      for (var x = cx - halfW; x < cx + halfW; x += 5) {
        final idx = y * w + x;
        if (idx >= 0 && idx < bytes.length) {
          sum += bytes[idx]; // Y value = luminance 0..255
          count++;
        }
      }
    }
    if (count > 0) {
      _lastBrightness = sum / count / 255.0; // normalize to 0..1
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // InputImage helper
  // ─────────────────────────────────────────────────────────────────────────
  /// How far the frame has to be turned for the detector to see it upright.
  ///
  /// iOS is always 0: the capture connection rotates the buffers NATIVELY,
  /// so the stream (and the preview texture) already arrive upright. Telling
  /// ML Kit the sensor angle double-rotates the frame and it sees the face
  /// lying sideways — that was the "Center your face" that never cleared.
  ///
  /// Android does rotate, and the sensor angle alone is only right by
  /// accident while the phone is held portrait: it has to be combined with
  /// how the device is currently turned, and a front camera combines it the
  /// other way round from a rear one.
  static const _orientationDegrees = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  int _rotationDegrees() {
    final cam = _cam;
    if (cam == null) return 0;
    // iOS: the buffers already arrive upright — see the doc comment above.
    if (!AppPlatform.isAndroid) return 0;
    final sensor = cam.description.sensorOrientation;
    final device = _orientationDegrees[cam.value.deviceOrientation] ?? 0;
    return cam.description.lensDirection == CameraLensDirection.front
        ? (sensor + device) % 360
        : (sensor - device + 360) % 360;
  }

  InputImage? _toInputImage(CameraImage img) {
    if (_cam == null || img.planes.isEmpty) return null;

    final rotation = InputImageRotationValue.fromRawValue(_rotationDegrees());
    if (rotation == null) return null;

    // Stated outright rather than read back off the frame, because the
    // camera was opened asking for exactly these two and they are the only
    // two each platform's detector accepts.
    final format = AppPlatform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

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
    // Kept so the camera callback can map face boxes onto the screen without
    // reaching for context off the build thread.
    _screen = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: _black,
      body: _cameraFailure != null
          ? _buildError()
          : _camReady
              ? _buildLive()
              : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
    );
  }

  // ── Startup error (permission denied / camera failed to start) ────────────
  //
  // This used to be a silent pop: the screen vanished and the driver landed
  // back on the form with no idea why. Same dark ground and gold accent as
  // the live view, a one-line reason, and a way out — plus the shortcut to
  // system settings when settings are the fix.
  Widget _buildError() {
    final s = S.of(context);
    final denied = _cameraFailure == _CameraFailure.permission;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: neuBox(
                radius: 36,
                borderColor: _gold.withValues(alpha: 0.45),
                borderWidth: 1.5,
              ),
              child: const Icon(
                Icons.videocam_off_rounded,
                color: _gold,
                size: 30,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              denied ? s.faceCameraPermissionDenied : s.faceCameraError,
              style: const TextStyle(
                color: _white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            if (denied) ...[
              _buildErrorButton(
                label: s.openSettings,
                gold: true,
                onTap: () => openAppSettings(),
              ),
              const SizedBox(height: 12),
            ],
            _buildErrorButton(
              label: s.close,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorButton({
    required String label,
    required VoidCallback onTap,
    bool gold = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: neuBox(
          radius: 24,
          borderColor: _gold.withValues(alpha: gold ? 0.45 : 0.12),
          borderWidth: 1.2,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: gold ? _gold : _white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }

  Widget _buildLive() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Full-screen camera
        _buildCameraFill(),

        // 2. Everything outside the oval softens once the face is framed
        _buildSurroundBlur(),

        // 3. Oval cutout overlay
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

  // ── Camera fill (no Transform.scale zoom) ────────────────────────────────
  Widget _buildCameraFill() {
    final camCtrl = _cam!;
    final preview = camCtrl.value.previewSize;
    if (preview == null) return const SizedBox.expand();
    // Size the FittedBox child from the REAL texture frame, not previewSize:
    // on iOS previewSize reports the negotiated session format (1920×1080
    // landscape) while the texture at ResolutionPreset.medium is 480×640,
    // and that mismatch is the ~1.33× zoom/crop the preview drew with.
    // Until the first stream frame lands, fall back to the previewSize swap.
    final streamed = _streamFrameSize;
    final displayed = streamed == null
        ? Size(preview.height, preview.width)
        : displayedFrameSize(
            streamed: streamed,
            rotationDegrees: _rotationDegrees(),
            preview: preview,
            isAndroid: AppPlatform.isAndroid,
          );
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: displayed.width,
          height: displayed.height,
          child: CameraPreview(camCtrl),
        ),
      ),
    );
  }

  // ── Surroundings blur ─────────────────────────────────────────────────────
  //
  // Fades in the moment the face is inside the oval, and back out if they
  // drift. Nothing else on the screen says "I have you" as directly as the
  // room going soft around them.
  Widget _buildSurroundBlur() {
    return AnimatedBuilder(
      animation: Listenable.merge([_blurCtrl, _pulseCtrl]),
      builder: (_, __) {
        final t = Curves.easeOutCubic.transform(_blurCtrl.value);
        // Nothing to draw, and a BackdropFilter that blurs by zero still
        // costs a full-screen render pass.
        if (t < 0.01) return const SizedBox.shrink();
        final pulse = Curves.easeInOut.transform(_pulseCtrl.value);
        return ClipPath(
          clipper: _OvalCutoutClipper(
            ovalW: _ovalW + pulse * 4,
            ovalH: _ovalH + pulse * 5,
          ),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 11 * t, sigmaY: 11 * t),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
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

  // ── Ring (static, no rotation — wave fill) ────────────────────────────────
  Widget _buildRing() {
    return AnimatedBuilder(
      animation:
          Listenable.merge([_sweepCtrl, _pulseCtrl, _fillCtrl, _blurCtrl]),
      builder: (_, __) {
        return RepaintBoundary(
          child: CustomPaint(
            painter: _FaceIDRingPainter(
              progress: _ringValue,
              sweep: _sweepCtrl.value,
              breathe: _pulseCtrl.value,
              framed: Curves.easeOutCubic.transform(_blurCtrl.value),
              allDone: _finishing,
              ovalW: _ovalW,
              ovalH: _ovalH,
            ),
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
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: neuBox(radius: 20),
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
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: neuBox(radius: 22),
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
                width: 60,
                height: 60,
                alignment: Alignment.center,
                decoration: neuBox(
                  radius: 30,
                  borderColor: (_finishing
                          ? _green
                          : _faceInOval
                              ? _gold
                              : Colors.white)
                      .withValues(alpha: _faceInOval || _finishing ? 0.45 : 0.06),
                  borderWidth: 1.5,
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
              // Framing hint — visible only while the face is not framed.
              // Once framed, the blur and "Face detected" already say it,
              // and the panel looks exactly as it always has.
              if (!_finishing && _feedback != _FaceFeedback.framed) ...[
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    _feedbackText(context),
                    key: ValueKey(_feedback),
                    style: TextStyle(
                      color: _gold.withValues(alpha: 0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
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

// ─── Face ID static ring painter with wave fill ────────────────────────────
/// One continuous ribbon of light around the oval.
///
/// This used to be eighty separate radial dashes, each coloured by its own
/// rule, which is why it read as a row of tally marks rather than something
/// flowing. Now it is a single arc under a sweep gradient, with a soft glow
/// beneath it, a highlight that travels the filled length, and a head that
/// pulses at the leading edge. Progress is handed in already eased by the
/// screen, so a step landing pours into place instead of jumping a quarter.
/// The ring of ticks around the oval — kept as ticks, made to flow.
///
/// The marks themselves were never the problem; the way they moved was. This
/// draws the same radial dashes, but:
///
///   • the boundary dash lights up FRACTIONALLY, so progress is continuous
///     instead of snapping eighty times around the ring
///   • an eased wave travels the lit arc, stretching and brightening each
///     dash as it passes and letting it settle behind — the dashes breathe
///     in sequence rather than blinking as a block
///   • a soft glow sits under the lit run so the light looks like it is
///     coming off the marks, not painted beside them
///   • the head dash carries its own halo
class _FaceIDRingPainter extends CustomPainter {
  /// 0..1, already eased by the screen so a completed step pours in.
  final double progress;

  /// 0..1 looping, drives the travelling wave.
  final double sweep;

  /// 0..1 breathing.
  final double breathe;

  /// 0..1, how framed the face is. Warms the ring as they line up.
  final double framed;

  final bool allDone;
  final double ovalW;
  final double ovalH;

  static const _dashCount = 80;
  static const _green    = Color(0xFF34C759);
  static const _greenHi  = Color(0xFFA8F5C0);
  static const _track    = Color(0xFF2A2A2A);

  const _FaceIDRingPainter({
    required this.progress,
    required this.sweep,
    required this.breathe,
    required this.framed,
    required this.allDone,
    required this.ovalW,
    required this.ovalH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || size.height < 2) return;

    final center = Offset(size.width / 2, size.height * 0.42);
    final b = Curves.easeInOut.transform(breathe);

    final radiusX = ovalW / 2 + 10 + b * 3;
    final radiusY = ovalH / 2 + 10 + b * 4;
    if (radiusX < 1 || radiusY < 1) return;

    final p = progress.clamp(0.0, 1.0);
    // Fractional, not rounded. Rounding is what made the ring advance in
    // visible steps of one eightieth.
    final filledExact = allDone ? _dashCount.toDouble() : p * _dashCount;
    final step = 2 * math.pi / _dashCount;

    // The wave eases at both ends of its run, so it never looks dragged at a
    // constant speed, and it sweeps a little past the head before returning.
    final t = Curves.easeInOutSine.transform(sweep);
    final wavePos = t * (filledExact + 6) - 3;

    final glow = <Offset>[];

    for (var i = 0; i < _dashCount; i++) {
      final angle = -math.pi / 2 + i * step;

      // How lit this dash is: 1 inside the run, a fraction at the boundary.
      final lit = (filledExact - i).clamp(0.0, 1.0);

      // Smooth falloff around the wave — no hard band edge.
      final d = (i - wavePos).abs();
      final wave = lit == 0 ? 0.0 : math.exp(-(d * d) / 18.0);

      final Color color;
      final double strokeW;
      final double inner;
      final double outer;

      if (lit == 0) {
        color = _track;
        strokeW = 2.0;
        inner = 6;
        outer = 2;
      } else {
        // Length and weight ride the wave, so the ring ripples.
        color = Color.lerp(_green, _greenHi, wave * 0.85)!
            .withValues(alpha: (0.55 + 0.45 * lit) * (0.85 + framed * 0.15));
        strokeW = 2.6 + wave * 1.5 + framed * 0.3;
        inner = 6 + wave * 2.5;
        outer = 2 + wave * 2.5;
        if (wave > 0.45) {
          glow.add(Offset(
            center.dx + radiusX * math.cos(angle),
            center.dy + radiusY * math.sin(angle),
          ));
        }
      }

      canvas.drawLine(
        Offset(
          center.dx + (radiusX - inner) * math.cos(angle),
          center.dy + (radiusY - inner) * math.sin(angle),
        ),
        Offset(
          center.dx + (radiusX + outer) * math.cos(angle),
          center.dy + (radiusY + outer) * math.sin(angle),
        ),
        Paint()
          ..color = color
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );
    }

    // The wave's own halo, drawn over the marks it is passing.
    if (glow.isNotEmpty && !allDone) {
      canvas.drawPoints(
        ui.PointMode.points,
        glow,
        Paint()
          ..color = _greenHi.withValues(alpha: 0.30)
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }

    // The leading dash keeps its own pulsing halo, so the eye always knows
    // where the fill has reached even when the wave is elsewhere.
    if (!allDone && filledExact > 0.5) {
      final headAngle = -math.pi / 2 + (filledExact - 1) * step;
      final pulse = 0.5 + 0.5 * math.sin(sweep * math.pi * 2);
      canvas.drawCircle(
        Offset(
          center.dx + radiusX * math.cos(headAngle),
          center.dy + radiusY * math.sin(headAngle),
        ),
        3.2 + pulse * 1.6,
        Paint()
          ..color = _greenHi.withValues(alpha: 0.65)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + pulse * 3),
      );
    }

    // The faint halo that keeps the oval alive while nothing else moves.
    if (!allDone) {
      canvas.drawOval(
        Rect.fromCenter(center: center, width: ovalW + 22, height: ovalH + 22),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 + b * 2
          ..color = _green
              .withValues(alpha: (0.03 + b * 0.06) * (0.4 + framed * 0.6))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  @override
  bool shouldRepaint(_FaceIDRingPainter old) =>
      old.progress != progress ||
      old.sweep != sweep ||
      old.breathe != breathe ||
      old.framed != framed ||
      old.allDone != allDone;
}

/// Everything EXCEPT the oval. What is drawn through this clip lands outside
/// the face window, which is how the blur leaves the face sharp and softens
/// the room behind it.
class _OvalCutoutClipper extends CustomClipper<Path> {
  final double ovalW;
  final double ovalH;
  const _OvalCutoutClipper({required this.ovalW, required this.ovalH});

  @override
  Path getClip(Size size) => Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()
          ..addOval(Rect.fromCenter(
            center: Offset(size.width / 2, size.height * 0.42),
            width: ovalW,
            height: ovalH,
          )),
      );

  @override
  bool shouldReclip(_OvalCutoutClipper old) =>
      old.ovalW != ovalW || old.ovalH != ovalH;
}
