import 'package:flutter/material.dart';
import 'driver_map_shell_screen.dart';

/// Navigates back to the driver online flow.
///
/// Strategy:
/// 1. First, try to pop back to an existing [DriverMapShellScreen] in the
///    navigation stack. This preserves the persistent map.
/// 2. If no shell exists below (e.g., direct navigation from DriverHomeScreen),
///    push a new [DriverMapShellScreen].
/// 3. If [clearStack] is true, remove all intermediate routes so only the
///    first route (usually HomeScreen) remains below the new shell.
///
/// This is called from:
/// - DriverTripAcceptScreen (trip cancelled/completed)
/// - DriverRateRiderScreen (after rating submission)
/// - Any screen that needs to return to the online searching state
void navigateToDriverOnline(
  BuildContext context, {
  bool clearStack = false,
}) {
  final nav = Navigator.of(context);

  // Strategy 1: Try to pop back to an existing shell.
  // This preserves the persistent map and is the fastest path.
  if (nav.canPop()) {
    nav.pop();
    return;
  }

  // Strategy 2: No shell in stack — create a new one.
  // This happens when DriverTripAcceptScreen was opened directly
  // from DriverHomeScreen (scheduled rides, resume active trip).
  final route = PageRouteBuilder(
    pageBuilder: (_, __, ___) => const DriverMapShellScreen(),
    transitionsBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
    transitionDuration: const Duration(milliseconds: 400),
  );

  if (clearStack) {
    nav.pushAndRemoveUntil(route, (r) => r.isFirst);
  } else {
    nav.push(route);
  }
}
