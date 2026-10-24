import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/socket_service.dart';
import '../../utils/app_platform.dart';
import '../../utils/selfie_variant.dart';
import '../../widgets/selfie_verify_card.dart';

/// The 24 h GO selfie check (owner spec 2026-10-23): NOT the 4-step
/// biometric liveness page — step 1 is the guide's own instruction card
/// (the SHARED SelfieVerifyCard; the shutter flash stays guide-only), step
/// 2 a FRONT-camera manual still with the LICENSE-CAPTURE page design
/// (`license_capture_screen.dart`: rounded preview card, X inside the
/// frame, copy below, gold shutter + flash toggle).
///
/// The screen uploads the shot ITSELF (owner spec 2026-10-23: "no se
/// cerrara y aparecera un loading"). When the selfie lands in MANUAL review
/// (a driver dispatch rejected once), step 3 holds a verifying loader until
/// dispatch's decision lands over the live socket (REST poll as the net,
/// 90 s ceiling) — approve pops already-`approved` so the caller connects
/// with ZERO home detour.
///
/// Output contract: pops `{'photo': path, 'approved': true|false}` on a
/// decision, `{'photo': path, 'pending': true}` when dispatch has not
/// decided (timeout / X escape), a bare `{'photo': path}` when the upload
/// itself failed (callers stay fail-open), and null on cancel.
class SelfieCheckScreen extends StatefulWidget {
  const SelfieCheckScreen({super.key});

  @override
  State<SelfieCheckScreen> createState() => _SelfieCheckScreenState();
}

