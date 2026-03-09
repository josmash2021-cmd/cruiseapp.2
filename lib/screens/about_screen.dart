import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

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
      backgroundColor: c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: c.isDark
                        ? null
                        : Border.all(
                            color: Colors.black.withValues(alpha: 0.06),
                          ),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: c.textPrimary,
                    size: 18,
                  ),
                ),
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
                        color: _gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Center(
                        child: Text(
                          'C',
                          style: TextStyle(
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            color: _gold,
                          ),
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
                          ? S.of(context).versionText(_version, _buildNumber)
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
                onTap: () => _openUrl('https://cruiseride.com/terms'),
              ),
              const SizedBox(height: 10),
              _infoItem(
                c,
                Icons.privacy_tip_outlined,
                S.of(context).privacyPolicy,
                onTap: () => _openUrl('https://cruiseride.com/privacy'),
              ),
              const SizedBox(height: 10),
              _infoItem(
                c,
                Icons.code_rounded,
                S.of(context).openSourceLicenses,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Cruise',
                  applicationVersion: _version,
                ),
              ),
              const SizedBox(height: 10),
              _infoItem(
                c,
                Icons.star_rounded,
                S.of(context).rateApp,
                onTap: () => _rateApp(),
              ),
              const SizedBox(height: 10),
              _infoItem(
                c,
                Icons.share_rounded,
                S.of(context).shareCruise,
                onTap: () => _shareCruise(),
              ),

              const SizedBox(height: 36),

              // ── Credits ──
              Center(
                child: Column(
                  children: [
                    Text(
                      S.of(context).madeWithHeart,
                      style: TextStyle(fontSize: 14, color: c.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      S.of(context).copyright,
                      style: TextStyle(fontSize: 13, color: c.textTertiary),
                    ),
                  ],
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, color: c.textPrimary, size: 22),
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
    if (await canLaunchUrl(uri))
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _rateApp() async {
    // Try Google Play Store first, then fallback
    const playStoreUrl =
        'https://play.google.com/store/apps/details?id=com.cruise_app';
    final uri = Uri.parse(playStoreUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      final sc = AppColors.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Thank you for your support! ⭐'),
          backgroundColor: sc.isDark ? sc.surface : Colors.black87,
        ),
      );
    }
  }

  Future<void> _shareCruise() async {
    const shareUrl = 'https://cruiseride.com/download';
    const shareText =
        'Check out Cruise - the best ride experience! 🚗\n$shareUrl';
    await Clipboard.setData(const ClipboardData(text: shareText));
    if (!mounted) return;
    final sc = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Share link copied to clipboard! 📋'),
        backgroundColor: sc.isDark ? sc.surface : Colors.black87,
      ),
    );
  }
}
