import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Minimalist 3-color palette: Gold · Black · White
/// Automatically adapts to system light/dark mode.
/// Usage: `final c = AppColors.of(context);`
class AppColors {
  final Brightness brightness;

  const AppColors._({required this.brightness});

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

  // ── Backgrounds (dark cards in both themes) ──
  Color get bg => isDark ? const Color(0xFF08090C) : const Color(0xFF0F1014);
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

const _pageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
  },
);

// Cinzel serif TextTheme — applied to all text styles for elegant branding
TextTheme _cinzelHeadlines(TextTheme base) {
  return base.copyWith(
    displayLarge: GoogleFonts.cinzel(textStyle: base.displayLarge),
    displayMedium: GoogleFonts.cinzel(textStyle: base.displayMedium),
    displaySmall: GoogleFonts.cinzel(textStyle: base.displaySmall),
    headlineLarge: GoogleFonts.cinzel(textStyle: base.headlineLarge),
    headlineMedium: GoogleFonts.cinzel(textStyle: base.headlineMedium),
    headlineSmall: GoogleFonts.cinzel(textStyle: base.headlineSmall),
    titleLarge: GoogleFonts.cinzel(textStyle: base.titleLarge),
    titleMedium: GoogleFonts.cinzel(textStyle: base.titleMedium),
    titleSmall: GoogleFonts.cinzel(textStyle: base.titleSmall),
    bodyLarge: GoogleFonts.cinzel(textStyle: base.bodyLarge),
    bodyMedium: GoogleFonts.cinzel(textStyle: base.bodyMedium),
    bodySmall: GoogleFonts.cinzel(textStyle: base.bodySmall),
    labelLarge: GoogleFonts.cinzel(textStyle: base.labelLarge),
    labelMedium: GoogleFonts.cinzel(textStyle: base.labelMedium),
    labelSmall: GoogleFonts.cinzel(textStyle: base.labelSmall),
  );
}

final ThemeData darkTheme = ThemeData.dark().copyWith(
  scaffoldBackgroundColor: const Color(0xFF08090C),
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFFE8C547),
    surface: Color(0xFF101114),
  ),
  textTheme: _cinzelHeadlines(ThemeData.dark().textTheme),
  pageTransitionsTheme: _pageTransitions,
);

final ThemeData lightTheme = ThemeData.light().copyWith(
  scaffoldBackgroundColor: const Color(0xFFF5F5F5),
  brightness: Brightness.light,
  colorScheme: const ColorScheme.light(
    primary: Color(0xFFE8C547),
    surface: Color(0xFFFFFFFF),
  ),
  textTheme: _cinzelHeadlines(ThemeData.light().textTheme),
  pageTransitionsTheme: _pageTransitions,
);
