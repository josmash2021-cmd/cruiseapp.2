import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';

/// Rider identity verification flow:
///  Step 0 — Intro: choose document type
///  Step 1 — Scan document(s) inline (front, then back for license)
///  Step 2 — Selfie capture
///  Step 3 — Processing / submitting
///  Step 4 — Pending dispatch review
///  Step 5 — Confirmed (approved)
///  Step 6 — Rejected
class IdentityVerificationScreen extends StatefulWidget {
  const IdentityVerificationScreen({super.key});

  @override
  State<IdentityVerificationScreen> createState() =>
      _IdentityVerificationScreenState();
}

class _IdentityVerificationScreenState extends State<IdentityVerificationScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldDark = Color(0xFFB8972E);

  // 0=intro, 1=scanning, 2=selfie-guide, 3=processing, 4=pending, 5=confirmed, 6=rejected
  int _step = 0;
  String? _docFrontPath;
  String? _docBackPath;
  String? _selfiePath;
  String _docType = ''; // 'license', 'government_id', 'passport'
  bool _scanningBack = false; // true when capturing back side of license
  bool _processing = false;
  bool _verified = false;
  String? _rejectionReason;
  Timer? _pollTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _firestoreSubscription;
  Map<String, String>? _cachedUser;

  late AnimationController _pulseCtrl;
  late AnimationController _checkCtrl;

  bool get _needsBackSide => _docType == 'license';

  /// Total photos needed (not counting selfie)
  int get _totalDocPhotos => _needsBackSide ? 2 : 1;

  /// Current doc photo step (1-based)
  int get _currentDocPhoto => _scanningBack ? 2 : 1;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _checkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _preloadUser();
  }

  Future<void> _preloadUser() async {
    final u = await UserSession.getUser();
    if (mounted) setState(() => _cachedUser = u);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _firestoreSubscription?.cancel();
    _pulseCtrl.dispose();
    _checkCtrl.dispose();
    super.dispose();
  }

  // ════════════════════════════════════════════════════
  //  FLOW CONTROL
  // ════════════════════════════════════════════════════

  /// User picked a doc type — go to scanner for the front
  void _selectDocType(String type) {
    setState(() {
      _docType = type;
      _scanningBack = false;
      _docFrontPath = null;
      _docBackPath = null;
      _step = 1; // scanning
    });
  }

  /// Called when user taps "Use Photo" on the scanner screen.
  /// Advances to next step inline.
  void _onDocPhotoTaken(String path) {
    if (!_scanningBack) {
      // Just took front side
      _docFrontPath = path;
      if (_needsBackSide) {
        // License needs back side — stay on scanner, switch to back
        setState(() {
          _scanningBack = true;
        });
      } else {
        // Passport / Gov ID — only front needed, go to selfie
        setState(() => _step = 2);
      }
    } else {
      // Just took back side
      _docBackPath = path;
      setState(() => _step = 2); // selfie
    }
  }

  /// User confirmed selfie guide — open camera
  Future<void> _captureSelfie() async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
      );
      if (xFile == null || !mounted) return;
      _selfiePath = xFile.path;
      setState(() {
        _step = 3; // processing
        _processing = true;
      });
      await _completeVerification();
    } catch (e) {
      debugPrint('Selfie capture failed: $e');
    }
  }

  Future<void> _completeVerification() async {
    final Map<String, dynamic> body = {
      'id_document_type': _docType,
      'role': 'rider',
    };

    // Encode front
    if (_docFrontPath != null) {
      try {
        final bytes = await File(_docFrontPath!).readAsBytes();
        body['license_front'] = base64Encode(bytes);
      } catch (e) {
        debugPrint('Failed to read doc front: $e');
      }
    }

    // Encode back (license only)
    if (_docBackPath != null) {
      try {
        final bytes = await File(_docBackPath!).readAsBytes();
        body['license_back'] = base64Encode(bytes);
      } catch (e) {
        debugPrint('Failed to read doc back: $e');
      }
    }

    // Encode selfie + profile photo
    if (_selfiePath != null) {
      try {
        final bytes = await File(_selfiePath!).readAsBytes();
        final encoded = base64Encode(bytes);
        body['selfie'] = encoded;
        body['profile_photo'] = encoded;
      } catch (e) {
        debugPrint('Failed to read selfie: $e');
      }
    }

    // Save selfie locally as profile photo immediately
    if (_selfiePath != null) {
      await UserSession.updateField('photo', _selfiePath!);
    }

    // Submit to backend
    try {
      await ApiService.submitVerification(body);
    } catch (e) {
      debugPrint('Verification submission failed: $e');
    }

    await UserSession.updateField('verificationStatus', 'pending');
    await UserSession.updateField('idDocumentType', _docType);

    if (!mounted) return;
    setState(() {
      _processing = false;
      _step = 4; // pending
    });

    _startPolling();
    _attachFirestoreListener();
  }

  // ════════════════════════════════════════════════════
  //  FIRESTORE + POLLING
  // ════════════════════════════════════════════════════

  void _attachFirestoreListener() async {
    // Retry Firebase Auth up to 3 times before giving up
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (FirebaseAuth.instance.currentUser == null) {
          await FirebaseAuth.instance.signInAnonymously();
        }
        break; // success
      } catch (e) {
        debugPrint('[IdentityVerification] Firebase Auth attempt ${attempt + 1} failed: $e');
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 2));
        // On final failure continue without Firestore — polling fallback covers it
      }
    }

    final user = await UserSession.getUser();
    final userId = user?['userId'];
    if (userId == null || userId.isEmpty || !mounted) return;
    final userIdInt = int.tryParse(userId) ?? 0;
    if (userIdInt <= 0) return;

    final docId = 'sql_$userIdInt';

    // One-shot immediate check before the stream fires
    try {
      final snap = await FirebaseFirestore.instance
          .collection('verifications')
          .doc(docId)
          .get()
          .timeout(const Duration(seconds: 5));
      if (snap.exists && mounted) _processVerificationData(snap.data() ?? {});
    } catch (e) {
      debugPrint('[IdentityVerification] Immediate Firestore GET failed: $e');
    }

    if (!mounted || _verified) return;

    // Real-time listener by doc ID (most reliable)
    _firestoreSubscription?.cancel();
    _firestoreSubscription = FirebaseFirestore.instance
        .collection('verifications')
        .where('userId', isEqualTo: userIdInt)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      for (final doc in snapshot.docs) {
        _processVerificationData(doc.data());
        if (_verified) return;
      }
    }, onError: (e) {
      debugPrint('[IdentityVerification] Firestore listener error: $e');
    });
  }

  /// Central approval logic so both the one-shot GET and the stream use the same check.
  void _processVerificationData(Map<String, dynamic> data) {
    if (!mounted || _verified) return;
    final status = data['status'] as String? ??
        data['verificationStatus'] as String? ??
        data['approvalStatus'] as String? ??
        '';
    final isApproved = status == 'approved' ||
        data['isVerified'] == true ||
        data['isApproved'] == true;
    if (isApproved) {
      _pollTimer?.cancel();
      LocalDataService.setIdentityVerified(_docType.isNotEmpty ? _docType : 'license');
      UserSession.updateField('isVerified', 'true');
      UserSession.updateField('verificationStatus', 'approved');
      final photoUrl = data['profilePhotoUrl'] as String? ??
          data['selfieUrl'] as String?;
      if (photoUrl != null && photoUrl.isNotEmpty) {
        UserSession.updateField('photo', photoUrl);
      }
      _checkCtrl.forward();
      setState(() {
        _verified = true;
        _step = 5;
      });
    } else if (status == 'rejected' && _step != 6) {
      _pollTimer?.cancel();
      final reason = data['reason'] as String? ??
          data['verificationReason'] as String? ??
          'Verification was not approved';
      UserSession.updateField('verificationStatus', 'rejected');
      setState(() {
        _rejectionReason = reason;
        _step = 6;
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    int pollAttempts = 0;
    // Fallback poll at 2 s — fast enough that if the Firestore listener is
    // briefly disconnected (cold start, network flap) the rider still sees
    // the dispatch approval within ~2 s. FCM push is the primary path;
    // Firestore listener is the secondary; this poll is the final safety
    // net. Backend handler is cheap (single indexed SELECT).
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      pollAttempts++;
      try {
        final result = await ApiService.getVerificationStatus();
        final status = result['verification_status'] as String? ?? 'pending';
        if (!mounted) return;

        if (status == 'approved') {
          _pollTimer?.cancel();
          await LocalDataService.setIdentityVerified(_docType.isNotEmpty ? _docType : 'license');
          await UserSession.updateField('isVerified', 'true');
          await UserSession.updateField('verificationStatus', 'approved');
          final photoUrl = result['profile_photo_url'] as String? ??
              result['selfie_url'] as String?;
          if (photoUrl != null && photoUrl.isNotEmpty) {
            await UserSession.updateField('photo', photoUrl);
          }
          if (!mounted) return;
          _checkCtrl.forward();
          setState(() {
            _verified = true;
            _step = 5;
          });
        } else if (status == 'rejected') {
          _pollTimer?.cancel();
          final reason =
              result['verification_reason'] as String? ??
              'Verification was not approved';
          await UserSession.updateField('verificationStatus', 'rejected');
          if (!mounted) return;
          setState(() {
            _rejectionReason = reason;
            _step = 6;
          });
        } else if (pollAttempts >= 120) {
          _pollTimer?.cancel();
        }
      } catch (e) {
        debugPrint('Verification poll failed: $e');
        if (pollAttempts >= 120) _pollTimer?.cancel();
      }
    });
  }

  // ════════════════════════════════════════════════════
  //  BUILD
  // ════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // Scanner step is full-screen (no SafeArea scaffold)
    if (_step == 1) {
      return _InlineDocScanner(
        docType: _docType,
        isBack: _scanningBack,
        currentPhoto: _currentDocPhoto,
        totalPhotos: _totalDocPhotos,
        onPhotoTaken: _onDocPhotoTaken,
        onCancel: () {
          if (_scanningBack) {
            // Go back to front
            setState(() => _scanningBack = false);
          } else {
            // Go back to intro
            setState(() => _step = 0);
          }
        },
      );
    }

    final c = AppColors.of(context);
    return PopScope(
      canPop: _step != 4,
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: _buildStep(c),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(AppColors c) {
    switch (_step) {
      case 0:
        return _buildIntro(c);
      case 2:
        return _buildSelfieGuide(c);
      case 3:
        return _buildProcessing(c);
      case 4:
        return _buildPendingReview(c);
      case 5:
        return _buildConfirmed(c);
      case 6:
        return _buildRejected(c);
      default:
        return _buildIntro(c);
    }
  }

  // ═══════════════════════════════════════════
  //  Step 0 — Intro (clean checklist + start button)
  // ═══════════════════════════════════════════
  Widget _buildIntro(AppColors c) {
    return Padding(
      key: const ValueKey(0),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Icon(Icons.close_rounded, color: c.textPrimary, size: 28),
              ),
            ),
          ),
          const Spacer(flex: 2),
          // Shield icon
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [_gold, _goldDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.3),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const Icon(Icons.verified_user_rounded, color: Colors.black, size: 48),
          ),
          const SizedBox(height: 32),
          Text(
            S.of(context).verifyIdentity,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Verify your identity to start requesting rides',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 40),
          // Checklist items — uniform style
          _stepPreview(c, Icons.credit_card_rounded, 'Photo of your ID document'),
          const SizedBox(height: 16),
          _stepPreview(c, Icons.face_rounded, 'Selfie — becomes your profile photo'),
          const SizedBox(height: 16),
          _stepPreview(c, Icons.check_circle_outline_rounded, S.of(context).quickDispatchReview),
          const Spacer(flex: 3),
          // Start verification button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _showDocTypePicker,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Start Verification',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            S.of(context).documentsEncrypted,
            style: TextStyle(fontSize: 12, color: c.textTertiary),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0
                ? 12
                : MediaQuery.of(context).padding.bottom + 24,
          ),
        ],
      ),
    );
  }

  /// Bottom sheet to pick document type before opening camera
  void _showDocTypePicker() {
    final c = AppColors.of(context);
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: c.cardBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                S.of(context).chooseDocToScan,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 20),
              _docTypeSheetOption(
                c, ctx,
                Icons.credit_card_rounded,
                S.of(context).driversLicense,
                S.of(context).frontAndBack,
                'license',
              ),
              const SizedBox(height: 10),
              _docTypeSheetOption(
                c, ctx,
                Icons.badge_rounded,
                S.of(context).governmentId,
                S.of(context).frontOnly,
                'government_id',
              ),
              const SizedBox(height: 10),
              _docTypeSheetOption(
                c, ctx,
                Icons.menu_book_rounded,
                S.of(context).passport,
                S.of(context).frontOnly,
                'passport',
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ).then((type) {
      if (type != null && mounted) _selectDocType(type);
    });
  }

  Widget _docTypeSheetOption(
    AppColors c,
    BuildContext ctx,
    IconData icon,
    String title,
    String subtitle,
    String type,
  ) {
    return GestureDetector(
      onTap: () => Navigator.pop(ctx, type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _gold.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: _gold.withValues(alpha: 0.5), size: 22),
          ],
        ),
      ),
    );
  }

  Widget _stepPreview(AppColors c, IconData icon, String label) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: _gold, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════
  //  Step 2 — Selfie guide
  // ═══════════════════════════════════════════
  Widget _buildSelfieGuide(AppColors c) {
    return Padding(
      key: const ValueKey(2),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () {
                // Go back to scanner (front of doc)
                setState(() {
                  _step = 1;
                  _scanningBack = false;
                  _docFrontPath = null;
                  _docBackPath = null;
                });
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.arrow_back_rounded, color: c.textPrimary, size: 20),
              ),
            ),
          ),
          const Spacer(flex: 2),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withValues(alpha: 0.12),
            ),
            child: const Icon(Icons.face_rounded, color: _gold, size: 48),
          ),
          const SizedBox(height: 28),
          Text(
            'Take a Selfie',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'This photo will be your profile picture.\nLook straight at the camera with good lighting.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 32),
          _selfTip(c, Icons.light_mode_rounded, 'Good, even lighting on your face'),
          const SizedBox(height: 10),
          _selfTip(c, Icons.remove_red_eye_rounded, 'Eyes open, face fully visible'),
          const SizedBox(height: 10),
          _selfTip(c, Icons.no_photography_rounded, 'No sunglasses or hats'),
          const Spacer(flex: 3),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _captureSelfie,
              icon: const Icon(Icons.camera_alt_rounded, size: 20),
              label: const Text(
                'Open Camera',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0
                ? 12
                : MediaQuery.of(context).padding.bottom + 24,
          ),
        ],
      ),
    );
  }

  Widget _selfTip(AppColors c, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _gold),
        const SizedBox(width: 10),
        Text(text, style: TextStyle(fontSize: 14, color: c.textSecondary)),
      ],
    );
  }

  // ═══════════════════════════════════════════
  //  Step 3 — Processing
  // ═══════════════════════════════════════════
  Widget _buildProcessing(AppColors c) {
    return Center(
      key: const ValueKey(3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withValues(alpha: 0.12),
              ),
              child: const CircularProgressIndicator(color: _gold, strokeWidth: 3),
            ),
            const SizedBox(height: 24),
            Text(
              S.of(context).submittingVerification,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).encryptingUploading,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  //  Step 4 — Pending Review
  // ═══════════════════════════════════════════
  Widget _buildPendingReview(AppColors c) {
    return Padding(
      key: const ValueKey(4),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: SizedBox(
        width: double.infinity,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(flex: 2),
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) {
              return Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gold.withValues(alpha: 0.1 + _pulseCtrl.value * 0.1),
                ),
                child: Icon(
                  Icons.hourglass_top_rounded,
                  size: 50,
                  color: Color.lerp(_goldDark, _gold, _pulseCtrl.value),
                ),
              );
            },
          ),
          const SizedBox(height: 32),
          Text(
            'Pending Review',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your identity verification has been submitted.\nOur dispatch team is reviewing your documents.\nThis usually takes a few minutes.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3, color: _gold),
          ),
          const Spacer(flex: 2),
          Text(
            'You\'ll be notified when the review is complete',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: c.textTertiary),
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }

  // ═══════════════════════════════════════════
  //  Step 5 — Confirmed
  // ═══════════════════════════════════════════
  Widget _buildConfirmed(AppColors c) {
    final user = _cachedUser;
    final firstName = user?['firstName'] ?? '';
    final lastName = user?['lastName'] ?? '';
    final email = user?['email'] ?? '';
    final phone = user?['phone'] ?? '';

    return Padding(
      key: const ValueKey(5),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 60),
          AnimatedBuilder(
            animation: _checkCtrl,
            builder: (_, __) {
              return Transform.scale(
                scale: Curves.elasticOut.transform(_checkCtrl.value.clamp(0.0, 1.0)),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [_gold, _goldDark],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.3),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
                ),
              );
            },
          ),
          const SizedBox(height: 28),
          Text(
            'Identity Verified!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your identity has been confirmed. You can now request rides.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 40),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _gold.withValues(alpha: 0.3), width: 1),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.verified_rounded, color: _gold, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'Verification Details',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _detailRow(c, 'Name', '$firstName $lastName'.trim()),
                const SizedBox(height: 10),
                if (email.isNotEmpty) ...[
                  _detailRow(c, 'Email', email),
                  const SizedBox(height: 10),
                ],
                if (phone.isNotEmpty) ...[
                  _detailRow(c, 'Phone', phone),
                  const SizedBox(height: 10),
                ],
                _detailRow(c, 'Document', _docTypeLabel()),
                const SizedBox(height: 10),
                _detailRow(c, 'Status', 'Verified'),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Continue to Homescreen',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0
                ? 12
                : MediaQuery.of(context).padding.bottom + 24,
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════
  //  Step 6 — Rejected
  // ═══════════════════════════════════════════
  Widget _buildRejected(AppColors c) {
    return Padding(
      key: const ValueKey(6),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => Navigator.pop(context, false),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.close_rounded, color: c.textPrimary, size: 20),
              ),
            ),
          ),
          const Spacer(flex: 2),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red.withValues(alpha: 0.1),
            ),
            child: const Icon(Icons.warning_amber_rounded, size: 50, color: Colors.red),
          ),
          const SizedBox(height: 32),
          Text(
            'Verification Not Approved',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: c.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: Colors.red, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _rejectionReason ?? 'Your verification was not approved. Please try again.',
                    style: TextStyle(fontSize: 14, color: c.textPrimary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(flex: 2),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                setState(() {
                  _step = 0;
                  _docFrontPath = null;
                  _docBackPath = null;
                  _selfiePath = null;
                  _rejectionReason = null;
                  _docType = '';
                  _scanningBack = false;
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Try Again',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0
                ? 12
                : MediaQuery.of(context).padding.bottom + 24,
          ),
        ],
      ),
    );
  }

  String _docTypeLabel() {
    switch (_docType) {
      case 'license':
        return S.of(context).driversLicense;
      case 'passport':
        return S.of(context).passport;
      case 'government_id':
        return S.of(context).governmentId;
      default:
        return S.of(context).driversLicense;
    }
  }

  Widget _detailRow(AppColors c, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 14, color: c.textTertiary)),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  INLINE DOCUMENT SCANNER
