import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Four parts over the setup steps (sign-in, permissions, pairing, privacy).
final class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({required this.step, super.key})
      : assert(step >= 1 && step <= parts);

  static const parts = 4;

  /// 1–4.
  final int step;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Semantics(
      key: const Key('onboarding-progress'),
      label: 'Step $step of $parts',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var part = 1; part <= parts; part++) ...[
            if (part > 1) const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: part <= step ? palette.text : palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
