import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/akariyu_button.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

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
              const Spacer(),
              _Mark(),
              const SizedBox(height: 24),
              Text('akariyu.dev',
                  style: AkariyuTypography.displayLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'Your dev server, in your pocket.',
                style: AkariyuTypography.bodyMedium.copyWith(
                  color: AkariyuColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              AkariyuButton(
                label: 'Add server',
                fullWidth: true,
                onPressed: () => context.push('/onboarding/add'),
              ),
              const SizedBox(height: 12),
              AkariyuButton(
                label: 'Pair via QR (soon)',
                variant: AkariyuButtonVariant.secondary,
                fullWidth: true,
                onPressed: null,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: AkariyuColors.surfaceCard,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AkariyuColors.borderSubtle),
        ),
        alignment: Alignment.center,
        child: Text(
          '>_',
          style: AkariyuTypography.displayLarge.copyWith(
            color: AkariyuColors.accent,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
