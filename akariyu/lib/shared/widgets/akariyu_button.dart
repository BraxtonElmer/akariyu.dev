import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';

enum AkariyuButtonVariant { primary, secondary, ghost, destructive }

class AkariyuButton extends StatelessWidget {
  const AkariyuButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AkariyuButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.fullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AkariyuButtonVariant variant;
  final IconData? icon;
  final bool loading;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;
    final colors = _colorsFor(variant, disabled: disabled);

    Widget child;
    if (loading) {
      child = SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.foreground,
        ),
      );
    } else {
      child = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: colors.foreground),
            const SizedBox(width: 8),
          ],
          Text(label, style: AkariyuTypography.labelLarge.copyWith(
            color: colors.foreground,
          )),
        ],
      );
    }

    return SizedBox(
      width: fullWidth ? double.infinity : null,
      child: Material(
        color: colors.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: colors.border == null
              ? BorderSide.none
              : BorderSide(color: colors.border!, width: 1),
        ),
        child: InkWell(
          onTap: disabled
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  onPressed!();
                },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  _ButtonColors _colorsFor(AkariyuButtonVariant variant, {required bool disabled}) {
    switch (variant) {
      case AkariyuButtonVariant.primary:
        return _ButtonColors(
          background: disabled ? AkariyuColors.surfaceCard : AkariyuColors.accent,
          foreground: disabled ? AkariyuColors.textTertiary : AkariyuColors.textPrimary,
          border: null,
        );
      case AkariyuButtonVariant.secondary:
        return _ButtonColors(
          background: AkariyuColors.surfaceCard,
          foreground: disabled ? AkariyuColors.textTertiary : AkariyuColors.textPrimary,
          border: AkariyuColors.borderSubtle,
        );
      case AkariyuButtonVariant.ghost:
        return _ButtonColors(
          background: Colors.transparent,
          foreground: disabled ? AkariyuColors.textTertiary : AkariyuColors.textPrimary,
          border: null,
        );
      case AkariyuButtonVariant.destructive:
        return _ButtonColors(
          background: disabled ? AkariyuColors.surfaceCard : AkariyuColors.error,
          foreground: disabled ? AkariyuColors.textTertiary : AkariyuColors.textPrimary,
          border: null,
        );
    }
  }
}

class _ButtonColors {
  _ButtonColors({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color? border;
}
