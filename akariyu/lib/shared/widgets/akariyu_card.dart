import 'package:flutter/material.dart';

import '../../theme/colors.dart';

class AkariyuCard extends StatelessWidget {
  const AkariyuCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Material(
      color: AkariyuColors.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: const BorderSide(color: AkariyuColors.borderSubtle),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
