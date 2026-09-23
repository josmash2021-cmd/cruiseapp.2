part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP ACTION BUTTONS — cancel, share, feedback dialogs
// ════════════════════════════════════════════════════════════

extension _RiderTrackingActionButtons on _RiderTrackingScreenState {

  // ── Cancel overlay: blur → spinner "Cancelando viaje..." → checkmark "Viaje cancelado" → home ──

  /// Kick off the full cancel flow (overlay + API + navigate)
  void _startCancelFlow({String? reason}) {
    _setState(() => _cancelOverlayPhase = 1);
    _executeCancelAndTransition(reason: reason);
  }

  /// Instant pre-pickup cancellation (2026-08-08): POST /trips/{id}/cancel
  /// works even with a driver assigned — the backend charges $5.00 only
  /// when the driver has been assigned/en route for more than 2 minutes
  /// (free before that) and rejects in-trip cancels server-side. Success
  /// runs the overlay + home transition; failure surfaces as a real error
  /// and the rider stays on the tracking screen. [reason] is the machine
  /// string from the cancel-reasons sheet (audit trail, optional).
  Future<void> _cancelTripInstantly({String? reason}) async {
    final tripId = widget.tripId;
    if (tripId == null) return;
    _setState(() => _cancelOverlayPhase = 1);
    try {
      await ApiService.cancelTrip(tripId, cancelReason: reason);
    } catch (e) {
      debugPrint('[RiderTracking] cancelTrip($tripId) failed: $e');
      if (!mounted) return;
      _setState(() => _cancelOverlayPhase = 0);
      _messenger?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).cancelOnServerFailedActive),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }
    if (!mounted) return;
    await _finishCancelTransition();
  }

  Future<void> _executeCancelAndTransition({String? reason}) async {
    bool backendOk = true;
    if (widget.tripId != null) {
      try {
        await ApiService.cancelTrip(widget.tripId!, cancelReason: reason);
      } catch (e) {
        backendOk = false;
        debugPrint('[RiderTracking] cancelTrip(${widget.tripId}) failed: $e');
      }
    }
    if (!backendOk && mounted) {
      // Show a warning but continue the flow so the rider isn't stuck.
      // Backend will eventually reconcile via the dispatch auto-cancel loop.
      _messenger?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).cancelRequestRetryBackground),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    }
    await _finishCancelTransition();
  }

  /// Shared tail of a successful cancel: clear local state, show the
  /// checkmark overlay (phase 2), then go home.
  Future<void> _finishCancelTransition() async {
    await LocalDataService.clearActiveRide();
    AnalyticsService.instance.logRideCancelled('user_cancelled', false);
    await _cleanupMapAnnotations();
    if (!mounted) return;
    // Phase 2: checkmark
    _setState(() => _cancelOverlayPhase = 2);
    // Wait, then go home
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    widget.onTripComplete?.call();
    _nav?.pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (_) => false,
    );
  }

  /// Full-screen blur overlay with animated spinner / checkmark
  Widget _buildCancelOverlay() {
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        builder: (context, value, child) => BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12 * value, sigmaY: 12 * value),
          child: Container(
            color: const Color(0xFF111318).withValues(alpha: 0.7 * value),
            child: Opacity(opacity: value, child: child),
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_cancelOverlayPhase == 1) ...[
                const SizedBox(
                  width: 48, height: 48,
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD4AF37)),
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  S.of(context).cancellingTrip,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
              if (_cancelOverlayPhase == 2) ...[
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.elasticOut,
                  builder: (_, v, child) => Transform.scale(scale: v, child: child),
                  child: Container(
                    width: 64, height: 64,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00C853),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  S.of(context).tripCancelled,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showFeedbackDialog() {
    final controller = TextEditingController(text: _anonymousFeedback);
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.leaveAnonymousFeedback),
        content: TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: s.typeMessage,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              _setState(() {
                _anonymousFeedback = controller.text.trim();
              });
              Navigator.of(ctx).pop();
            },
            child: Text(s.save),
          ),
        ],
      ),
    );
  }

  Future<void> _handleShareTrip() async {
    // No trip id — nothing to share. Say so instead of doing nothing:
    // a button that silently ignores a tap reads as broken.
    if (widget.tripId == null) {
      if (mounted) {
        _messenger?.showSnackBar(
          SnackBar(
            content: Text(S.of(context).couldNotShareTripError('no trip')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    HapticService.selectionClick();
    try {
      final result = await ApiService.shareTrip(widget.tripId!);
      final shareUrl = result['share_url'] as String?;
      if (shareUrl == null) {
        if (mounted) {
          _messenger?.showSnackBar(
            SnackBar(
              content: Text(S.of(context).couldNotShareTripError('no link')),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      // Serves the live-tracking page: GET /track/{token}, backed by
      // /trips/shared/{token}/location for the moving car.
      final fullUrl = '${ApiService.publicBaseUrl}$shareUrl';
      if (!mounted) return;
      await shareText(
        context,
        '${S.of(context).trackMyCruiseRideLive} $fullUrl',
        subject: 'Cruise — Live Trip Tracking',
      );
      AnalyticsService.instance.logEvent('trip_shared');
    } catch (e) {
      if (!mounted) return;
      _messenger?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).couldNotShareTripError(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showCancelDialog() {
    // Cancel policy (2026-08-08): the backend allows instant rider
    // cancellation at any point before pickup — even with a driver
    // assigned — charging $5.00 only once the driver has been assigned /
    // en route for more than 2 minutes (free before that).
    // Reason sheet first (2026-09-23, same reference design as the
    // driver's): the picked reason rides to the API as `cancel_reason`,
    // then the confirm dialog that explains the fee rule (it lives in
    // driver_info_card.dart, _showCancelConfirmDialog).
    final s = S.of(context);
    showCancelReasonSheet(
      context,
      title: s.driverCancelChooseTitle,
      note: s.cancelFeeWarning,
      reasons: riderCancelReasons(s),
      nextLabel: s.nextLabel,
    ).then((reason) {
      if (reason == null || !mounted) return;
      _showCancelConfirmDialog(reason: reason);
    });
  }

  /// Shows a clear overlay when the driver (or backend) cancels the trip.
  Future<void> _showDriverCancelledDialog({String? message}) async {
    if (!mounted) return;
    _statusPollTimer?.cancel();
    _driverLocSub?.cancel();
    _tripStatusSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    await LocalDataService.clearActiveRide();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cancel_outlined, color: Color(0xFFEF4444), size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).rideCancelledByDriver,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                message ?? S.of(context).driverCancelledMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4AF37),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    if (!mounted) return;
                    widget.onTripComplete?.call();
                    _nav?.pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (_, __, ___) => const HomeScreen(),
                        transitionsBuilder: (_, a, __, child) =>
                            FadeTransition(opacity: a, child: child),
                        transitionDuration: const Duration(milliseconds: 400),
                      ),
                      (_) => false,
                    );
                  },
                  child: Text(
                    S.of(context).findAnotherRide,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows cancel confirmation dialog during onTrip phase
  void _showCancelOnTripDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: Color(0xFFFF3B30),
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).cancelTripConfirm,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).cancelFeeWarning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF3B30),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final s = S.of(context);
                    final reason = await showCancelReasonSheet(
                      context,
                      title: s.driverCancelChooseTitle,
                      note: s.cancelFeeWarning,
                      reasons: riderCancelReasons(s),
                      nextLabel: s.nextLabel,
                    );
                    if (reason == null || !mounted) return;
                    _startCancelFlow(reason: reason);
                  },
                  child: Text(
                    S.of(context).yesCancelTrip,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4A843),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    // Navigate to contact support
                    _nav?.push(
                      slideFromRightRoute(
                        const ChatScreen(
                          recipientName: 'Support',
                          avatarInitial: 'S',
                          tripId: null,
                        ),
                      ),
                    );
                  },
                  child: Text(
                    S.of(context).contactSupport,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'No',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.6),
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
