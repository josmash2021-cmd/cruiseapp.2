import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Minimalist 3-color palette: Gold · Black · White
/// Automatically adapts to system light/dark mode.
/// Usage: `final c = AppColors.of(context);`
class AppColors {
  final Brightness brightness;

  const AppColors._({required this.brightness});

  /// Static gold constant — use when BuildContext is unavailable.
  static const Color kGold = Color(0xFFE8C547);
  static const Color kGoldLight = Color(0xFFF5D990);

  factory AppColors.of(BuildContext context) {
    return AppColors._(brightness: Theme.of(context).brightness);
  }

  bool get isDark => brightness == Brightness.dark;

  // ── Brand colors ──
  Color get gold => const Color(0xFFE8C547);
  Color get goldLight => const Color(0xFFF5D990);
  Color get goldDim => const Color(0xFFB08C35);

  // Semantic aliases (all map to gold/white variants)
  Color get promo => gold;
  Color get routeBlue => gold;
  Color get success => goldLight;
  Color get error => const Color(0xFFEF4444);

  // ── Backgrounds ──
  // Unified 2026-08-25: every page background is the shared grey
  // (0xFF14141A, `neuBase`) — no more near-black variants.
  Color get bg => const Color(0xFF14141A);
  Color get panel => isDark ? const Color(0xFF101114) : const Color(0xFF161820);
  Color get surface =>
      isDark ? const Color(0xFF161719) : const Color(0xFF1C1E24);
  Color get cardBg =>
      isDark ? const Color(0xFF0E0F12) : const Color(0xFF141518);

  // ── Text (white in both themes for dark cards) ──
  Color get textPrimary => Colors.white;
  Color get textSecondary => Colors.white.withValues(alpha: 0.50);
  Color get textTertiary => Colors.white.withValues(alpha: 0.30);
  Color get textOnGold => const Color(0xFF0A0800);

  // ── Borders & dividers ──
  Color get border => Colors.white.withValues(alpha: 0.06);
  Color get divider => Colors.white.withValues(alpha: 0.04);

  // ── Shadows ──
  Color get shadow => Colors.black.withValues(alpha: 0.35);

  // ── Icon colors ──
  Color get iconDefault => Colors.white.withValues(alpha: 0.55);
  Color get iconMuted => Colors.white.withValues(alpha: 0.20);
  Color get chevron => Colors.white.withValues(alpha: 0.14);

  // ── Search bar ──
  Color get searchText => Colors.white.withValues(alpha: 0.35);
  Color get searchBorder => gold.withValues(alpha: 0.25);

  // ── Chip button ──
  Color get chipText => Colors.white.withValues(alpha: 0.65);
  Color get chipBorder => Colors.white.withValues(alpha: 0.06);

  // ── Bottom nav ──
  Color get navInactive => Colors.white.withValues(alpha: 0.35);
  Color get navActiveBg => gold.withValues(alpha: 0.10);

  // ── Ride card gradients (dark in both themes) ──
  List<Color> get rideCardVip => [
    const Color(0xFF1A1500),
    const Color(0xFF100E00),
  ];
  List<Color> get rideCardPremium => [
    const Color(0xFF12120E),
    const Color(0xFF0D0D0A),
  ];
  List<Color> get rideCardComfort => [
    const Color(0xFF0F0F0C),
    const Color(0xFF0A0A08),
  ];

  // ── Ride card text ──
  Color get rideCardVehicle => Colors.white;
  Color get rideCardSub => Colors.white.withValues(alpha: 0.35);
  Color get rideCardBorder => Colors.white.withValues(alpha: 0.05);

  // ── Notification badge ──
  Color get badgeText => const Color(0xFF0A0800);

  // ── Map panel ──
  Color get mapPanel => const Color(0xFF111214);
  Color get mapSurface => const Color(0xFF1A1B1E);

  // ── Splash ──
  Color get splashBg => const Color(0xFF050505);
}

// ── Theme data builders ──

// Smooth fade for ALL platforms — consistent cross-platform feel
const _pageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _CruiseFadeTransitionBuilder(),
    TargetPlatform.iOS: _CruiseFadeTransitionBuilder(),
    TargetPlatform.windows: _CruiseFadeTransitionBuilder(),
    TargetPlatform.macOS: _CruiseFadeTransitionBuilder(),
    TargetPlatform.linux: _CruiseFadeTransitionBuilder(),
  },
);