class _SelfieCheckScreenState extends State<SelfieCheckScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _navy = Color(0xFF14141A);

  int _step = 0; // 0 = instructions card · 1 = front camera · 2 = verifying
  String _variant = 'std_m';
  bool _vip = false;

  /// Step-1 entrance cascade — the same language as the guide pages.
  late final AnimationController _entry;

  // Camera — initialized ONLY on entering step 2 (no permission prompt
  // while the driver is still reading the instructions).
  CameraController? _ctrl;
  bool _initialized = false;
  bool _capturing = false;
  FlashMode _flashMode = FlashMode.off;

  // Step 2 "verifying" (manual dispatch review): the page HOLDS until the
  // decision lands — live socket first, a 5 s REST poll as the net, a 90 s
  // ceiling so nobody is trapped. `_reviewDone` latches the first outcome.
  StreamSubscription<Map<String, dynamic>>? _reviewSub;
  Timer? _reviewPoll;
  Timer? _reviewTimeout;
  String? _reviewPhotoPath;
  bool _reviewDone = false;

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
    _reviewSub?.cancel();
    _reviewPoll?.cancel();
    _reviewTimeout?.cancel();
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
  /// the gold shutter tap, then STRAIGHT into the verifying step (owner spec
  /// 2026-10-23: the page no longer closes here to reconnect 1-3 s later at
  /// home — it closes when the selfie is APPROVED and the driver is already
  /// activating).
  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    HapticService.mediumImpact();
    try {
      final xFile = await _ctrl!.takePicture();
      if (!mounted) return;
      _uploadAndVerify(xFile.path);
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Flash toggle — same spot as the license-capture design. Front cameras
  /// usually have no torch unit: a failed write just leaves the mode as-is.
  Future<void> _toggleFlash() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await c.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {}
  }

  /// Step 2 → 3: the upload runs under the verifying loader; the answer
  /// decides the exit. Auto-approved (the daily check, or the review flag
  /// cleared in the meantime) closes the page already approved — the caller
  /// connects on the spot.
  Future<void> _uploadAndVerify(String photoPath) async {
    setState(() {
      _step = 2;
      _reviewPhotoPath = photoPath;
      _reviewDone = false;
    });
    final resp = await ApiService.submitFaceCheck(photoPath);
    if (!mounted || _reviewDone) return;
    if (resp == null) {
      // Upload failed — the callers stay fail-open: bare photo pops and
      // their old logic decides (daily gate still connects; verify retries).
      _reviewDone = true;
      Navigator.of(context).pop({'photo': photoPath});
      return;
    }
    if (resp['pending_review'] != true) {
      _finishReview(true);
      return;
    }
    _startReviewWait();
  }

  /// Manual review wait: the live socket (face_check_reviewed) answers
  /// instantly; a 5 s canGoOnline poll is the net under a dead socket; a
  /// 90 s ceiling pops "pending" so the driver is never trapped (the grey
  /// review GO + 30 s poll take over from there).
  void _startReviewWait() {
    _reviewSub =
        SocketService.faceCheckReviewStream.listen((data) {
      _finishReview(data['approved'] == true);
    });
    _reviewPoll = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final r = await ApiService.canGoOnline()
            .timeout(const Duration(seconds: 10));
        if (!mounted || _reviewDone) return;
        if (r['face_check_pending'] == true) return; // still on the desk
        _finishReview(r['face_review_required'] == true ? false : true);
      } catch (_) {}
    });
    _reviewTimeout = Timer(const Duration(seconds: 90), () {
      _finishReview(null);
    });
  }

  /// One outcome, once: true approved · false rejected · null still pending
  /// (timeout or the escape X on the verifying view).
  void _finishReview(bool? approved) {
    if (_reviewDone) return;
    _reviewDone = true;
    _reviewSub?.cancel();
    _reviewPoll?.cancel();
    _reviewTimeout?.cancel();
    if (!mounted) return;
    final path = _reviewPhotoPath;
    if (path == null) {
      Navigator.of(context).pop(null);
      return;
    }
    Navigator.of(context).pop({
      'photo': path,
      if (approved == null) 'pending': true else 'approved': approved,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: switch (_step) {
        1 => _buildCamera(),
        2 => _buildVerifying(),
        _ => _buildInstructions(),
      },
    );
  }

  // ── Step 3: verifying — the page HOLDS until dispatch decides ──

  Widget _buildVerifying() {
    final s = S.of(context);
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                        color: _gold, strokeWidth: 3),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    s.faceCheckVerifyingTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    s.faceCheckVerifyingBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 15,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Escape hatch (never trapped): pops "pending" — the caller's
          // grey review GO + 30 s poll take it from there.
          Positioned(
            top: 0,
            left: 0,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: IconButton(
                onPressed: () => _finishReview(null),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 24),
              ),
            ),
          ),
        ],
      ),
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
                  const SizedBox(height: 18),
                  _cascade(
                    SelfieVerifyChips(vip: _vip),
                    0.72,
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

  // ── Step 2: front camera with the LICENSE-CAPTURE design (owner spec
  // 2026-10-23: "así debe ser cuando se van a tomar la foto" — the SAME
  // layout as the registration's license photo page: rounded preview card,
  // X inside the frame, copy below, gold shutter + flash toggle) ──

  Widget _buildCamera() {
    final s = S.of(context);
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;

    final preview = _initialized && _ctrl != null
        ? FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _ctrl!.value.previewSize!.height,
              height: _ctrl!.value.previewSize!.width,
              child: CameraPreview(_ctrl!),
            ),
          )
        : const ColoredBox(
            color: Colors.black,
            child: Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: pad.top + 12),
        // Rounded preview card (~57% of the screen) — the X rides INSIDE
        // the frame (cancel pops null — the GO call sites read "no GO").
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: size.height * 0.57,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  preview,
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
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
                  ),
                ],
              ),
            ),
          ),
        ),
        // Copy below the preview — the license page's rhythm.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
            child: Column(
              children: [
                Text(
                  s.selfieVerifyTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  s.faceCheckFrameHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 14.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Gold shutter + flash toggle (front cameras usually lack a torch —
        // a failed write just leaves the mode as-is, see _toggleFlash).
        Padding(
          padding: EdgeInsets.only(bottom: pad.bottom + 28, top: 8),
          child: SizedBox(
            height: 74,
            child: Stack(
              alignment: Alignment.center,
              children: [
                GestureDetector(
                  onTap: _initialized ? _capture : null,
                  child: Container(
                    width: 74,
                    height: 74,
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
                Positioned(
                  right: 36,
                  child: GestureDetector(
                    onTap: _toggleFlash,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C24),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
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
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
