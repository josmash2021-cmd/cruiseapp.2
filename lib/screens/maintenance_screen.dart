import 'dart:async';

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

/// Maintenance kill page (dispatch-controlled, 2026-10-11 — user spec: "un
/// botón en dispatch para cuando la app presente problemas").
///
/// Shown as the ONLY route when GET /app-update-status answers
/// maintenance=true — no back, no skip. The switch lives in the dispatch
/// panel (Administración → Actualización App → Modo mantenimiento) and
/// flips live apps via the `app_update_gate_changed` socket ping.
///
/// Entrance pops UP (scale+fade from the centre) and the exit pops OUT,
/// like the update page's animation family. Real-time both ways: the page
/// re-checks on every socket ping and every 15 s — the moment dispatch
/// turns it off, the page dismisses itself and the app boots normally.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key});

  /// Guard against stacking two pages (socket ping + boot race).
  static bool showing = false;

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFF000000); // pure black, like the mockup
  static const _gold = Color(0xFFE8C547);
  static const _pollEvery = Duration(seconds: 15);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
    reverseDuration: const Duration(milliseconds: 280),
  )..forward();

  Timer? _poll;
  StreamSubscription<Map<String, dynamic>>? _gateSub;
  bool _leaving = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    MaintenanceScreen.showing = true;
    _poll = Timer.periodic(_pollEvery, (_) => _recheck());
    _gateSub = SocketService.appUpdateGateStream.listen((_) => _recheck());
  }

  @override
  void dispose() {
    MaintenanceScreen.showing = false;
    _poll?.cancel();
    _gateSub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    if (_leaving) return;
    setState(() => _checking = true);
    final gate = await ApiService.getAppUpdateStatus();
    if (!mounted || _leaving) return;
    setState(() => _checking = false);
    if (gate == null) return; // error = stay put (fail-open lives at boot)
    if (gate['maintenance'] == true) return;
    await _dismissAnimated();
  }

  /// Pop-out exit, then hand the app back to the normal boot sequence.
  Future<void> _dismissAnimated() async {
    _leaving = true;
    _poll?.cancel();
    try {
      await _anim.reverse();
    } on TickerCanceled {
      // disposed mid-flight — dispose() owns the rest
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/');
  }

  /// The bell badge while the art downloads (or if it ever fails).
  Widget _fallbackBadge() {
    return Container(
      width: 148,
      height: 148,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _gold.withValues(alpha: 0.10),
        border: Border.all(color: _gold.withValues(alpha: 0.35), width: 1.5),
      ),
      child: const Center(
        child: Icon(Icons.notifications_off_rounded, size: 64, color: _gold),
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
                // Pop-up entrance: scale from the centre with a soft back
                // ease, ahead of the text.
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _anim,
                    curve: const Interval(0, 0.6, curve: Curves.easeOutBack),
                  ),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _anim,
                      curve: const Interval(0, 0.45),
                    ),
                    child: Image.network(
                      '${ApiService.currentBaseUrl}/static/maintenance_hero.png',
                      width: 240,
                      fit: BoxFit.contain,
                      frameBuilder: (context, child, frame, wasSync) {
                        if (wasSync) return child;
                        if (frame == null) return _fallbackBadge();
                        return child; // already fading with the page
                      },
                      errorBuilder: (context, error, stack) =>
                          _fallbackBadge(),
                    ),
                  ),
                ),
                const SizedBox(height: 36),
                _fadeSlide(
                  Text(
                    S.of(context).maintenanceTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  0.25,
                  0.7,
                ),
                const SizedBox(height: 14),
                _fadeSlide(
                  Text(
                    S.of(context).maintenanceBody,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9AA3B8),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  0.4,
                  0.85,
                ),
                const Spacer(flex: 3),
                _fadeSlide(
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _checking ? null : _recheck,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _gold,
                        side: BorderSide(
                            color: _gold.withValues(alpha: 0.5), width: 1.4),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        _checking
                            ? S.of(context).loading
                            : S.of(context).maintenanceRetry,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
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

  Widget _fadeSlide(Widget child, double begin, double end) {
    final curved = CurvedAnimation(
      parent: _anim,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.24),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
