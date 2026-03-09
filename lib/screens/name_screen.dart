import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import 'email_collect_screen.dart';

class NameScreen extends StatefulWidget {
  final String registeredWith; // email or phone used to register
  final bool registeredWithEmail;

  const NameScreen({
    super.key,
    required this.registeredWith,
    required this.registeredWithEmail,
  });

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _firstCtrl = TextEditingController();
  final _lastCtrl = TextEditingController();
  bool _canContinue = false;

  @override
  void initState() {
    super.initState();
    _firstCtrl.addListener(_onChanged);
    _lastCtrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    final ok =
        _firstCtrl.text.trim().isNotEmpty && _lastCtrl.text.trim().isNotEmpty;
    if (ok != _canContinue) setState(() => _canContinue = ok);
  }

  void _next() {
    if (!_canContinue) return;
    final first = _firstCtrl.text.trim();
    final last = _lastCtrl.text.trim();
    Navigator.of(context).push(
      slideFromRightRoute(
        EmailCollectScreen(
          firstName: first,
          lastName: last,
          registeredWith: widget.registeredWith,
          registeredWithEmail: widget.registeredWithEmail,
        ),
      ),
    );
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

              // ── Back button ──
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
                S.of(context).whatsYourName,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).driversWillSeeFirstName,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── First Name ──
              _buildField(c, _firstCtrl, S.of(context).firstName),
              const SizedBox(height: 16),

              // ── Last Name ──
              _buildField(c, _lastCtrl, S.of(context).lastName),
              const SizedBox(height: 24),

              // ── Already have an account ──
              Center(
                child: TextButton(
                  onPressed: () {
                    // placeholder — could navigate to login
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    S.of(context).alreadyHaveAccount,
                    style: TextStyle(
                      color: _gold,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // ── Next button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      gradient: _canContinue
                          ? const LinearGradient(colors: [_gold, _goldLight])
                          : null,
                      color: _canContinue ? null : c.surface,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: _canContinue
                            ? const Color(0xFF1A1400)
                            : c.textTertiary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onPressed: _canContinue ? _next : null,
                      child: Text(
                        S.of(context).next,
                        style: TextStyle(
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

  Widget _buildField(AppColors c, TextEditingController ctrl, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: ctrl,
        textCapitalization: TextCapitalization.words,
        style: TextStyle(color: c.textPrimary, fontSize: 16),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
        ),
      ),
    );
  }
}
