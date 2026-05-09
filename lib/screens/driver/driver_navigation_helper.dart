import 'package:flutter/material.dart';
import '../../config/page_transitions.dart';
import 'driver_map_shell_screen.dart';

/// Navigates back to the driver online flow.
///
/// If the current screen was pushed on top of a [DriverMapShellScreen],
/// this pops back to the shell (preserving the persistent map).
///
/// If there is no shell in the stack (e.g., direct navigation from
/// DriverHomeScreen), this pushes a new [DriverMapShellScreen] and
/// clears intermediate routes.
///
/// [keepUntilFirst] — if true, keeps only the first route (HomeScreen).
///   Use this when the trip was cancelled/completed and you want to
///   reset the navigation stack.
void navigateToDriverOnline(
  BuildContext context, {
  bool keepUntilFirst = false,
}) {
  final nav = Navigator.of(context);

  // Try to pop first — this works when we're on top of the shell
  if (nav.canPop() && !keepUntilFirst) {
    nav.pop();
    return;
  }

  // No shell below — push a new one and optionally clear the stack
  final route = PageRouteBuilder(
    pageBuilder: (_, __, ___) => const DriverMapShellScreen(),
    transitionsBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
    transitionDuration: const Duration(milliseconds: 400),
  );

  if (keepUntilFirst) {
    nav.pushAndRemoveUntil(route, (r) => r.isFirst);
  } else {
    nav.push(route);
  }
}
