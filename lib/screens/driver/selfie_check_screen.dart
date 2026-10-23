import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';
import '../../utils/app_platform.dart';
import '../../utils/selfie_variant.dart';
import '../../widgets/selfie_verify_card.dart';

/// The 24 h GO selfie check (owner spec 2026-10-23): NOT the 4-step
/// biometric liveness page — step 1 is the guide's own instruction card
/// (the SHARED SelfieVerifyCard; the shutter flash stays guide-only), step
/// 2 a FRONT-camera manual still with the license scanner's frame design.
///
/// Output contract is identical to the old FaceLivenessScreen flow: pops
/// `{'photo': path}` on success, null on cancel — the GO call sites keep
/// their logic untouched.
class SelfieCheckScreen extends StatefulWidget {
  const SelfieCheckScreen({super.key});

  @override
  State<SelfieCheckScreen> createState() => _SelfieCheckScreenState();
}

class _SelfieCheckScreenState extends State<SelfieCheckScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF14141A);

  int _step = 0; // 0 = instructions card · 1 = front camera
  String _variant = 'std_m';
  bool _vip = false;

  /// Step-1 entrance cascade — the same language as the guide pages.
  late final AnimationController _entry;

  // Camera — initialized ONLY on entering step 2 (no permission prompt
  // while the driver is still reading the instructions).
  CameraController? _ctrl;
  bool _initialized = false;
  bool _capturing = false;

  /// Animated gold frame corners — the scanner's 1400 ms repeat-reverse.
  late final AnimationController _cornerAnim;

  /// Capture feedback flash (the guide's shutter idiom, reused for the
  /// manual shot).
  late final AnimationController _shotFlash;
  late final Animation<double> _shotFlashOpacity;

  /// Capture preset — copied from license_scanner_screen.dart's
  /// doc-comment: iOS runs ultraHigh, NEVER max (the plugin's .max branch
  /// overrides the active format AND sets `isHighResolutionPhotoEnabled`
  /// on the still — on iOS 16+ that capture raises a native NSException
  /// and the app CLOSES at capture). Android keeps max (CameraX's fallback
  /// chain has no such branch).
  static ResolutionPreset get _capturePreset =>
      AppPlatform.isIOS ? ResolutionPreset.ultraHigh : ResolutionPreset.max;

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
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _cornerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _shotFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _shotFlashOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: 0.55), weight: 40),
      TweenSequenceItem(tween: Tween<double>(begin: 0.55, end: 0), weight: 60),
    ]).animate(CurvedAnimation(parent: _shotFlash, curve: Curves.easeOut));
    _resolveVariant();
  }

  /// Same tier×gender resolution as the guide — one shared helper.
  Future<void> _resolveVariant() async {
    final variant = await resolveSelfieVariant();
    if (!mounted) return;
    setState(() {
      _variant = variant;
      _vip = variant.startsWith('vip');
    });
  }

  @override
  void dispose() {
    _entry.dispose();
    _cornerAnim.dispose();
    _shotFlash.dispose();
    // Null-swap: la animación de salida de la ruta rebuilda este widget
    // DESPUÉS de dispose() — con el campo en null el build cae al
    // placeholder en vez de llamar buildPreview sobre un controller
    // dispuesto (Crashlytics 2026-10-17: "Disposed CameraController").
    final c = _ctrl;
    _ctrl = null;
    c?.dispose();
    super.dispose();
  }

  void _openCamera() {
    HapticService.selectionClick();
    setState(() => _step = 1);
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
    // FRONT camera — a straight-on selfie, not a document scan.
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    // See _capturePreset: iOS ultraHigh never max, Android max. No image
    // stream and no format group — there is no OCR here.
    _ctrl = CameraController(front, _capturePreset, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('⚠️ Selfie camera init failed: $e');
      // Retry once after a short delay
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      try {
        final old = _ctrl;
        _ctrl = null;
        await old?.dispose();
        _ctrl = CameraController(front, _capturePreset, enableAudio: false);
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        if (mounted) setState(() => _initialized = true);
      } catch (_) {
        if (mounted) Navigator.of(context).pop(null);
      }
    }
  }

  /// Manual capture — no OCR, no ML Kit, no auto-capture: takePicture() on
  /// the tap, a brief white flash as the feedback, then pop the result.
  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await _ctrl!.takePicture();
      _shotFlash.forward(from: 0);
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      Navigator.of(context).pop({'photo': xFile.path});
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _step == 0 ? _navy : Colors.black,
      body: _step == 0 ? _buildInstructions() : _buildCamera(),
    );
  }

  // ── Step 1: the instruction card (the guide's page-6 design, no flash) ──

  Widget _cascade(Widget child, double begin, double end) {
    final anim = CurvedAnimation(
      parent: _entry,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position:
            Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(anim),
        child: child,
      ),
    );
  }

  Widget _buildInstructions() {
    final s = S.of(context);
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(null),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 24),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _cascade(
                    SelfieVerifyCard(
                      variant: _variant,
                      vip: _vip,
                      flash: false,
                      active: true,
                      badge: '1',
                    ),
                    0.0,
                    0.45,
                  ),
                  const SizedBox(height: 26),
                  _cascade(
                    Text(
                      s.selfieVerifyTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    0.35,
                    0.7,
                  ),
                  const SizedBox(height: 14),
                  _cascade(
                    Text(
                      _vip ? s.selfieBodyVip : s.selfieBodyStd,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 15,
                        height: 1.55,
                      ),
                    ),
                    0.6,
                    1.0,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                24, 8, 24, MediaQuery.of(context).padding.bottom + 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _openCamera,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  elevation: 4,
                  shadowColor: _gold.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  s.faceCheckTakeSelfie,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2: front camera with the scanner's frame design ──

  Widget _buildCamera() {
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

        // Dark overlay with the animated gold face frame
        if (_initialized) _buildOverlay(context),

        // Capture feedback flash over the whole preview
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _shotFlashOpacity,
            builder: (ctx, _) => Opacity(
              opacity: _shotFlashOpacity.value,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),

        // Top bar — the license scanner's design (2026-10-23 owner spec:
        // "el mismo diseño de tomarle foto a la licencia en el registro"):
        // X left (cancel pops null — the GO call sites read that as "no
        // GO"), centered title, and a 40 px spacer on the right where the
        // scanner keeps its flash toggle (front cameras have no torch — a
        // dead button there would be a lie).
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
                    S.of(context).selfieVerifyTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
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
        ),

        // Hint under the frame (same height as the scanner's instruction)
        Positioned(
          bottom: 180,
          left: 24,
          right: 24,
          child: Text(
            S.of(context).faceCheckFrameHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.4,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
            ),
          ),
        ),

        // Gold manual shutter — always visible
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
    final frameW = size.width * 0.72;
    final frameH = frameW * 1.3; // portrait face frame
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

            // Frame border — the gold breathes with the corner animation.
            // Radius 12 like the license scanner's card frame (owner spec
            // 2026-10-23: same design language, portrait for a face).
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
      Positioned(
          top: t, left: l, child: _corner(color, len, thick, true, true)),
      Positioned(
          top: t,
          left: l + w - len,
          child: _corner(color, len, thick, false, true)),
      Positioned(
          top: t + h - len,
          left: l,
          child: _corner(color, len, thick, true, false)),
      Positioned(
          top: t + h - len,
          left: l + w - len,
          child: _corner(color, len, thick, false, false)),
    ];
  }

  Widget _corner(Color c, double len, double thick, bool left, bool top) {
    return SizedBox(
      width: len,
      height: len,
      child: CustomPaint(painter: _FaceCornerPainter(c, thick, left, top)),
    );
  }
}

/// The scanner's corner tick, repainted for the face frame.
class _FaceCornerPainter extends CustomPainter {
  final Color color;
  final double thick;
  final bool left;
  final bool top;
  const _FaceCornerPainter(this.color, this.thick, this.left, this.top);

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
  bool shouldRepaint(_FaceCornerPainter old) => old.color != color;
}
