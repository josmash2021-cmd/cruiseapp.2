import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// Force-update gate (dispatch-controlled, 2026-10-10).
///
/// Shown as the ONLY route when GET /app-update-status answers
/// update_required=true — no back button, no skip, no way into the app
/// until the user updates from the store. The switch lives in the dispatch
/// panel (Administración → Actualización App) and takes effect without any
/// store release.
///
/// Real-time OFF (user spec): while this page is up it re-checks the switch
/// every 15 s — the moment dispatch turns it off, the page dismisses itself
/// and the app boots normally, no app restart needed. A failed poll keeps
/// the page up (the gate is fail-open at BOOT, not while displayed).
class UpdateRequiredScreen extends StatefulWidget {
  final String storeUrl;

  const UpdateRequiredScreen({super.key, required this.storeUrl});

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  static const _bg = Color(0xFF0A0E1A);
  static const _gold = Color(0xFFE8C547);
  static const _pollEvery = Duration(seconds: 15);

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollEvery, (_) => _recheck());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _recheck() async {
    final gate = await ApiService.getAppUpdateStatus();
    if (!mounted || gate == null) return; // error = stay put
    if (gate['required'] == true) return;
    // Switch turned OFF — hand the app back to the normal boot sequence.
    _poll?.cancel();
    Navigator.of(context).pushReplacementNamed('/');
  }

  Future<void> _openStore() async {
    final uri = Uri.tryParse(widget.storeUrl);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[UpdateRequired] store launch failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // blocking by design — no gesture/back escape
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                // Hero: update glyph on a gold-halo circle (stands in for
                // the mockup's phone illustration).
                Container(
                  width: 148,
                  height: 148,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _gold.withValues(alpha: 0.10),
                    border: Border.all(
                        color: _gold.withValues(alpha: 0.35), width: 1.5),
                  ),
                  child: const Center(
                    child: Icon(Icons.system_update_alt_rounded,
                        size: 64, color: _gold),
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  S.of(context).updateRequiredTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  S.of(context).updateRequiredBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9AA3B8),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const Spacer(flex: 3),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _openStore,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: _bg,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      S.of(context).updateNowButton,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
