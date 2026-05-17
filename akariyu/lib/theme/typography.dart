import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

/// akariyu.dev design system — typography.
class AkariyuTypography {
  AkariyuTypography._();

  static TextStyle get _base => GoogleFonts.inter(
        color: AkariyuColors.textPrimary,
        height: 1.4,
      );

  static TextStyle get displayLarge => _base.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.2,
      );

  static TextStyle get displayMedium => _base.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.25,
      );

  static TextStyle get headlineLarge => _base.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.3,
      );

  static TextStyle get titleLarge => _base.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      );

  static TextStyle get bodyLarge => _base.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w400,
      );

  static TextStyle get bodyMedium => _base.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AkariyuColors.textSecondary,
      );

  static TextStyle get bodySmall => _base.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AkariyuColors.textSecondary,
      );

  static TextStyle get labelLarge => _base.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      );

  static TextStyle get labelSmall => _base.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AkariyuColors.textTertiary,
        letterSpacing: 0.4,
      );

  static TextStyle get mono => GoogleFonts.jetBrainsMono(
        color: AkariyuColors.textPrimary,
        fontSize: 14,
        height: 1.5,
      );

  static TextStyle get monoSmall => GoogleFonts.jetBrainsMono(
        color: AkariyuColors.textSecondary,
        fontSize: 12,
        height: 1.5,
      );
}
