import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/sms_service.dart';
import '../services/user_session.dart';
import 'home_screen.dart';

/// Verification-code screen shown during Login (not registration).
///
/// After the code is verified, exchanges the [loginToken] for a full JWT
/// and navigates to [HomeScreen].
class LoginVerifyScreen extends StatefulWidget {
  final String loginToken;
  final String contact; // email or phone
  final bool useVerifyApi; // true = Twilio, false = EmailJS
  final String expectedCode; // only used when useVerifyApi == false

  const LoginVerifyScreen({
    super.key,
    required this.loginToken,
    required this.contact,
    required this.useVerifyApi,
    this.expectedCode = '',
  });

  @override
  State<LoginVerifyScreen> createState() => _LoginVerifyScreenState();
}

class _LoginVerifyScreenState extends State<LoginVerifyScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  bool _canSubmit = false;
  String? _errorText;
  bool _verifying = false;

  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;

  @override
  void initState() {
    super.initState();
    _codeCtrl.addListener(_onCodeChanged);

    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnim = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticIn));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _codeFocus.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final ok = _codeCtrl.text.trim().length == 6;
    if (ok != _canSubmit || _errorText != null) {
      setState(() {
        _canSubmit = ok;
        _errorText = null;
      });
    }
  }

  Future<void> _verify() async {
    if (_verifying) return;
    final code = _codeCtrl.text.trim();
    if (code.length != 6) return;

    setState(() => _verifying = true);

    bool isValid;

    if (widget.useVerifyApi) {
      // Phone — verify via Twilio Verify API
      isValid = await SmsService.checkVerificationCode(
        toPhone: widget.contact,
        code: code,
      );
    } else {
      // Email — local code comparison
      await Future.delayed(const Duration(milliseconds: 500));
      isValid = code == widget.expectedCode;
    }

    if (!mounted) return;

    if (!isValid) {
      setState(() {
        _errorText = 'Invalid code';
        _verifying = false;
      });
      _shakeCtrl.forward(from: 0);
      HapticFeedback.mediumImpact();
      return;
    }

    // Code correct — exchange login_token for full JWT
    try {
      final result = await ApiService.completeLogin(
        loginToken: widget.loginToken,
      );

      if (!mounted) return;

      // Cache user data locally — preserve existing photo if available
      final user = result['user'] as Map<String, dynamic>;
      final existingUser = await UserSession.getUser();
      String existingPhoto = existingUser?['photoPath'] ?? '';
      // Fallback: check persistent photo (survives logout)
      if (existingPhoto.isEmpty) {
        existingPhoto = await UserSession.getPersistedPhotoPath();
      }
      // Fallback: download photo from server (works across devices)
      if (existingPhoto.isEmpty || !await File(existingPhoto).exists()) {
        final serverPhotoUrl = user['photo_url'] as String?;
        if (serverPhotoUrl != null && serverPhotoUrl.isNotEmpty) {
          final downloaded = await ApiService.downloadPhoto(serverPhotoUrl);
          if (downloaded.isNotEmpty) {
            existingPhoto = downloaded;
          }
        }
      }
      // Validate that this account is a rider
      final backendRole = user['role'] as String? ?? 'rider';
      if (backendRole == 'driver') {
        setState(() {
          _errorText = S.of(context).driverAccountError;
          _verifying = false;
        });
        return;
      }

      await UserSession.saveUser(
        firstName: user['first_name'] ?? '',
        lastName: user['last_name'] ?? '',
        email: user['email'] ?? '',
        phone: user['phone'] ?? '',
        photoPath: existingPhoto.isNotEmpty ? existingPhoto : null,
        userId: user['id'] as int?,
        role: 'rider',
      );
      await UserSession.saveMode('rider');
      await UserSession.initPhotoNotifier();

      // Restore verification status from backend
      final vStatus = user['verification_status'] as String?;
      if (vStatus == 'approved') {
        final docType = user['id_document_type'] as String? ?? 'id_card';
        await LocalDataService.setIdentityVerified(docType);
      }

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        smoothFadeRoute(const HomeScreen(), durationMs: 600),
        (_) => false,
      );
    } on ApiException catch (e) {
      setState(() {
        _errorText = e.message;
        _verifying = false;
      });
    } catch (_) {
      setState(() {
        _errorText = S.of(context).connectionError;
        _verifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: c.textPrimary,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Title ──
              Text(
                widget.useVerifyApi
                    ? S.of(context).codeSentCheckPhone
                    : S.of(context).codeSentCheckEmail,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                S.of(context).enterCodeSentTo(widget.contact),
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Code input ──
              AnimatedBuilder(
                animation: _shakeCtrl,
                builder: (context, child) {
                  final dx = _shakeCtrl.isAnimating
                      ? sin(_shakeAnim.value * 3 * pi) * 8
                      : 0.0;
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _errorText != null
                          ? Colors.white.withValues(alpha: 0.6)
                          : _canSubmit
                          ? _gold
                          : c.border,
                      width: _errorText != null || _canSubmit ? 1.8 : 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextField(
                    controller: _codeCtrl,
                    focusNode: _codeFocus,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 8,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      hintText: '6-digit code',
                      hintStyle: TextStyle(
                        color: c.textTertiary,
                        fontSize: 16,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                  ),
                ),
              ),

              // ── Error ──
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _errorText != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.6),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _errorText!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              const Spacer(),

              // ── Verify button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      gradient: _canSubmit
                          ? const LinearGradient(colors: [_gold, _goldLight])
                          : null,
                      color: _canSubmit ? null : c.surface,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: _canSubmit
                            ? const Color(0xFF1A1400)
                            : c.textTertiary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onPressed: _canSubmit ? _verify : null,
                      child: _verifying
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: _canSubmit
                                    ? const Color(0xFF1A1400)
                                    : c.textTertiary,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              S.of(context).verifyAndSignIn,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
