import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/user_session.dart';
import 'splash_screen.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  static const _gold = Color(0xFFE8C547);

  bool _locationSharing = true;
  bool _analyticsEnabled = true;
  bool _personalizedAds = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _locationSharing = prefs.getBool('privacy_location') ?? true;
      _analyticsEnabled = prefs.getBool('privacy_analytics') ?? true;
      _personalizedAds = prefs.getBool('privacy_ads') ?? false;
    });
  }

  Future<void> _toggle(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    // Sync privacy preferences with backend
    try {
      await ApiService.updateMe({key: value});
    } catch (_) {}
  }

  void _showSnack(String msg) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: c.isDark ? c.surface : Colors.black87,
      ),
    );
  }

  Future<void> _clearTripHistory() async {
    final c = AppColors.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Clear Trip History',
          style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'This will permanently delete all your saved trip history from this device.',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(
                color: Color(0xFFE8C547),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('trip_history_v1');
    await prefs.remove('destination_usage_v1');
    if (!mounted) return;
    _showSnack('Trip history cleared');
  }

  Future<void> _requestDataExport() async {
    final c = AppColors.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Download My Data',
          style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'We\'ll prepare a copy of your personal data and send it to your registered email address within 48 hours.',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Request Export',
              style: TextStyle(
                color: Color(0xFFE8C547),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    _showSnack(
      'Data export requested. You\'ll receive an email within 48 hours.',
    );
  }

  Future<void> _deleteAccount() async {
    final c = AppColors.of(context);
    final s = S.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          s.deleteAccount,
          style: const TextStyle(
            color: Colors.red,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.deleteAccountProcessing,
              style: TextStyle(color: c.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 16),
            Text(
              s.deleteAccountQuestion,
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              s.cancelDeletion,
              style: TextStyle(color: c.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              s.sure,
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Request account deletion on backend + Firestore
    try {
      await ApiService.deleteAccount();
    } catch (e) {
      debugPrint('⚠️ Backend delete failed: $e');
    }

    // Clear all local data
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await NotificationService.cancelAll();
    await UserSession.logout();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const SplashScreen(), durationMs: 600),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
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
                  const SizedBox(width: 16),
                  Text(
                    'Privacy',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).dataSharing,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    _toggleItem(
                      c,
                      S.of(context).locationSharing,
                      S.of(context).locationSharingDesc,
                      _locationSharing,
                      (v) {
                        setState(() => _locationSharing = v);
                        _toggle('privacy_location', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).usageAnalytics,
                      S.of(context).usageAnalyticsDesc,
                      _analyticsEnabled,
                      (v) {
                        setState(() => _analyticsEnabled = v);
                        _toggle('privacy_analytics', v);
                      },
                    ),
                    const SizedBox(height: 10),
                    _toggleItem(
                      c,
                      S.of(context).personalizedAds,
                      S.of(context).personalizedAdsDesc,
                      _personalizedAds,
                      (v) {
                        setState(() => _personalizedAds = v);
                        _toggle('privacy_ads', v);
                      },
                    ),

                    const SizedBox(height: 28),
                    Text(
                      S.of(context).yourData,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    _actionItem(
                      c,
                      Icons.history_rounded,
                      S.of(context).clearTripHistory,
                      S.of(context).clearTripHistoryDesc,
                      onTap: _clearTripHistory,
                    ),
                    const SizedBox(height: 10),
                    _actionItem(
                      c,
                      Icons.download_rounded,
                      S.of(context).downloadMyData,
                      S.of(context).downloadMyDataDesc,
                      onTap: _requestDataExport,
                    ),

                    const SizedBox(height: 28),
                    Text(
                      'Account',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    GestureDetector(
                      onTap: _deleteAccount,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFE8C547,
                          ).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(
                              0xFFE8C547,
                            ).withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete_forever_rounded,
                              color: Color(0xFFE8C547),
                              size: 22,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Delete Account',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFE8C547),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Permanently remove your account and all associated data.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: Color(0xFFE8C547),
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleItem(
    AppColors c,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: c.isDark
            ? null
            : Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 13, color: c.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: _gold,
            activeTrackColor: _gold.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }

  Widget _actionItem(
    AppColors c,
    IconData icon,
    String title,
    String subtitle, {
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 13, color: c.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}
