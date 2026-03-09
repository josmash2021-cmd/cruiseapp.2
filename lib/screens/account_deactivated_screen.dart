import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';

class AccountDeactivatedScreen extends StatelessWidget {
  const AccountDeactivatedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.error.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.pause_circle_filled_rounded,
                  size: 56,
                  color: c.error,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                s.accountDeactivated,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                s.accountDeactivatedMsg,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 15,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 3),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () async {
                    await UserSession.logout();
                    if (!context.mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                      (_) => false,
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: c.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    s.logOut,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