/// Pure cross-fade page transition for every route in the app.
///
/// The outgoing page fades out 1.0 → 0.0 while the incoming page
/// fades in 0.0 → 1.0 on the same clock. Both use a slow easeInOut
/// curve so the crossover never feels abrupt. No slide, no scale —
/// the user explicitly asked for fade-in / fade-out without any
/// horizontal or vertical motion so the map underneath (and any
/// shared visual element) never jumps.
class _CruiseFadeTransitionBuilder extends PageTransitionsBuilder {
  const _CruiseFadeTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fadeIn = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    // Outgoing page fades all the way out (1 → 0) instead of holding
    // at 0.92. That prevents the visible "ghost" of the previous
    // screen showing through during the cross-fade.
    final fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeInOutCubic,
        reverseCurve: Curves.easeInOutCubic,
      ),
    );

    return FadeTransition(
      opacity: fadeOut,
      child: FadeTransition(
        opacity: fadeIn,
        child: child,
      ),
    );
  }
}

// Poppins (titles/headlines) + Inter (body/labels) — modern, clean, very readable
TextTheme _cinzelHeadlines(TextTheme base) {
  return base.copyWith(
    // ── Poppins for all headline/title/display styles ──
    displayLarge:  GoogleFonts.poppins(textStyle: base.displayLarge),
    displayMedium: GoogleFonts.poppins(textStyle: base.displayMedium),
    displaySmall:  GoogleFonts.poppins(textStyle: base.displaySmall),
    headlineLarge:  GoogleFonts.poppins(textStyle: base.headlineLarge),
    headlineMedium: GoogleFonts.poppins(textStyle: base.headlineMedium),
    headlineSmall:  GoogleFonts.poppins(textStyle: base.headlineSmall),
    titleLarge:  GoogleFonts.poppins(textStyle: base.titleLarge),
    titleMedium: GoogleFonts.poppins(textStyle: base.titleMedium),
    titleSmall:  GoogleFonts.poppins(textStyle: base.titleSmall),
    // ── Inter for body and label styles ──
    bodyLarge:   GoogleFonts.inter(textStyle: base.bodyLarge),
    bodyMedium:  GoogleFonts.inter(textStyle: base.bodyMedium),
    bodySmall:   GoogleFonts.inter(textStyle: base.bodySmall),
    labelLarge:  GoogleFonts.inter(textStyle: base.labelLarge),
    labelMedium: GoogleFonts.inter(textStyle: base.labelMedium),
    labelSmall:  GoogleFonts.inter(textStyle: base.labelSmall),
  );
}

// Shared button theme: scale-down on press, fast response
final _elevatedButtonTheme = ElevatedButtonThemeData(
  style: ButtonStyle(
    animationDuration: const Duration(milliseconds: 100),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return Colors.white.withValues(alpha: 0.12);
      }
      return null;
    }),
    splashFactory: InkRipple.splashFactory,
  ),
);

final _textButtonTheme = TextButtonThemeData(
  style: ButtonStyle(
    animationDuration: const Duration(milliseconds: 100),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return Colors.white.withValues(alpha: 0.08);
      }
      return null;
    }),
  ),
);

const _snackBarTheme = SnackBarThemeData(
  behavior: SnackBarBehavior.floating,
  backgroundColor: Color(0xFFE8C547),
  contentTextStyle: TextStyle(
    color: Colors.black,
    fontWeight: FontWeight.w600,
    fontSize: 14,
  ),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
  ),
  elevation: 8,
  dismissDirection: DismissDirection.down,
  insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
);

final ThemeData darkTheme = ThemeData.dark().copyWith(
  scaffoldBackgroundColor: const Color(0xFF08090C),
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFFE8C547),
    surface: Color(0xFF101114),
  ),
  textTheme: _cinzelHeadlines(
    GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
  ),
  pageTransitionsTheme: _pageTransitions,
  elevatedButtonTheme: _elevatedButtonTheme,
  textButtonTheme: _textButtonTheme,
  snackBarTheme: _snackBarTheme,
);

final ThemeData lightTheme = ThemeData.light().copyWith(
  scaffoldBackgroundColor: const Color(0xFFF5F5F5),
  brightness: Brightness.light,
  colorScheme: const ColorScheme.light(
    primary: Color(0xFFE8C547),
    surface: Color(0xFFFFFFFF),
  ),
  textTheme: _cinzelHeadlines(
    GoogleFonts.interTextTheme(ThemeData.light().textTheme),
  ),
  pageTransitionsTheme: _pageTransitions,
  elevatedButtonTheme: _elevatedButtonTheme,
  textButtonTheme: _textButtonTheme,
  snackBarTheme: _snackBarTheme,
);
