import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'colors.dart';
import 'typography.dart';

/// akariyu.dev unified theme.
class AkariyuTheme {
  AkariyuTheme._();

  static ThemeData get dark {
    const colorScheme = ColorScheme.dark(
      primary: AkariyuColors.accent,
      onPrimary: AkariyuColors.textPrimary,
      secondary: AkariyuColors.accentMuted,
      onSecondary: AkariyuColors.textPrimary,
      surface: AkariyuColors.surfaceCard,
      onSurface: AkariyuColors.textPrimary,
      error: AkariyuColors.error,
      onError: AkariyuColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AkariyuColors.backgroundBase,
      canvasColor: AkariyuColors.backgroundBase,
      splashFactory: NoSplash.splashFactory,
      textTheme: TextTheme(
        displayLarge: AkariyuTypography.displayLarge,
        displayMedium: AkariyuTypography.displayMedium,
        headlineLarge: AkariyuTypography.headlineLarge,
        titleLarge: AkariyuTypography.titleLarge,
        bodyLarge: AkariyuTypography.bodyLarge,
        bodyMedium: AkariyuTypography.bodyMedium,
        bodySmall: AkariyuTypography.bodySmall,
        labelLarge: AkariyuTypography.labelLarge,
        labelSmall: AkariyuTypography.labelSmall,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AkariyuColors.backgroundBase,
        foregroundColor: AkariyuColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: AkariyuTypography.headlineLarge,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
        ),
      ),
      cardTheme: CardThemeData(
        color: AkariyuColors.surfaceCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AkariyuColors.borderSubtle, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AkariyuColors.surfaceCard,
        hintStyle: AkariyuTypography.bodyMedium.copyWith(
          color: AkariyuColors.textTertiary,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AkariyuColors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AkariyuColors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AkariyuColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AkariyuColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AkariyuColors.error, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AkariyuColors.accent,
          foregroundColor: AkariyuColors.textPrimary,
          disabledBackgroundColor: AkariyuColors.surfaceCard,
          disabledForegroundColor: AkariyuColors.textTertiary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: AkariyuTypography.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AkariyuColors.textPrimary,
          side: const BorderSide(color: AkariyuColors.borderSubtle),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: AkariyuTypography.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AkariyuColors.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: AkariyuTypography.labelLarge,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AkariyuColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AkariyuColors.surfaceElevated,
        modalBackgroundColor: AkariyuColors.surfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        dragHandleColor: AkariyuColors.borderSubtle,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AkariyuColors.surfaceCard,
        contentTextStyle: AkariyuTypography.bodyMedium.copyWith(
          color: AkariyuColors.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AkariyuColors.borderSubtle),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AkariyuColors.accent,
        linearTrackColor: AkariyuColors.surfaceCard,
      ),
    );
  }
}
