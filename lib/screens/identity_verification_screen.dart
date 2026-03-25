import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';
import 'driver/license_scanner_screen.dart';

/// Rider identity verification flow:
///  Step 0 — Intro: "Verify Your Identity"
///  (launches LicenseScannerScreen → FaceLivenessScreen automatically)
///  Step 1 — Processing / submitting
///  Step 2 — Confirmed
///  Step 3 — Pending dispatch review
///  Step 4 — Rejected
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

  int _step = 0; // 0=intro, 1=processing, 2=confirmed, 3=pending, 4=rejected
  String? _licenseFrontPath;
  String? _licenseBackPath;
  String? _selfiePath;
  final String _docType = 'license';
  bool _processing = false;
  bool _verified = false;
  String? _rejectionReason;
  Timer? _pollTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _firestoreSubscription;
  Map<String, String>? _cachedUser;

  late AnimationController _pulseCtrl;
  late AnimationController _checkCtrl;

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

  /// Scan license front, license back, then capture selfie.
  Future<void> _startVerification() async {
    // Scan license front
    final frontPath = await Navigator.of(context).push<String?>(
      slideFromRightRoute(const LicenseScannerScreen(side: 'Front')),
    );
    if (frontPath == null || !mounted) return;
    _licenseFrontPath = frontPath;

    // Scan license back
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final backPath = await Navigator.of(context).push<String?>(
      slideFromRightRoute(const LicenseScannerScreen(side: 'Back')),
    );
    if (backPath == null || !mounted) return;
    _licenseBackPath = backPath;

    // Capture selfie (becomes profile photo)
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final selfiePath = await _captureSelfie();
    if (selfiePath == null || !mounted) return;
    _selfiePath = selfiePath;

    setState(() {
      _step = 1;
      _processing = true;
    });
    await _completeVerification();
  }

  /// Launch front camera to capture a selfie for the profile photo.
  Future<String?> _captureSelfie() async {
    // Show guide sheet before opening camera
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SelfieGuideSheet(),
    );
    if (proceed != true || !mounted) return null;
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 85,
      );
      return xFile?.path;
    } catch (e) {
      debugPrint('⚠️ Selfie capture failed: $e');
      return null;
    }
  }

  Future<void> _completeVerification() async {
    final Map<String, dynamic> body = {
      'id_document_type': _docType,
      'role': 'rider',
    };

    // Encode license front
    if (_licenseFrontPath != null) {
      try {
        final bytes = await File(_licenseFrontPath!).readAsBytes();
        body['license_front'] = base64Encode(bytes);
      } catch (e) {
        debugPrint('⚠️ Failed to read license front: $e');
      }
    }

    // Encode license back
    if (_licenseBackPath != null) {
      try {
        final bytes = await File(_licenseBackPath!).readAsBytes();
        body['license_back'] = base64Encode(bytes);
      } catch (e) {
        debugPrint('⚠️ Failed to read license back: $e');
      }
    }

    // Encode selfie — also sent as profile_photo so backend sets profilePhotoUrl
    if (_selfiePath != null) {
      try {
        final bytes = await File(_selfiePath!).readAsBytes();
        final encoded = base64Encode(bytes);
        body['selfie'] = encoded;
        body['profile_photo'] = encoded;
      } catch (e) {
        debugPrint('⚠️ Failed to read selfie: $e');
      }
    }

    // Save selfie locally as profile photo immediately (before approval)
    if (_selfiePath != null) {
      await UserSession.updateField('photo', _selfiePath!);
    }

    // Submit verification request to backend for dispatch review
    try {
      await ApiService.submitVerification(body);
    } catch (e) {
      debugPrint('⚠️ Verification submission failed: $e');
    }

    // Update local state to pending
    await UserSession.updateField('verificationStatus', 'pending');
    await UserSession.updateField('idDocumentType', 'license');

    if (!mounted) return;
    setState(() {
      _processing = false;
      _step = 3; // Pending review
    });

    // Start polling for dispatch decision + attach Firestore real-time listener
    _startPolling();
    _attachFirestoreListener();
  }

  /// Firestore real-time listener — queries by userId field, fires instantly
  /// when Dispatch approves/rejects regardless of the document ID format.
  /// Ensures Firebase Auth is available first (Firestore rules require auth).
  void _attachFirestoreListener() async {
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (e) {
      debugPrint('[IdentityVerification] Firebase Auth failed: $e');
      return; // polling still covers this case
    }

    final user = await UserSession.getUser();
    final userId = user?['userId'];
    if (userId == null || userId.isEmpty || !mounted) return;
    final userIdInt = int.tryParse(userId) ?? 0;
    if (userIdInt <= 0) return;

    _firestoreSubscription = FirebaseFirestore.instance
        .collection('verifications')
        .where('userId', isEqualTo: userIdInt)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final status = data['status'] as String? ??
            data['verificationStatus'] as String? ??
            '';
        final isApproved = status == 'approved' ||
            data['isVerified'] == true ||
            data['isApproved'] == true;
        if (isApproved && !_verified) {
          _pollTimer?.cancel();
          LocalDataService.setIdentityVerified('license');
          UserSession.updateField('isVerified', 'true');
          UserSession.updateField('verificationStatus', 'approved');
          // Update profile photo from Firestore (backend-hosted URL)
          final photoUrl = data['profilePhotoUrl'] as String? ??
              data['selfieUrl'] as String?;
          if (photoUrl != null && photoUrl.isNotEmpty) {
            UserSession.updateField('photo', photoUrl);
          }
          _checkCtrl.forward();
          setState(() {
            _verified = true;
            _step = 2;
          });
          return;
        } else if (status == 'rejected' && _step != 4) {
          _pollTimer?.cancel();
          final reason = data['reason'] as String? ??
              data['verificationReason'] as String? ??
              'Verification was not approved';
          UserSession.updateField('verificationStatus', 'rejected');
          setState(() {
            _rejectionReason = reason;
            _step = 4;
          });
          return;
        }
      }
    }, onError: (e) {
      debugPrint('[IdentityVerification] Firestore listener error: $e');
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    int pollAttempts = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      pollAttempts++;
      try {
        final result = await ApiService.getVerificationStatus();
        final status = result['verification_status'] as String? ?? 'pending';
        if (!mounted) return;

        if (status == 'approved') {
          _pollTimer?.cancel();
          await LocalDataService.setIdentityVerified('license');
          await UserSession.updateField('isVerified', 'true');
          await UserSession.updateField('verificationStatus', 'approved');
          // Update profile photo from polling response
          final photoUrl = result['profile_photo_url'] as String? ??
              result['selfie_url'] as String?;
          if (photoUrl != null && photoUrl.isNotEmpty) {
            await UserSession.updateField('photo', photoUrl);
          }
          if (!mounted) return;
          _checkCtrl.forward();
          setState(() {
            _verified = true;
            _step = 2; // Confirmed
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
            _step = 4; // Rejected
          });
        } else if (pollAttempts >= 120) {
          // Stop after ~10 minutes
          _pollTimer?.cancel();
        }
      } catch (e) {
        debugPrint('⚠️ Verification poll failed: $e');
        if (pollAttempts >= 120) _pollTimer?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          switchInCurve: Curves.easeOutCubic,
          child: _buildStep(c),
        ),
      ),
    );
  }

  Widget _buildStep(AppColors c) {
    switch (_step) {
      case 0:
        return _buildIntro(c);
      case 1:
        return _buildProcessing(c);
      case 2:
        return _buildConfirmed(c);
      case 3:
        return _buildPendingReview(c);
      case 4:
        return _buildRejected(c);
      default:
        return _buildIntro(c);
    }
  }

  // ═══════════════════════════════════════════
  //  Step 0 — Intro
  // ═══════════════════════════════════════════
  Widget _buildIntro(AppColors c) {
    return Padding(
      key: const ValueKey(0),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Close button
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Icon(
                  Icons.close_rounded,
                  color: c.textPrimary,
                  size: 28,
                ),
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
            child: const Icon(
              Icons.verified_user_rounded,
              color: Colors.black,
              size: 48,
            ),
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
          const SizedBox(height: 16),
          Text(
            S.of(context).verifyIdentitySubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: c.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 40),
          // Steps preview
          _stepPreview(
            c,
            Icons.credit_card_rounded,
            'License — Front side',
          ),
          const SizedBox(height: 12),
          _stepPreview(
            c,
            Icons.flip_rounded,
            'License — Back side',
          ),
          const SizedBox(height: 12),
          _stepPreview(
            c,
            Icons.face_rounded,
            'Selfie — becomes your profile photo',
          ),
          const SizedBox(height: 12),
          _stepPreview(
            c,
            Icons.check_circle_outline_rounded,
            S.of(context).quickDispatchReview,
          ),
          const Spacer(flex: 3),
          // CTA
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _startVerification,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  S.of(context).startVerification,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 ? 8 : 16),
          Text(
            S.of(context).documentsEncrypted,
            style: TextStyle(fontSize: 12, color: c.textTertiary),
          ),
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 
              ? 12 
              : MediaQuery.of(context).padding.bottom + 24),
        ],
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
  //  Step 1 — Processing (submitting to backend)
  // ═══════════════════════════════════════════
  Widget _buildProcessing(AppColors c) {
    return Center(
      key: const ValueKey(1),
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
              child: const CircularProgressIndicator(
                color: _gold,
                strokeWidth: 3,
              ),
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
  //  Step 2 — Confirmed
  // ═══════════════════════════════════════════
  Widget _buildConfirmed(AppColors c) {
    final user = _cachedUser;
    final firstName = user?['firstName'] ?? '';
    final lastName = user?['lastName'] ?? '';
    final email = user?['email'] ?? '';
    final phone = user?['phone'] ?? '';

    return Padding(
          key: const ValueKey(2),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),
              // Animated check
              AnimatedBuilder(
                animation: _checkCtrl,
                builder: (_, __) {
                  return Transform.scale(
                    scale: Curves.elasticOut.transform(
                      _checkCtrl.value.clamp(0.0, 1.0),
                    ),
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFE8C547), Color(0xFFB8972E)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFFE8C547,
                            ).withValues(alpha: 0.3),
                            blurRadius: 30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 52,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              Text(
                'Identity Verified!',
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
                style: TextStyle(
                  fontSize: 16,
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              // Verification details card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    // Header
                    Row(
                      children: [
                        const Icon(
                          Icons.verified_rounded,
                          color: Color(0xFFE8C547),
                          size: 22,
                        ),
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
                    _detailRow(
                      c,
                      'Document',
                      _docType == 'license'
                          ? S.of(context).driversLicense
                          : (_docType == 'passport'
                                ? S.of(context).passport
                                : S.of(context).governmentId),
                    ),
                    const SizedBox(height: 10),
                    _detailRow(c, 'Status', 'Verified ✓'),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: const Text(
                      'Continue to Cruise',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 
                  ? 12 
                  : MediaQuery.of(context).padding.bottom + 24),
            ],
          ),
        );
  }

  // ═══════════════════════════════════════════
  //  Step 3 — Pending Dispatch Review
  // ═══════════════════════════════════════════
  Widget _buildPendingReview(AppColors c) {
    return Padding(
      key: const ValueKey(3),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 60),
          const Spacer(),
          // Animated clock icon
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
          // Pulsing indicator
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3, color: _gold),
          ),
          const Spacer(),
          Text(
            'You\'ll be notified when the review is complete',
            style: TextStyle(fontSize: 13, color: c.textTertiary),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════
  //  Step 4 — Rejected
  // ═══════════════════════════════════════════
  Widget _buildRejected(AppColors c) {
    return Padding(
      key: const ValueKey(4),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
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
                child: Icon(
                  Icons.close_rounded,
                  color: c.textPrimary,
                  size: 20,
                ),
              ),
            ),
          ),
          const Spacer(),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red.withValues(alpha: 0.1),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              size: 50,
              color: Colors.red,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Verification Not Approved',
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
                const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _rejectionReason ??
                        'Your verification was not approved. Please try again.',
                    style: TextStyle(
                      fontSize: 14,
                      color: c.textPrimary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: () {
                // Reset and go back to intro
                setState(() {
                  _step = 0;
                  _licenseFrontPath = null;
                  _licenseBackPath = null;
                  _selfiePath = null;
                  _rejectionReason = null;
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: const Text(
                  'Try Again',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 
              ? 12 
              : MediaQuery.of(context).padding.bottom + 24),
        ],
      ),
    );
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
              color: value.contains('✓')
                  ? const Color(0xFF4CAF50)
                  : c.textPrimary,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════
//  Selfie Guide Bottom Sheet
// ═══════════════════════════════════════════
class _SelfieGuideSheet extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);
  const _SelfieGuideSheet();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textC = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gold.withValues(alpha: 0.12),
                ),
                child: const Icon(Icons.face_rounded, color: _gold, size: 40),
              ),
              const SizedBox(height: 20),
              Text(
                'Take a Selfie',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: textC,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This photo will be your profile picture.\nLook straight at the camera with good lighting.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: sub, height: 1.5),
              ),
              const SizedBox(height: 24),
              // Tips
              _tip(isDark, Icons.light_mode_rounded, 'Good, even lighting on your face'),
              const SizedBox(height: 10),
              _tip(isDark, Icons.remove_red_eye_rounded, 'Eyes open, face fully visible'),
              const SizedBox(height: 10),
              _tip(isDark, Icons.no_photography_rounded, 'No sunglasses or hats'),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.camera_alt_rounded, size: 20),
                  label: const Text(
                    'Open Camera',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tip(bool isDark, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _gold),
        const SizedBox(width: 10),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      ],
    );
  }
}
