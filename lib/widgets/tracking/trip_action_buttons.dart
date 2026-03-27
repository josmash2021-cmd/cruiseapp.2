part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP ACTION BUTTONS — cancel, share, feedback dialogs
// ════════════════════════════════════════════════════════════

extension _RiderTrackingActionButtons on _RiderTrackingScreenState {

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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          s.cancelRideQuestion,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          s.cancelRideConfirm,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.no, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Clear persisted active ride so banner disappears
              LocalDataService.clearActiveRide();
              if (widget.tripId != null) {
                try {
                  await ApiService.cancelTrip(widget.tripId!);
                } catch (_) {}
              }
              AnalyticsService.instance.logRideCancelled('user_cancelled', false);
              // Clean up all map annotations before navigating away
              await _cleanupMapAnnotations();
              if (!mounted) return;
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
              s.cancelRide,
              style: const TextStyle(color: Color(0xFFFF3B30)),
            ),
          ),
        ],
      ),
    );
  }

  /// Shows a clear dialog when the driver (or backend) cancels the trip.
  /// The rider must acknowledge before being sent back to home.
  void _showDriverCancelledDialog() {
    if (!mounted) return;
    // Prevent duplicate dialogs
    _statusPollTimer?.cancel();
    _driverLocSub?.cancel();
    _tripStatusSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    LocalDataService.clearActiveRide();
    final s = S.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_outlined, color: Color(0xFFFF3B30), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                s.rideCancelledByDriver,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          s.driverCancelledMessage,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
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
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(s.ok, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ],
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
                    // Cancel the trip
                    if (widget.tripId != null) {
                      try {
                        await ApiService.cancelTrip(widget.tripId!);
                        LocalDataService.clearActiveRide();
                      } catch (_) {}
                    }
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => const HomeScreen(),
                          transitionsBuilder: (_, anim, __, child) =>
                              FadeTransition(opacity: anim, child: child),
                          transitionDuration: const Duration(milliseconds: 400),
                        ),
                        (_) => false,
                      );
                    }
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
}
