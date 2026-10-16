import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/onboarding/onboarding_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/onboarding_progress.dart';
import 'email_sign_in_step.dart';
import 'pairing_step.dart';
import 'permissions_step.dart';
import 'privacy_step.dart';
import 'welcome_step.dart';

final class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.controller,
    required this.onComplete,
    this.notice,
    super.key,
  });

  final OnboardingController controller;
  final VoidCallback onComplete;

  /// Shown on the welcome: why the phone was signed out, when it was not by choice.
  final String? notice;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

final class _OnboardingScreenState extends State<OnboardingScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

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
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handlePrimary(OnboardingState state) async {
    switch (state.step) {
      case OnboardingStep.signIn:
        await widget.controller.signIn(
          _emailController.text,
          _passwordController.text,
        );
      case OnboardingStep.permissions:
        await widget.controller.requestPermissions();
      case OnboardingStep.pairing:
        await widget.controller.pair();
      case OnboardingStep.privacy:
        await widget.controller.finishPrivacy();
        if (mounted && widget.controller.value.completed) {
          widget.onComplete();
        }
      case OnboardingStep.firstResult:
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
        if (!state.initialized) {
          return Scaffold(
            body: Center(
              child: Semantics(
                label: 'Loading setup progress',
                liveRegion: true,
                child: const CircularProgressIndicator(),
              ),
            ),
          );
        }
        if (state.step == OnboardingStep.signIn && state.showWelcome) {
          return WelcomeStep(
            onEmail: widget.controller.continueWithEmail,
            notice: widget.notice,
          );
        }
        final setupStep = state.step == OnboardingStep.firstResult
            ? null
            : state.step.index + 1;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (setupStep != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Transform.translate(
                            offset: const Offset(-10, 0),
                            child: IconButton(
                              key: const Key('onboarding-back'),
                              tooltip: 'Back',
                              onPressed:
                                  state.busy ? null : widget.controller.goBack,
                              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                                  size: 20),
                            ),
                          ),
                          Expanded(child: OnboardingProgress(step: setupStep)),
                        ],
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 28, bottom: 20),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: KeyedSubtree(
                          key: ValueKey(state.step),
                          child: _step(state),
                        ),
                      ),
                    ),
                  ),
                  _actionArea(state: state),
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
      OnboardingStep.signIn => EmailSignInStep(
          emailController: _emailController,
          passwordController: _passwordController,
          enabled: !state.busy,
          onSubmit: () => unawaited(_handlePrimary(state)),
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
      OnboardingStep.privacy => const PrivacyStep(),
      OnboardingStep.firstResult => Text(
          'Try it now',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
    };
  }

  Widget _actionArea({required OnboardingState state}) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.error case final error?)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: palette.red,
                      ),
                ),
              ),
            ),
          if (state.step == OnboardingStep.signIn)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: palette.text2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This phone gets its own key. You can sign it out later from '
                      'Settings, without touching your other devices.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 54,
            child: FilledButton(
              key: state.step == OnboardingStep.signIn
                  ? const Key('sign-in-submit')
                  : const Key('onboarding-primary'),
              onPressed: state.busy ? null : () => _handlePrimary(state),
              child: state.busy
                  ? Semantics(
                      label: 'Working',
                      liveRegion: true,
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.background,
                        ),
                      ),
                    )
                  : Text(_primaryLabel(state)),
            ),
          ),
          if (state.step == OnboardingStep.pairing && !state.paired)
            SizedBox(
              height: 48,
              child: TextButton(
                key: const Key('onboarding-skip-pairing'),
                onPressed: state.busy ? null : widget.controller.skipPairing,
                style: TextButton.styleFrom(foregroundColor: palette.text),
                child: const Text("I don't have it with me"),
              ),
            ),
        ],
      ),
    );
  }

  String _primaryLabel(OnboardingState state) {
    return switch (state.step) {
      OnboardingStep.signIn => 'Sign in',
      OnboardingStep.permissions => 'Allow and continue',
      OnboardingStep.pairing => 'Pair Echo',
      OnboardingStep.privacy =>
        state.paired ? 'Start listening' : 'Start using Echo',
      OnboardingStep.firstResult => 'Go to Today',
    };
  }
}
