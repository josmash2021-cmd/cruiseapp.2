import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/neu_style.dart';
import 'privacy_policy_screen.dart';

/// Dedicated biometric consent screen (BIPA-style informed written consent).
///
/// Shown ONCE before any facial liveness capture. Pops with `true` when the
/// user explicitly consents (checkbox + Continue), `false`/`null` otherwise.
/// The consent is persisted in SharedPreferences (`biometric_consent_v1`
/// plus `biometric_consent_v1_at` ISO timestamp) so the gate never asks again.
class BiometricConsentScreen extends StatefulWidget {
  const BiometricConsentScreen({super.key});

  static const _gold = Color(0xFFE8C547);

  @override
  State<BiometricConsentScreen> createState() => _BiometricConsentScreenState();
}

class _BiometricConsentScreenState extends State<BiometricConsentScreen> {
  bool _consented = false;
  bool _saving = false;

  Future<void> _continue() async {
    if (!_consented || _saving) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('biometric_consent_v1', true);
      await prefs.setString(
        'biometric_consent_v1_at',
        DateTime.now().toIso8601String(),
      );
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              // ── Header ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(false),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: neuBox(radius: 14, pressed: true),
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Identity Verification',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 24),

              // ── Disclosure card ──
              Container(
                padding: const EdgeInsets.all(20),
                decoration: neuBox(radius: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: const Icon(
                        Icons.verified_user_rounded,
                        color: BiometricConsentScreen._gold,
                        size: 24,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Biometric data consent',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'To verify your identity, the App captures a selfie photo or short sequence to confirm a live person is present ("liveness detection").\n\n'
                      '• The analysis runs on your device using Google ML Kit — it does not leave your phone except for the pass/fail result and the verification images used to complete and audit the verification.\n'
                      '• We do not store facial geometry templates, perform facial recognition searches, or use biometric data for advertising.\n'
                      '• Data is kept only while your verification is valid and destroyed within 90 days after account deletion or verification expiry, unless the law requires longer.\n'
                      '• We never sell biometric data. It is used solely to verify identity and prevent fraud.\n\n'
                      'Declining consent means we cannot complete identity verification (required to ride or drive).',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 13.5,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PrivacyPolicyScreen(),
                          ),
                        );
                      },
                      child: const Text(
                        'Read the full Privacy Policy',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: BiometricConsentScreen._gold,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: BiometricConsentScreen._gold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Explicit consent checkbox ──
              GestureDetector(
                onTap: () => setState(() => _consented = !_consented),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: _consented
                            ? BiometricConsentScreen._gold
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _consented
                              ? BiometricConsentScreen._gold
                              : Colors.white.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: _consented
                          ? const Icon(Icons.check_rounded,
                              color: Colors.black, size: 18)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'I consent to the collection and use of my biometric data for identity verification as described.',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),

              // ── Actions ──
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _consented && !_saving ? _continue : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BiometricConsentScreen._gold,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor:
                        Colors.white.withValues(alpha: 0.08),
                    disabledForegroundColor:
                        Colors.white.withValues(alpha: 0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'Not now',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
