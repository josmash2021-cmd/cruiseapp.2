import '../utils/app_platform.dart';
import '../config/page_transitions.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  static const _gold = Color(0xFFE8C547);

  String _version = '';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _buildNumber = info.buildNumber;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _version = '1.0.0';
        _buildNumber = '1';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: neuBox(radius: 14, pressed: true),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: c.textPrimary,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    S.of(context).aboutTitle,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 36),

              // ── Logo ──
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [_gold, const Color(0xFFF5D990)],
                        ),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Image.asset(
                          'assets/images/logoapp.png',
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Cruise',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _version.isNotEmpty
                          ? 'Version $_version'
                          : S.of(context).loading,
                      style: TextStyle(fontSize: 14, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),

              // ── Info items ──
              _infoItem(
                c,
                Icons.description_outlined,
                S.of(context).termsOfService,
                onTap: () => Navigator.of(context).push(
                  slideFromRightRoute(const TermsOfServiceScreen()),
                ),
              ),
              const SizedBox(height: 10),
              _infoItem(
                c,
                Icons.privacy_tip_outlined,
                S.of(context).privacyPolicy,
                onTap: () => Navigator.of(context).push(
                  slideFromRightRoute(const PrivacyPolicyScreen()),
                ),
              ),
              const SizedBox(height: 10),
              // Rate + Share side by side
              Row(
                children: [
                  Expanded(
                    child: _infoItem(
                      c,
                      Icons.star_rounded,
                      S.of(context).rateApp,
                      onTap: () => _rateApp(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _infoItem(
                      c,
                      Icons.share_rounded,
                      S.of(context).shareCruise,
                      onTap: () => _shareCruise(),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 36),

              // ── Credits ──
              Center(
                child: Text(
                  S.of(context).copyright,
                  style: TextStyle(fontSize: 13, color: c.textTertiary),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoItem(
    AppColors c,
    IconData icon,
    String label, {
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: neuBox(radius: 18),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // App Store review link — opens the write-review form directly.
  static const String _kAppStoreReviewUrl =
      'https://apps.apple.com/app/id6760517086?action=write-review';
  static const String _kAppStoreUrl =
      'https://apps.apple.com/app/id6760517086';
  // Google Play link — PENDING: replace once the Play Store listing is live.
  static const String _kPlayStoreUrl = '';

  Future<void> _rateApp() async {
    if (!AppPlatform.isIOS) {
      // Play Store link is still pending — show a friendly notice instead
      // of opening a dead URL. Once _kPlayStoreUrl is set, it opens instead.
      if (_kPlayStoreUrl.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).comingSoon)),
        );
        return;
      }
      final playUri = Uri.parse(_kPlayStoreUrl);
      if (await canLaunchUrl(playUri)) {
        await launchUrl(playUri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    final uri = Uri.parse(_kAppStoreReviewUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _shareCruise() async {
    final storeUrl = AppPlatform.isIOS
        ? _kAppStoreUrl
        : 'https://cruiseinride.com';
    final text = S.of(context).shareAppText.replaceAll(
      'https://cruiseride.com/download',
      storeUrl,
    );
    await Share.share(text);
  }
}
