import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../config/app_theme.dart';
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
  bool _processing = false;
  bool _verified = false;
  String? _rejectionReason;
  Timer? _pollTimer;

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
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulseCtrl.dispose();
    _checkCtrl.dispose();
    super.dispose();
  }

  /// Launch license scanner (front → back) → submit verification.
  Future<void> _startVerification() async {
    // Step 1: Scan front of license
    final frontPath = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => const LicenseScannerScreen(side: 'Front'),
      ),
    );
    if (frontPath == null || !mounted) return;

    setState(() => _licenseFrontPath = frontPath);

    // Brief delay to let the camera fully release before reinitializing
    await Future.delayed(const Duration(milliseconds: 600));

    // Step 2: Scan back of license
    final backPath = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => const LicenseScannerScreen(side: 'Back'),
      ),
    );
    if (backPath == null || !mounted) return;

    setState(() {
      _licenseBackPath = backPath;
      _step = 1; // Processing / submitting
      _processing = true;
    });
    await _completeVerification();
  }

  Future<void> _completeVerification() async {
    final Map<String, dynamic> body = {'id_document_type': 'license'};

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

    // Start polling for dispatch decision
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    int _pollAttempts = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      _pollAttempts++;
      try {
        final result = await ApiService.getVerificationStatus();
        final status = result['verification_status'] as String? ?? 'pending';
        if (!mounted) return;

        if (status == 'approved') {
          _pollTimer?.cancel();
          await LocalDataService.setIdentityVerified('license');
          await UserSession.updateField('isVerified', 'true');
          await UserSession.updateField('verificationStatus', 'approved');
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
        } else if (_pollAttempts >= 120) {
          // Stop after ~10 minutes
          _pollTimer?.cancel();
        }
      } catch (e) {
        debugPrint('⚠️ Verification poll failed: $e');
        if (_pollAttempts >= 120) _pollTimer?.cancel();
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
          // Back button
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
            S.of(context).scanLicenseFront,
          ),
          const SizedBox(height: 12),
          _stepPreview(c, Icons.flip_rounded, S.of(context).scanLicenseBack),
          const SizedBox(height: 12),
          _stepPreview(
            c,
            Icons.check_circle_outline_rounded,
            'Quick dispatch review',
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
              child: Text(
                S.of(context).startVerification,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your documents are encrypted and securely stored',
            style: TextStyle(fontSize: 12, color: c.textTertiary),
          ),
          const SizedBox(height: 24),
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
    return FutureBuilder<Map<String, String>?>(
      future: UserSession.getUser(),
      builder: (context, snap) {
        final user = snap.data;
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
                builder: (_, _) {
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
                    _detailRow(c, 'Document', "Driver's License"),
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
                  child: const Text(
                    'Continue to Cruise',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
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
            builder: (_, _) {
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
              child: const Text(
                'Try Again',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 24),
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
