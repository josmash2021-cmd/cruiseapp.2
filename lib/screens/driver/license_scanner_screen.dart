import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../l10n/app_localizations.dart';

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

  CameraController? _ctrl;
  bool _initialized = false;
  String? _capturedPath;
  bool _capturing = false;

  // OCR
  final _textRecognizer = TextRecognizer();
  bool _scanning = false;
  bool _documentDetected = false;
  String _detectedHint = '';

  // Auto-capture
  bool _showManualButton = false;
  Timer? _manualButtonTimer;
  bool _autoCapturing = false;
  Timer? _autoCaptureTimer;

  late AnimationController _cornerAnim;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
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
    _ctrl = CameraController(rear, ResolutionPreset.high, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() => _initialized = true);
        _startAutoScan();
        _startManualButtonTimer();
      }
    } catch (e) {
      debugPrint('⚠️ Camera init failed: $e');
      // Retry once after a short delay
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        _ctrl?.dispose();
        _ctrl = CameraController(
          rear,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        if (mounted) {
          setState(() => _initialized = true);
          _startAutoScan();
          _startManualButtonTimer();
        }
      } catch (_) {
        if (mounted) Navigator.of(context).pop(null);
      }
    }
  }

  /// Start scanning frames with OCR for auto-capture.
  void _startAutoScan() {
    // Check every 1.5 seconds
    _autoCaptureTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _scanForDocument(),
    );
  }

  /// Show manual shutter after 60s fallback.
  void _startManualButtonTimer() {
    _manualButtonTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) setState(() => _showManualButton = true);
    });
  }

  /// Scan current frame for document text via OCR.
  Future<void> _scanForDocument() async {
    if (_ctrl == null ||
        !_ctrl!.value.isInitialized ||
        _capturing ||
        _scanning ||
        _capturedPath != null ||
        !mounted) {
      return;
    }
    _scanning = true;
    try {
      final xFile = await _ctrl!.takePicture();
      final inputImage = InputImage.fromFilePath(xFile.path);
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
      if (hasDocText && mounted && _capturedPath == null) {
        // Auto-capture!
        setState(() => _autoCapturing = true);
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) {
          _autoCaptureTimer?.cancel();
          _capturedPath = xFile.path;
          _documentDetected = true;
          setState(() => _autoCapturing = false);
        }
      }
      // Clean up temp file if we didn't use it
      if (_capturedPath != xFile.path) {
        try {
          File(xFile.path).deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('⚠️ Auto-scan error: $e');
    }
    _scanning = false;
  }

  @override
  void dispose() {
    _cornerAnim.dispose();
    _textRecognizer.close();
    _ctrl?.dispose();
    _manualButtonTimer?.cancel();
    _autoCaptureTimer?.cancel();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticFeedback.mediumImpact();
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
    setState(() => _capturedPath = null);
    // Restart auto-scan when retaking
    _autoCaptureTimer?.cancel();
    _startAutoScan();
  }

  String _sideTitle(BuildContext context) {
    switch (widget.side) {
      case 'Front':
        return S.of(context).scanFrontLicense;
      case 'Back':
        return S.of(context).scanBackLicense;
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

        // Top bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(null),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  _sideTitle(context),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 40),
              ],
            ),
          ),
        ),

        // Instruction text
        Positioned(
          bottom: _showManualButton ? 180 : 80,
          left: 24,
          right: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_autoCapturing)
                Text(
                  S.of(context).autoCapturing,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                  ),
                )
              else
                Text(
                  S.of(context).alignDocumentInstruction,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                    shadows: const [
                      Shadow(color: Colors.black87, blurRadius: 8),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Shutter button — hidden until 60s fallback
        if (_showManualButton)
          Positioned(
            bottom: 56,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _initialized ? _capture : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: _capturing ? 68 : 74,
                  height: _capturing ? 68 : 74,
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
      builder: (_, _) {
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

            // Frame border
            Positioned(
              top: frameTop,
              left: frameLeft,
              child: Container(
                width: frameW,
                height: frameH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.5 + 0.5 * glow),
                    width: 2,
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
    final color = Color.lerp(const Color(0xFFF5D990), _gold, glow)!;
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
