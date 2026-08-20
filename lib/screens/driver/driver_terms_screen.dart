import 'dart:io';

import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../services/analytics_service.dart';
import '../../l10n/app_localizations.dart';

/// Cruiseinride Driver Terms of Service (Cruise in Ride LLC / Florida) with
/// its own dedicated acceptance — separate from the FCRA background check
/// disclosure and the Independent Contractor Agreement.
///
/// The document is served by the backend
/// (`GET /legal/driver-terms-of-service`) and acceptance is logged via
/// `POST /auth/consent` with consent_type `driver_terms_of_service`.
/// Everything network-related is lazy (fetched on view/accept/history)
/// so the screen builds without touching the network.
class DriverTermsScreen extends StatefulWidget {
  const DriverTermsScreen({super.key});

  @override
  State<DriverTermsScreen> createState() => _DriverTermsScreenState();
}

class _DriverTermsScreenState extends State<DriverTermsScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);

  bool _consentChecked = false;
  bool _submitting = false;
  bool _loadingDoc = false;

  /// Cached terms document ({document_id, version, content_hash,
  /// content_markdown}) — fetched lazily on first view or on accept.
  Map<String, dynamic>? _terms;

  String _deviceInfo() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade400,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Fetch and display the Driver Terms of Service in a scrollable dialog.
  Future<void> _showTerms() async {
    setState(() => _loadingDoc = true);
    try {
      _terms ??= await ApiService.fetchDriverTermsOfService();
      if (!mounted) return;
      final content = _terms?['content_markdown']?.toString() ?? '';
      final version = _terms?['version']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'Cruiseinride Driver Terms of Service',
                        style: TextStyle(
                          color: _gold,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                if (version.isNotEmpty)
                  Text(
                    'Version $version',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      content.isEmpty ? 'Document unavailable.' : content,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _showError(S.of(context).errorWithMessage(e.toString()));
    } finally {
      if (mounted) setState(() => _loadingDoc = false);
    }
  }

  /// Show past acceptances of the Driver Terms of Service.
  Future<void> _showConsentHistory() async {
    try {
      final items = await ApiService.fetchConsentHistory();
      final history = items
          .where((i) => i['consent_type'] == 'driver_terms_of_service')
          .toList();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text(
            'Acceptance history',
            style: TextStyle(
              color: _gold,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: history.isEmpty
              ? Text(
                  'No records yet.',
                  style:
                      TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final item = history[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_rounded,
                            color: _gold, size: 18),
                        title: Text(
                          '${item['action'] ?? ''} · v${item['version'] ?? ''}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          item['created_at']?.toString() ?? '',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError(S.of(context).errorWithMessage(e.toString()));
    }
  }

  Future<void> _accept() async {
    if (!_consentChecked) return;

    setState(() => _submitting = true);
    try {
      // Fetch the exact document version/hash being accepted, then log the
      // acceptance BEFORE returning. If consent logging fails, do NOT
      // proceed — the driver has not validly accepted the terms.
      _terms ??= await ApiService.fetchDriverTermsOfService();
      final doc = _terms!;
      await ApiService.recordDriverTermsConsent(
        version: doc['version']?.toString() ?? '',
        contentHash: doc['content_hash']?.toString() ?? '',
        deviceInfo: _deviceInfo(),
      );
      AnalyticsService.instance.logEvent('driver_terms_of_service_accepted');
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showError(S.of(context).errorWithMessage(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _surface,
        foregroundColor: Colors.white,
        title: const Text('Driver Terms of Service'),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Info card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _gold.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.gavel_rounded, color: _gold, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Cruise in Ride LLC · Florida. These terms govern your use of the Cruiseinride platform as a driver.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Document — must be reviewable before consent.
              Container(
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: InkWell(
                  onTap: _loadingDoc ? null : _showTerms,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    child: Row(
                      children: [
                        const Icon(Icons.description_rounded,
                            color: _gold, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'View Cruiseinride Driver Terms of Service',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_loadingDoc)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: _gold,
                              strokeWidth: 2,
                            ),
                          )
                        else
                          Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white.withValues(alpha: 0.3),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Consent checkbox — dedicated solely to the Driver Terms of
              // Service (separate from the FCRA disclosure and the ICA).
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _consentChecked
                        ? _gold.withValues(alpha: 0.4)
                        : Colors.white12,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _consentChecked,
                      onChanged: (v) =>
                          setState(() => _consentChecked = v ?? false),
                      activeColor: _gold,
                      checkColor: Colors.black,
                      side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.4)),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'I have read and agree to the Cruiseinride Driver Terms of Service.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // Accept button — disabled until the checkbox is checked.
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed:
                      (_submitting || !_consentChecked) ? null : _accept,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.black,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 22),
                  label: Text(
                    _submitting
                        ? 'Submitting...'
                        : 'Accept Driver Terms of Service',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: _gold.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Consent history affordance
              Center(
                child: TextButton.icon(
                  onPressed: _showConsentHistory,
                  icon: const Icon(Icons.history_rounded,
                      size: 16, color: Colors.white38),
                  label: Text(
                    'Acceptance history',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
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
