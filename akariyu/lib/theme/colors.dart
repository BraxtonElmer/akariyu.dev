import 'package:flutter/material.dart';

/// akariyu.dev design system — color palette.
///
/// Dark-only. Deep red accent (cybersigilism-adjacent).
class AkariyuColors {
  AkariyuColors._();

  // Surfaces
  static const Color backgroundBase = Color(0xFF0A0A0A);
  static const Color surfaceElevated = Color(0xFF141414);
  static const Color surfaceCard = Color(0xFF1C1C1C);
  static const Color borderSubtle = Color(0xFF262626);

  // Text
  static const Color textPrimary = Color(0xFFF5F5F5);
  static const Color textSecondary = Color(0xFFA3A3A3);
  static const Color textTertiary = Color(0xFF6B6B6B);

  // Accent (akariyu red) — deeper, dried-blood / sigil-ink tones,
  // not the bootstrap-danger #DC2626. Used sparingly.
  static const Color accent = Color(0xFFB1271C);
  static const Color accentMuted = Color(0xFF7F1D1D);
  static const Color accentDim = Color(0xFF3A0F0E);

  // Semantic
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  // Status colors
  static const Color statusIdle = Color(0xFF6B6B6B);
  static const Color statusRunning = Color(0xFFF59E0B);
  static const Color statusWaitingInput = Color(0xFF3B82F6);
  static const Color statusDone = Color(0xFF22C55E);
  static const Color statusError = Color(0xFFEF4444);
}
