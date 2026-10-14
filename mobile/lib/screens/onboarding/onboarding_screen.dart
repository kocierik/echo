import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/build_defaults.dart';
import '../../services/onboarding_controller.dart';
import '../../theme/app_theme.dart';
import 'backend_step.dart';
import 'pairing_step.dart';
import 'permissions_step.dart';
import 'welcome_step.dart';

final class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.controller,
    required this.onComplete,
    super.key,
  });

  final OnboardingController controller;
  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

final class _OnboardingScreenState extends State<OnboardingScreen> {
  final _serverController = TextEditingController(text: BuildDefaults.serverUrl);
  final _apiKeyController = TextEditingController(text: BuildDefaults.apiKey);

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant OnboardingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _handlePrimary(OnboardingState state) async {
    switch (state.step) {
      case OnboardingStep.backend:
        await widget.controller.submitBackend(
          _serverController.text,
          _apiKeyController.text,
        );
      case OnboardingStep.permissions:
        await widget.controller.requestPermissions();
      case OnboardingStep.pairing:
        await widget.controller.pair();
      case OnboardingStep.privacy:
        await widget.controller.complete();
        if (mounted && widget.controller.value.completed) {
          widget.onComplete();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OnboardingState>(
      valueListenable: widget.controller,
      builder: (context, state, child) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  _OnboardingHeader(step: state.step),
                  Expanded(
                    child: state.initialized
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.only(top: 28, bottom: 20),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: KeyedSubtree(
                                key: ValueKey(state.step),
                                child: _step(state),
                              ),
                            ),
                          )
                        : Center(
                            child: Semantics(
                              label: 'Loading setup progress',
                              liveRegion: true,
                              child: const CircularProgressIndicator(),
                            ),
                          ),
                  ),
                  if (state.initialized) _actionArea(state: state),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _step(OnboardingState state) {
    return switch (state.step) {
      OnboardingStep.backend => BackendStep(
          serverController: _serverController,
          apiKeyController: _apiKeyController,
          enabled: !state.busy,
        ),
      OnboardingStep.permissions => PermissionsStep(
          backgroundExplanation:
              widget.controller.backgroundCapabilityExplanation,
          notificationDenied: state.notificationDenied,
          voiceDenied: state.voiceDenied,
        ),
      OnboardingStep.pairing => PairingStep(
          busy: state.busy,
          paired: state.paired,
        ),
      OnboardingStep.privacy => const WelcomeStep(),
    };
  }

  Widget _actionArea({required OnboardingState state}) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.error case final error?)
            Semantics(
              liveRegion: true,
              label: 'Error: $error',
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.red,
                      ),
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: state.busy ? null : () => _handlePrimary(state),
              child: state.busy
                  ? Semantics(
                      label: 'Working',
                      liveRegion: true,
                      child: const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : Text(_primaryLabel(state.step)),
            ),
          ),
          if (state.step == OnboardingStep.pairing && !state.paired)
            SizedBox(
              height: 44,
              child: TextButton(
                key: const Key('onboarding-skip-pairing'),
                onPressed: state.busy ? null : widget.controller.skipPairing,
                child: const Text('Skip for now'),
              ),
            ),
          if (state.step != OnboardingStep.backend)
            SizedBox(
              height: 44,
              child: TextButton.icon(
                onPressed: state.busy ? null : widget.controller.goBack,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Back'),
              ),
            ),
        ],
      ),
    );
  }

  String _primaryLabel(OnboardingStep step) {
    return switch (step) {
      OnboardingStep.backend => 'Connect backend',
      OnboardingStep.permissions => 'Allow and continue',
      OnboardingStep.pairing => 'Pair Echo',
      OnboardingStep.privacy => 'Start using Echo',
    };
  }
}

final class _OnboardingHeader extends StatelessWidget {
  const _OnboardingHeader({required this.step});

  final OnboardingStep step;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: palette.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text('Echo', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(width: 10),
              // Takes the free space and shortens on narrow screens with large text
              Expanded(
                child: Text(
                  'Step ${step.index + 1} of ${OnboardingStep.values.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Onboarding progress: step ${step.index + 1} of 4',
            child: Row(
              children: List.generate(OnboardingStep.values.length, (index) {
                return Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(
                      right: index == OnboardingStep.values.length - 1 ? 0 : 6,
                    ),
                    decoration: BoxDecoration(
                      color: index <= step.index ? palette.blue : palette.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}