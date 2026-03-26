import 'package:flutter/material.dart';

/// Lightweight error display service. Call [show] from anywhere with a
/// BuildContext to surface a user-facing SnackBar on failure.
class ErrorService {
  ErrorService._();

  /// Global key for showing SnackBars from anywhere (when context is unavailable).
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Show a short error SnackBar with an optional retry action.
  static void show(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFFB00020),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: onRetry != null
            ? SnackBarAction(
                label: 'RETRY',
                textColor: const Color(0xFFE8C547),
                onPressed: onRetry,
              )
            : null,
      ),
    );
  }

  /// Show via the global key (no context needed). Use sparingly.
  static void showGlobal(String message) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFFB00020),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