//  Full-screen camera with preview. On "Use Photo" calls onPhotoTaken
//  instead of popping — the parent swaps to next step inline.
// ═══════════════════════════════════════════════════════════════════════════════

class _InlineDocScanner extends StatefulWidget {
  final String docType;
  final bool isBack;
  final int currentPhoto;
  final int totalPhotos;
  final ValueChanged<String> onPhotoTaken;
  final VoidCallback onCancel;

  const _InlineDocScanner({
    required this.docType,
    required this.isBack,
    required this.currentPhoto,
    required this.totalPhotos,
    required this.onPhotoTaken,
    required this.onCancel,
  });

  @override
  State<_InlineDocScanner> createState() => _InlineDocScannerState();
}

class _InlineDocScannerState extends State<_InlineDocScanner>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  CameraController? _ctrl;
  bool _initialized = false;
  String? _capturedPath;
  bool _capturing = false;

  final _textRecognizer = TextRecognizer();
  bool _scanning = false;
  bool _documentDetected = false;
  String _detectedHint = '';
  FlashMode _flashMode = FlashMode.off;
  Timer? _scanTimer;

  late AnimationController _cornerAnim;

  String get _scanTitle {
    if (widget.docType == 'passport') return S.of(context).scanPassport;
    if (widget.docType == 'government_id') return S.of(context).scanId;
    return widget.isBack ? S.of(context).scanBackLicense : S.of(context).scanFrontLicense;
  }

  @override
  void initState() {
    super.initState();
    _cornerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _initCamera();
  }

  @override
  void didUpdateWidget(covariant _InlineDocScanner old) {
    super.didUpdateWidget(old);
    // When switching from front to back, reset capture state
    if (old.isBack != widget.isBack || old.docType != widget.docType) {
      setState(() {
        _capturedPath = null;
        _documentDetected = false;
        _detectedHint = '';
      });
      _scanTimer?.cancel();
      _startDocumentDetection();
    }
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
                  widget.onCancel();
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
        widget.onCancel();
      }
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) widget.onCancel();
      return;
    }
    final rear = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _ctrl = CameraController(rear, ResolutionPreset.high, enableAudio: false);
    try {
      await _ctrl!.initialize().timeout(const Duration(seconds: 5));
      await _ctrl!.setFlashMode(FlashMode.off);
      if (mounted) {
        setState(() => _initialized = true);
        _startDocumentDetection();
      }
    } catch (e) {
      debugPrint('Camera init failed: $e');
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        _ctrl?.dispose();
        _ctrl = CameraController(rear, ResolutionPreset.high, enableAudio: false);
        await _ctrl!.initialize().timeout(const Duration(seconds: 5));
        await _ctrl!.setFlashMode(FlashMode.off);
        if (mounted) {
          setState(() => _initialized = true);
          _startDocumentDetection();
        }
      } catch (_) {
        if (mounted) widget.onCancel();
      }
    }
  }

  void _startDocumentDetection() {
    _scanTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _scanForDocument(),
    );
  }

  Future<void> _toggleFlash() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    await _ctrl!.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  Future<void> _scanForDocument() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing || _scanning ||
        _capturedPath != null || !mounted) {
      return;
    }
    _scanning = true;
    try {
      final xFile = await _ctrl!.takePicture();
      final inputImage = InputImage.fromFilePath(xFile.path);
      final result = await _textRecognizer.processImage(inputImage);
      final text = result.text.toLowerCase();
      final hasDocText =
          text.contains('license') || text.contains('driver') ||
          text.contains('dob') || text.contains('exp') ||
          text.contains('class') || text.contains('state') ||
          text.contains('name') || text.contains('address') ||
          text.contains('dl') || text.contains('iss') ||
          text.contains('passport') || text.contains('nationality') ||
          text.contains('birth') || text.contains('gobierno') ||
          text.contains('licencia') || result.blocks.length >= 3;
      if (mounted && _capturedPath == null) {
        setState(() => _documentDetected = hasDocText);
      }
      try { File(xFile.path).deleteSync(); } catch (_) {}
    } catch (e) {
      debugPrint('Doc-scan error: $e');
    }
    _scanning = false;
  }

  @override
  void dispose() {
    _cornerAnim.dispose();
    _textRecognizer.close();
    _ctrl?.dispose();
    _scanTimer?.cancel();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    _scanTimer?.cancel();
    while (_scanning) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    setState(() => _capturing = true);
    HapticFeedback.mediumImpact();
    try {
      final xFile = await _ctrl!.takePicture();
      final inputImage = InputImage.fromFilePath(xFile.path);
      final result = await _textRecognizer.processImage(inputImage);
      final text = result.text.toLowerCase();
      final isDoc =
          text.contains('license') || text.contains('driver') ||
          text.contains('dob') || text.contains('exp') ||
          text.contains('class') || text.contains('state') ||
          text.contains('name') || text.contains('address') ||
          text.contains('dl') || text.contains('iss') ||
          result.blocks.length >= 3;

      if (isDoc) {
        if (mounted) {
          setState(() {
            _capturedPath = xFile.path;
            _documentDetected = true;
            _detectedHint = '';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _capturedPath = xFile.path;
            _documentDetected = false;
            _detectedHint = S.of(context).noDocumentDetected;
          });
        }
      }
    } catch (_) {
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
      _detectedHint = '';
    });
    _scanTimer?.cancel();
    _startDocumentDetection();
  }

  void _usePhoto() {
    if (_capturedPath == null) return;
    widget.onPhotoTaken(_capturedPath!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1F),
      body: _capturedPath != null ? _buildPreview() : _buildScanner(),
    );
  }

  // ── Preview captured photo ──
  Widget _buildPreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(_capturedPath!), fit: BoxFit.cover),
        Container(color: Colors.black.withValues(alpha: 0.4)),
        // Top bar — X always top-left, no title after capture
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: GestureDetector(
                onTap: _retake,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 22),
                ),
              ),
            ),
          ),
        ),
        // Bottom buttons + step counter
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
                  if (!_documentDetected && _detectedHint.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade900.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _detectedHint,
                              style: const TextStyle(
                                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500,
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: Text(
                        S.of(context).usePhoto,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        S.of(context).retake,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Step counter
                  Text(
                    '${widget.currentPhoto} of ${widget.totalPhotos}',
                    style: TextStyle(
                      color: _gold,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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

  // ── Live camera scanner ──
  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
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
          const Center(child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5)),

        if (_initialized) _buildOverlay(context),

        // Top bar — X top-left, title centered
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
                    onTap: widget.onCancel,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _scanTitle,
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
                        color: _flashMode == FlashMode.off ? Colors.white : _gold,
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

        // Shutter button
        Positioned(
          bottom: 56,
          left: 0,
          right: 0,
          child: Column(
            children: [
              Center(
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
                          color: (_documentDetected ? const Color(0xFF4CAF50) : _gold)
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
                        : const Icon(Icons.camera_alt_rounded, color: Colors.black, size: 32),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Step counter below shutter
              Text(
                '${widget.currentPhoto} of ${widget.totalPhotos}',
                style: TextStyle(
                  color: _gold.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final frameW = size.width * 0.82;
    final frameH = frameW * 0.63;
    final frameLeft = (size.width - frameW) / 2;
    final frameTop = (size.height - frameH) / 2 - 30;

    return AnimatedBuilder(
      animation: _cornerAnim,
      builder: (_, __) {
        final glow = _cornerAnim.value;
        return Stack(
          children: [
            Positioned(top: 0, left: 0, right: 0, height: frameTop,
              child: Container(color: Colors.black.withValues(alpha: 0.62))),
            Positioned(top: frameTop + frameH, left: 0, right: 0, bottom: 0,
              child: Container(color: Colors.black.withValues(alpha: 0.62))),
            Positioned(top: frameTop, left: 0, width: frameLeft, height: frameH,
              child: Container(color: Colors.black.withValues(alpha: 0.62))),
            Positioned(top: frameTop, left: frameLeft + frameW, right: 0, height: frameH,
              child: Container(color: Colors.black.withValues(alpha: 0.62))),
            Positioned(
              top: frameTop, left: frameLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: frameW, height: frameH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _documentDetected
                        ? const Color(0xFF4CAF50).withValues(alpha: 0.7 + 0.3 * glow)
                        : _gold.withValues(alpha: 0.5 + 0.5 * glow),
                    width: _documentDetected ? 3 : 2,
                  ),
                ),
              ),
            ),
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
      Positioned(top: t, left: l, child: _corner(color, len, thick, true, true)),
      Positioned(top: t, left: l + w - len, child: _corner(color, len, thick, false, true)),
      Positioned(top: t + h - len, left: l, child: _corner(color, len, thick, true, false)),
      Positioned(top: t + h - len, left: l + w - len, child: _corner(color, len, thick, false, false)),
    ];
  }

  Widget _corner(Color c, double len, double thick, bool left, bool top) {
    return SizedBox(
      width: len, height: len,
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
