import 'package:flutter/material.dart';

import '../domain/hirang_theme_id.dart';

@immutable
class HirangSemanticColors extends ThemeExtension<HirangSemanticColors> {
  const HirangSemanticColors({
    required this.keepBackground,
    required this.keepForeground,
    required this.markBackground,
    required this.markForeground,
  });

  final Color keepBackground;
  final Color keepForeground;
  final Color markBackground;
  final Color markForeground;

  @override
  HirangSemanticColors copyWith({
    Color? keepBackground,
    Color? keepForeground,
    Color? markBackground,
    Color? markForeground,
  }) => HirangSemanticColors(
    keepBackground: keepBackground ?? this.keepBackground,
    keepForeground: keepForeground ?? this.keepForeground,
    markBackground: markBackground ?? this.markBackground,
    markForeground: markForeground ?? this.markForeground,
  );

  @override
  HirangSemanticColors lerp(covariant HirangSemanticColors? other, double t) {
    if (other == null) return this;
    return HirangSemanticColors(
      keepBackground: Color.lerp(keepBackground, other.keepBackground, t)!,
      keepForeground: Color.lerp(keepForeground, other.keepForeground, t)!,
      markBackground: Color.lerp(markBackground, other.markBackground, t)!,
      markForeground: Color.lerp(markForeground, other.markForeground, t)!,
    );
  }
}

@immutable
class HirangPalette {
  const HirangPalette({
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.tertiary,
    required this.scaffold,
    required this.appBar,
    required this.surface,
    required this.onSurface,
    required this.card,
  });

  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color tertiary;
  final Color scaffold;
  final Color appBar;
  final Color surface;
  final Color onSurface;
  final Color card;
}

HirangPalette hirangPaletteFor(HirangThemeId id) => switch (id) {
  HirangThemeId.amihan => const HirangPalette(
    primary: Color(0xFF153F5B),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF347F9B),
    tertiary: Color(0xFF5795B6),
    scaffold: Color(0xFFF1F6F7),
    appBar: Color(0xFFF1F6F7),
    surface: Color(0xFFFBFEFF),
    onSurface: Color(0xFF172832),
    card: Color(0xFFFFFFFF),
  ),
  HirangThemeId.dapithapon => const HirangPalette(
    primary: Color(0xFF91442E),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFFB45F43),
    tertiary: Color(0xFFD28A64),
    scaffold: Color(0xFFFBF3E8),
    appBar: Color(0xFFFBF3E8),
    surface: Color(0xFFFFFAF3),
    onSurface: Color(0xFF33251F),
    card: Color(0xFFFFFEFA),
  ),
  HirangThemeId.hatinggabi => const HirangPalette(
    primary: Color(0xFFBDB0ED),
    onPrimary: Color(0xFF2B2145),
    secondary: Color(0xFFAFC1EA),
    tertiary: Color(0xFFD5ADD5),
    scaffold: Color(0xFF171923),
    appBar: Color(0xFF171923),
    surface: Color(0xFF242633),
    onSurface: Color(0xFFF2F0F7),
    card: Color(0xFF292B38),
  ),
};

ThemeData buildHirangThemeFor(HirangThemeId id) {
  final isDark = id.isDark;
  final palette = hirangPaletteFor(id);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.primary,
        brightness: isDark ? Brightness.dark : Brightness.light,
      ).copyWith(
        primary: palette.primary,
        onPrimary: palette.onPrimary,
        secondary: palette.secondary,
        onSecondary: _accessibleForeground(palette.secondary),
        tertiary: palette.tertiary,
        onTertiary: _accessibleForeground(palette.tertiary),
        surface: palette.surface,
        onSurface: palette.onSurface,
      );
  final text = Typography.material2021().black.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final semantic = HirangSemanticColors(
    keepBackground: isDark ? const Color(0xFFB7E3C3) : const Color(0xFF226B45),
    keepForeground: isDark ? const Color(0xFF143722) : const Color(0xFFFFFFFF),
    markBackground: isDark ? const Color(0xFFF2B7B3) : const Color(0xFFA32D2B),
    markForeground: isDark ? const Color(0xFF561311) : const Color(0xFFFFFFFF),
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    brightness: isDark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    extensions: [semantic],
    textTheme: text,
    scaffoldBackgroundColor: palette.scaffold,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.appBar,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: palette.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      elevation: 1,
      shadowColor: scheme.shadow.withValues(alpha: .12),
      surfaceTintColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .55),
      space: 1,
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
  );
}

Color _accessibleForeground(Color background) {
  const light = Color(0xFFFFFFFF);
  const dark = Color(0xFF111111);
  double contrast(Color foreground) {
    final foregroundLuminance = foreground.computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance > backgroundLuminance
        ? backgroundLuminance
        : foregroundLuminance;
    return (lighter + .05) / (darker + .05);
  }

  return contrast(light) >= contrast(dark) ? light : dark;
}
