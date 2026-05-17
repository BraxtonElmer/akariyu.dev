import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(biometricServiceProvider);
    final ok = await auth.authenticate(reason: 'Unlock akariyu');
    if (!mounted) return;
    if (ok) {
      context.go('/');
    } else {
      setState(() {
        _busy = false;
        _error = 'Authentication failed. Tap to try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              const _LockMark(),
              const SizedBox(height: 28),
              Text(
                'akariyu',
                style: AkariyuTypography.displayLarge.copyWith(
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Locked. Authenticate to continue.',
                style: AkariyuTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 4),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: AkariyuTypography.bodySmall.copyWith(
                    color: AkariyuColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              AkariyuButton(
                label: 'Unlock',
                variant: AkariyuButtonVariant.secondary,
                fullWidth: true,
                icon: Icons.lock_open_outlined,
                loading: _busy,
                onPressed: _busy ? null : _unlock,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockMark extends StatelessWidget {
  const _LockMark();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AkariyuColors.surfaceCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AkariyuColors.borderSubtle),
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.lock_outline,
          size: 28,
          color: AkariyuColors.textSecondary,
        ),
      ),
    );
  }
}
