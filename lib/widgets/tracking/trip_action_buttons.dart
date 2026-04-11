part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP ACTION BUTTONS — cancel, share, feedback dialogs
// ════════════════════════════════════════════════════════════

extension _RiderTrackingActionButtons on _RiderTrackingScreenState {

  // ── Cancel overlay: blur → spinner "Cancelando viaje..." → checkmark "Viaje cancelado" → home ──

  /// Kick off the full cancel flow (overlay + API + navigate)
  void _startCancelFlow() {
    _setState(() => _cancelOverlayPhase = 1);
    _executeCancelAndTransition();
  }

  Future<void> _executeCancelAndTransition() async {
    await LocalDataService.clearActiveRide();
    bool backendOk = true;
    if (widget.tripId != null) {
      try {
        await ApiService.cancelTrip(widget.tripId!);
      } catch (e) {
        backendOk = false;
        debugPrint('[RiderTracking] cancelTrip(${widget.tripId}) failed: $e');
      }
    }
    if (!backendOk && mounted) {
      // Show a warning but continue the flow so the rider isn't stuck.
      // Backend will eventually reconcile via the dispatch auto-cancel loop.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Cancel request may not have reached the server — we will retry in the background',
          ),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    }
    AnalyticsService.instance.logRideCancelled('user_cancelled', false);
    await _cleanupMapAnnotations();
    if (!mounted) return;
    // Phase 2: checkmark
    _setState(() => _cancelOverlayPhase = 2);
    // Wait, then go home
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    widget.onTripComplete?.call();
    Navigator.of(context).pushAndRemoveUntil(
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
    if (widget.tripId == null) return;
    try {
      final result = await ApiService.shareTrip(widget.tripId!);
      final shareUrl = result['share_url'] as String?;
      if (shareUrl == null) return;
      final fullUrl = '${ApiService.publicBaseUrl}$shareUrl';
      await Share.share(
        'Track my Cruise ride live: $fullUrl',
        subject: 'Cruise - Live Trip Tracking',
      );
      AnalyticsService.instance.logEvent('trip_shared');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not share trip: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showCancelDialog() {
    final s = S.of(context);
    // ── Cancel policy (2026-04-11) ──────────────────────────────────
    // RiderTrackingScreen only opens once a driver has been assigned
    // and is arriving/en-route/arrived/in_trip. Per policy, riders may
    // NOT directly cancel trips with a driver assigned — the only
    // escape path is to contact support, which creates an action
    // request for dispatch. So from this screen we always route to
    // Contact Support.  The in-app flow that cancels BEFORE a driver
    // is assigned lives in RideRequestScreen's waiting mode, not here.
    _showContactSupportForCancel();
    return;
    showDialog(
      context: context,
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
                s.cancelRideQuestion,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                s.cancelRideConfirm,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _startCancelFlow();
                  },
                  child: Text(
                    s.cancelRide,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity, height: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    s.no,
                    style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.6),
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
                    Navigator.of(context).pushAndRemoveUntil(
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
                    _startCancelFlow();
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
                    Navigator.of(context).push(
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

  /// Shown when the rider asks to cancel but a driver is already assigned.
  /// Per policy, the only way to cancel at that point is to contact
  /// dispatch. This dialog explains why and opens the support chat.
  void _showContactSupportForCancel() {
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
                  color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.support_agent_rounded,
                  color: Color(0xFFE8C547),
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Trip already in progress',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your driver is on the way. If you need to cancel, please contact support and a dispatcher will help you.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8C547),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                  label: Text(
                    S.of(context).contactSupport,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openSupportChatFromCancel();
                  },
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Close',
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

  /// Opens the support chat pre-filled with a cancellation request and
  /// fires the backend action-request so dispatch sees it immediately.
  Future<void> _openSupportChatFromCancel() async {
    final tripId = widget.tripId;
    if (tripId == null) return;
    // Fire-and-forget: create the action request. The support chat still
    // opens regardless so the rider can add context.
    unawaited(() async {
      try {
        await ApiService.requestTripCancel(
          tripId: tripId,
          reason: 'rider_requested_via_cancel_button',
          urgency: 'normal',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Dispatch has been notified and will contact you shortly.',
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Color(0xFF1a1a1a),
              duration: Duration(seconds: 4),
            ),
          );
        }
      } catch (e) {
        debugPrint('[RiderTracking] requestTripCancel failed: $e');
      }
    }());
    if (!mounted) return;
    Navigator.of(context).push(
      slideFromRightRoute(
        ChatScreen(
          recipientName: 'Support',
          isSupport: true,
          tripId: tripId,
          currentRole: 'rider',
        ),
      ),
    );
  }
}
