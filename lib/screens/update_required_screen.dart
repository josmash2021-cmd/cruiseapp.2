import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

/// Force-update gate (dispatch-controlled, 2026-10-10).
///
/// Shown as the ONLY route when GET /app-update-status answers
/// update_required=true — no back button, no skip, no way into the app
/// until the user updates from the store. The switch lives in the dispatch
/// panel (Administración → Actualización App) and takes effect without any
/// store release.
///
/// Real-time both ways (user spec): the socket ping `app_update_gate_changed`
/// flips live apps instantly — this page ANIMATES IN when the switch turns
/// on and ANIMATES OUT when it turns off, handing the app back to the
/// splash boot. Fallbacks: a 15 s poll while the page is up (socket dead),
/// and the boot check in the splash (app closed). A failed recheck keeps
/// the page up (fail-open applies to the boot, not to a shown gate).
class UpdateRequiredScreen extends StatefulWidget {
  final String storeUrl;

  const UpdateRequiredScreen({super.key, required this.storeUrl});

  /// Guard against stacking two gates (socket ping + boot race).
  static bool showing = false;

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFF0A0E1A);
  static const _gold = Color(0xFFE8C547);
  static const _pollEvery = Duration(seconds: 15);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    reverseDuration: const Duration(milliseconds: 350),
  )..forward();

  Timer? _poll;
  StreamSubscription<Map<String, dynamic>>? _gateSub;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    UpdateRequiredScreen.showing = true;
    _poll = Timer.periodic(_pollEvery, (_) => _recheck());
    _gateSub =
        SocketService.appUpdateGateStream.listen((_) => _recheck());
  }

  @override
  void dispose() {
    UpdateRequiredScreen.showing = false;
    _poll?.cancel();
    _gateSub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    if (_leaving) return;
    final gate = await ApiService.getAppUpdateStatus();
    if (!mounted || _leaving || gate == null) return; // error = stay put
    if (gate['required'] == true) return;
    await _dismissAnimated();
  }

  /// Animated exit: reverse the entrance, then re-run the normal boot.
  Future<void> _dismissAnimated() async {
    _leaving = true;
    _poll?.cancel();
    try {
      await _anim.reverse().orElse(() {});
    } catch (_) {}
    if (!mounted) return;
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

  Widget _fadeSlide(Widget child, double begin, double end,
      {double dy = 24}) {
    final curved = CurvedAnimation(
      parent: _anim,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, dy / 100),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
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
                // Hero: update glyph on a gold-halo circle, popping in with
                // a soft scale+fade ahead of the text.
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _anim,
                    curve: const Interval(0, 0.55, curve: Curves.easeOutBack),
                  ),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _anim,
                      curve: const Interval(0, 0.4),
                    ),
                    child: Container(
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
                  ),
                ),
                const SizedBox(height: 40),
                _fadeSlide(
                  Text(
                    S.of(context).updateRequiredTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  0.3,
                  0.75,
                ),
                const SizedBox(height: 14),
                _fadeSlide(
                  Text(
                    S.of(context).updateRequiredBody,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9AA3B8),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  0.45,
                  0.9,
                ),
                const Spacer(flex: 3),
                _fadeSlide(
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
                  0.6,
                  1.0,
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
