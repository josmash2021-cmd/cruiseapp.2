import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/app_platform.dart';

/// Full-screen camera scanner with document-frame overlay and OCR.
/// Detects text on the license to confirm a real document is present,
/// then auto-captures or allows manual capture.
/// Returns the captured image path, or null if the user cancels.
class LicenseScannerScreen extends StatefulWidget {
  final String side; // "Front" or "Back"
  const LicenseScannerScreen({super.key, required this.side});

  @override
  State<LicenseScannerScreen> createState() => _LicenseScannerScreenState();
}

class _LicenseScannerScreenState extends State<LicenseScannerScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  /// Capture preset for the scanner.
  ///
  /// max, not high: takePicture() captures at the session preset, and at
  /// high (720p) the crop of the licence frame lands ~485×306 px — too
  /// soft for OCR to read.
  ///
  /// iOS runs ultraHigh (4K), NOT max. The plugin's `.max` branch overrides
  /// the active format with the sensor's highest-resolution one AND sets
  /// `isHighResolutionPhotoEnabled` on the still capture — on iOS 16+ that
  /// capture raises a native NSException (hi-res stills need
  /// `maxPhotoDimensions`, which the plugin never sets), so the app CLOSES
  /// the moment a still is taken. 4K stills leave the frame crop at
  /// ~1940×1224 — comfortably OCR-legible — through the plain session-preset
  /// path with no format override. Android keeps max: CameraX's fallback
  /// chain has no such branch.
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

  CameraController? _ctrl;
  bool _initialized = false;
  String? _capturedPath;
  bool _capturing = false;

  // OCR
  final _textRecognizer = TextRecognizer();
  bool _scanning = false;
  bool _documentDetected = false;
  String _detectedHint = '';
  FlashMode _flashMode = FlashMode.off;

  // Document detection rides the SILENT preview stream (2026-08-30) —
  // takePicture() per tick played the shutter sound every 1.5 s and the
  // page sounded like it was shooting photos on its own. The throttle +
  // the _scanning guard keep OCR passes from piling up on slow devices.
  DateTime? _lastScanTick;

  late AnimationController _cornerAnim;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    _cornerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).cameraPermissionRequired)),
        );
        Navigator.of(context).pop(null);
      }
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) Navigator.of(context).pop(null);
      return;
    }
    final rear = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    // See _capturePreset: max or the OCR crop comes back illegible —
    // and on iOS the .max still path closes the app natively.
    // nv21/bgra8888 stream format: the only ones each platform's ML Kit
    // converter accepts (same rule as face_liveness_screen.dart).
    _ctrl = CameraController(
      rear,
      _capturePreset,
      enableAudio: false,
      imageFormatGroup: AppPlatform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      await _ctrl!.setFlashMode(FlashMode.off);
      if (mounted) {
        setState(() => _initialized = true);
        unawaited(_startStream());
      }
    } catch (e) {
      debugPrint('⚠️ Camera init failed: $e');
      // Retry once after a short delay
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        _ctrl?.dispose();
        _ctrl = CameraController(
          rear,
          // Same preset as the first attempt — see _capturePreset.
          _capturePreset,
          enableAudio: false,
          imageFormatGroup: AppPlatform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
        );
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        await _ctrl!.setFlashMode(FlashMode.off);
        if (mounted) {
          setState(() => _initialized = true);
          unawaited(_startStream());
        }
      } catch (_) {
        if (mounted) Navigator.of(context).pop(null);
      }
    }
  }

  /// Starts the silent frame feed that powers document detection.
  Future<void> _startStream() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized || c.value.isStreamingImages) {
      return;
    }
    try {
      await c.startImageStream(_onStreamFrame);
    } catch (_) {}
  }

  Future<void> _toggleFlash() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    await _ctrl!.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  void _onStreamFrame(CameraImage img) {
    if (_capturing || _scanning || _capturedPath != null || !mounted) return;
    final now = DateTime.now();
    if (_lastScanTick != null &&
        now.difference(_lastScanTick!) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastScanTick = now;
    _scanning = true;
    _scanForDocument(img).whenComplete(() => _scanning = false);
  }

  // iOS rotates the stream buffers natively at the connection
  // (face_liveness 2026-08-08) — applying the sensor angle there
  // double-rotates and ML Kit reads the document sideways.
  static const _orientationDegrees = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  int _rotationDegrees() {
    final cam = _ctrl;
    if (cam == null) return 0;
    if (!AppPlatform.isAndroid) return 0;
    final sensor = cam.description.sensorOrientation;
    final device = _orientationDegrees[cam.value.deviceOrientation] ?? 0;
    return (sensor - device + 360) % 360; // rear camera
  }

  InputImage? _frameToInputImage(CameraImage img) {
    if (img.planes.isEmpty) return null;
    final rotation = InputImageRotationValue.fromRawValue(_rotationDegrees());
    if (rotation == null) return null;
    // Stated, not read off the frame: the controller was opened asking for
    // exactly these and they are the only two each converter accepts.
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

  /// Scan a stream frame for document text via OCR — only updates border color.
  Future<void> _scanForDocument(CameraImage img) async {
    try {
      final inputImage = _frameToInputImage(img);
      if (inputImage == null) return;
      final result = await _textRecognizer.processImage(inputImage);
      final text = result.text.toLowerCase();
      final hasDocText =
          text.contains('license') ||
          text.contains('driver') ||
          text.contains('dob') ||
          text.contains('exp') ||
          text.contains('class') ||
          text.contains('state') ||
          text.contains('name') ||
          text.contains('address') ||
          text.contains('dl') ||
          text.contains('iss') ||
          text.contains('passport') ||
          text.contains('nationality') ||
          text.contains('birth') ||
          text.contains('gobierno') ||
          text.contains('licencia') ||
          result.blocks.length >= 3;
      if (mounted && _capturedPath == null) {
        setState(() => _documentDetected = hasDocText);
      }
    } catch (e) {
      debugPrint('⚠️ Doc-scan error: $e');
    }
  }

  @override
  void dispose() {
    _cornerAnim.dispose();
    _textRecognizer.close();
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    // Wait for any in-progress OCR pass, then stop the silent stream
    // BEFORE the still — the shutter sound here is the only one the page
    // should ever make, because the user tapped the button.
    while (_scanning) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    try {
      await _ctrl!.stopImageStream();
    } catch (_) {}
    if (mounted) setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await _ctrl!.takePicture();
      // Run OCR on captured image to verify it's a document
      final inputImage = InputImage.fromFilePath(xFile.path);
      final result = await _textRecognizer.processImage(inputImage);
      final text = result.text.toLowerCase();
      final isLicense =
          text.contains('license') ||
          text.contains('driver') ||
          text.contains('dob') ||
          text.contains('exp') ||
          text.contains('class') ||
          text.contains('state') ||
          text.contains('name') ||
          text.contains('address') ||
          text.contains('dl') ||
          text.contains('iss') ||
          result.blocks.length >= 3; // at least 3 text blocks = real document

      if (isLicense) {
        if (mounted) {
          setState(() {
            _capturedPath = xFile.path;
            _documentDetected = true;
            _detectedHint = '';
          });
        }
      } else {
        // Not a valid document — let user retry
        if (mounted) {
          setState(() {
            _capturedPath = xFile.path;
            _documentDetected = false;
            _detectedHint = S.of(context).noDocumentDetected;
          });
        }
      }
    } catch (_) {
      // If OCR fails, still allow the photo
      try {
        final xFile = await _ctrl!.takePicture();
        if (mounted) {
          setState(() {
            _capturedPath = xFile.path;
            _documentDetected = true;
          });
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _capturing = false);
  }

  void _retake() {
    setState(() {
      _capturedPath = null;
      _documentDetected = false;
    });
    unawaited(_startStream());
  }

  String _sideTitle(BuildContext context) {
    switch (widget.side) {
      case 'Front':
        return S.of(context).scanFrontLicense;
      case 'Back':
        return S.of(context).scanBackLicense;
      case 'Car Registration':
        return 'Scan Car Registration';
      case 'Passport':
        return S.of(context).scanPassport;
      case 'ID':
        return S.of(context).scanId;
      default:
        return S.of(context).scanDocument;
    }
  }

  void _usePhoto() => Navigator.of(context).pop(_capturedPath);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _capturedPath != null ? _buildPreview() : _buildScanner(),
    );
  }

  // ── Preview captured photo ──────────────────────────────────────────────────
  Widget _buildPreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(_capturedPath!), fit: BoxFit.cover),
        // Dark overlay
        Container(color: Colors.black.withValues(alpha: 0.4)),
        // Top bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _retake,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  _sideTitle(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 40),
              ],
            ),
          ),
        ),
        // Bottom buttons
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
              child: Column(
                children: [
                  // Warning when OCR did not detect a document
                  if (!_documentDetected && _detectedHint.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade900.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _detectedHint,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _usePhoto,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        S.of(context).usePhoto,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      onPressed: _retake,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white30),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        S.of(context).retake,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Live camera scanner ─────────────────────────────────────────────────────
  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview or loading
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
            child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
          ),

        // Dark overlay with card cutout
        if (_initialized) _buildOverlay(context),

        // Top bar with X button in corner
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(null),
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
                  const Spacer(),
                  Text(
                    _sideTitle(context),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _toggleFlash,
                    child: Container(
                      width: 40,
                      height: 40,
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
                            : _gold,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Instruction text
        Positioned(
          bottom: 180,
          left: 24,
          right: 24,
          child: Text(
            _documentDetected
                ? S.of(context).documentDetectedTakePhoto
                : S.of(context).alignDocumentInstruction,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _documentDetected
                  ? const Color(0xFF4CAF50)
                  : Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
            ),
          ),
        ),

        // Shutter button — always visible
        Positioned(
          bottom: 56,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _initialized ? _capture : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _capturing ? 68 : 74,
                height: _capturing ? 68 : 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _documentDetected ? const Color(0xFF4CAF50) : _gold,
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_documentDetected ? const Color(0xFF4CAF50) : _gold)
                              .withValues(alpha: 0.45),
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

  Widget _buildOverlay(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final frameW = size.width * 0.82;
    final frameH = frameW * 0.63; // standard credit-card ratio
    final frameLeft = (size.width - frameW) / 2;
    final frameTop = (size.height - frameH) / 2 - 30;

    return AnimatedBuilder(
      animation: _cornerAnim,
      builder: (_, __) {
        final glow = _cornerAnim.value;
        return Stack(
          children: [
            // Semi-transparent overlay (4 rects = top, bottom, left, right)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: frameTop,
              child: Container(color: Colors.black.withValues(alpha: 0.62)),
            ),
            Positioned(
              top: frameTop + frameH,
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(color: Colors.black.withValues(alpha: 0.62)),
            ),
            Positioned(
              top: frameTop,
              left: 0,
              width: frameLeft,
              height: frameH,
              child: Container(color: Colors.black.withValues(alpha: 0.62)),
            ),
            Positioned(
              top: frameTop,
              left: frameLeft + frameW,
              right: 0,
              height: frameH,
              child: Container(color: Colors.black.withValues(alpha: 0.62)),
            ),

            // Frame border — green when document detected, gold otherwise
            Positioned(
              top: frameTop,
              left: frameLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: frameW,
                height: frameH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _documentDetected
                        ? const Color(
                            0xFF4CAF50,
                          ).withValues(alpha: 0.7 + 0.3 * glow)
                        : _gold.withValues(alpha: 0.5 + 0.5 * glow),
                    width: _documentDetected ? 3 : 2,
                  ),
                ),
              ),
            ),

            // Corner accents
            ..._corners(frameLeft, frameTop, frameW, frameH, glow),
          ],
        );
      },
    );
  }

  List<Widget> _corners(double l, double t, double w, double h, double glow) {
    const len = 22.0;
    const thick = 3.0;
    final color = _documentDetected
        ? Color.lerp(const Color(0xFF81C784), const Color(0xFF4CAF50), glow)!
        : Color.lerp(const Color(0xFFF5D990), _gold, glow)!;
    return [
      // Top-left
      Positioned(
        top: t,
        left: l,
        child: _corner(color, len, thick, true, true),
      ),
      // Top-right
      Positioned(
        top: t,
        left: l + w - len,
        child: _corner(color, len, thick, false, true),
      ),
      // Bottom-left
      Positioned(
        top: t + h - len,
        left: l,
        child: _corner(color, len, thick, true, false),
      ),
      // Bottom-right
      Positioned(
        top: t + h - len,
        left: l + w - len,
        child: _corner(color, len, thick, false, false),
      ),
    ];
  }

  Widget _corner(Color c, double len, double thick, bool left, bool top) {
    return SizedBox(
      width: len,
      height: len,
      child: CustomPaint(painter: _CornerPainter(c, thick, left, top)),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double thick;
  final bool left;
  final bool top;
  const _CornerPainter(this.color, this.thick, this.left, this.top);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thick
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final x = left ? 0.0 : size.width;
    final y = top ? 0.0 : size.height;
    final hx = left ? size.width : 0.0;
    final vy = top ? size.height : 0.0;
    canvas.drawLine(Offset(x, y), Offset(hx, y), paint);
    canvas.drawLine(Offset(x, y), Offset(x, vy), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}
