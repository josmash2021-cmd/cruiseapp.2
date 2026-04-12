/// Compile-time feature flags for the Cruise rider + driver apps.
///
/// Each flag is a top-level `const bool`. Flags live in ONE place so you
/// can grep `FeatureFlags.` to see every conditional code path in the app
/// without hunting through random files.
///
/// Adding a new flag:
/// 1. Add a `static const bool <name> = false;` below.
/// 2. In the call site, `if (FeatureFlags.<name>) { ... } else { ... }`.
/// 3. Flip to `true` when you're ready to ship the new code path.
/// 4. When the new code path is the default, remove the flag + old branch
///    in a follow-up commit.
///
/// NEVER read env vars, SharedPreferences, or Firebase remote config here.
/// Flags are compile-time only so the compiler can tree-shake the dead
/// branch and we never ship the old code path once the flag is removed.
class FeatureFlags {
  const FeatureFlags._();

  /// Rider-side single-map "shell" refactor.
  ///
  /// When ON, the rider flow from choose-vehicle through rating is
  /// rendered inside a single [RiderFlowShell] widget with fading
  /// bottom-sheet cards instead of 3 separate full-screen widgets
  /// (RideRequestScreen + SearchingDriverScreen + RiderTrackingScreen).
  /// The map never re-inits between phases, producing the Uber-style
  /// continuous flow with no black flash and no per-phase camera reset.
  ///
  /// Safe to toggle: when OFF the shell code is never reached and the
  /// app behaves exactly as it did before 2026-04-11. See
  /// `lib/screens/rider_flow/` for the implementation.
  static const bool useRiderFlowShell = true;
}
