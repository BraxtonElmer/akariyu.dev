import 'package:flutter/material.dart';

import '../../theme/colors.dart';

enum DotStatus { idle, connecting, connected, error }

class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.status,
    this.size = 8,
  });

  final DotStatus status;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    _maybeAnimate();
  }

  @override
  void didUpdateWidget(covariant StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeAnimate();
  }

  void _maybeAnimate() {
    if (widget.status == DotStatus.connecting) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _colorFor(DotStatus s) {
    switch (s) {
      case DotStatus.idle:
        return AkariyuColors.statusIdle;
      case DotStatus.connecting:
        return AkariyuColors.statusRunning;
      case DotStatus.connected:
        return AkariyuColors.success;
      case DotStatus.error:
        return AkariyuColors.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(widget.status);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = widget.status == DotStatus.connecting
            ? 0.3 + (_controller.value * 0.7)
            : 1.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: opacity),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4 * opacity),
                blurRadius: 6,
                spreadRadius: 0,
              ),
            ],
          ),
        );
      },
    );
  }
}
