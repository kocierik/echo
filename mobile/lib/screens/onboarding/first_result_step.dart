import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/onboarding/first_result_watcher.dart';
import '../../theme/app_theme.dart';
import '../../widgets/panel.dart';

/// The first request to say, in the phone's language: Echo transcribes in the user's,
/// and an Italian saying "Echo" alone is heard "Ecco", a word; after "Ehi" it is the name.
const firstRequests = {
  'en': 'Hey Echo, remind me to call Giulia on Friday at six.',
  'it': 'Ehi Echo, ricordami di chiamare Giulia venerdì alle sei.',
};

String firstRequestFor(String? language) => firstRequests[language] ?? firstRequests['en']!;

/// The end of the first run: the user asks Echo something out loud and sees it
/// heard and understood. Without a watcher (no server to ask) it only explains.
final class FirstResultStep extends StatefulWidget {
  const FirstResultStep({this.createWatcher, super.key});

  /// Makes the watcher this step starts, and disposes when it goes.
  final FirstResultWatcher Function()? createWatcher;

  @override
  State<FirstResultStep> createState() => _FirstResultStepState();
}

final class _FirstResultStepState extends State<FirstResultStep> {
  FirstResultWatcher? _watcher;

  @override
  void initState() {
    super.initState();
    final watcher = widget.createWatcher?.call();
    _watcher = watcher;
    if (watcher != null) unawaited(watcher.start());
  }

  @override
  void dispose() {
    _watcher?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watcher = _watcher;
    if (watcher == null) return _view(const FirstResultState());
    return ValueListenableBuilder<FirstResultState>(
      valueListenable: watcher,
      builder: (context, state, _) => _view(state),
    );
  }

  Widget _view(FirstResultState state) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final heard = state.heard;
    final answer = state.answer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Try it now', style: textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            text: 'Say, out loud: ',
            children: [
              TextSpan(
                text: '"${firstRequestFor(WidgetsBinding.instance.platformDispatcher.locale.languageCode)}"',
                style:
                    TextStyle(color: palette.text, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          style: textTheme.bodyLarge?.copyWith(color: palette.text2),
        ),
        const SizedBox(height: 24),
        Container(
          key: const Key('first-result-heard'),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(AppTheme.panelRadius),
            border: Border.all(
              color: heard == null ? palette.surface : palette.live,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: heard == null ? palette.text2 : palette.live,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Echo heard',
                    style: textTheme.labelMedium?.copyWith(
                      color: heard == null ? palette.text2 : palette.liveText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  heard ?? 'Waiting for you to speak…',
                  style: textTheme.bodyLarge?.copyWith(
                    fontSize: 18,
                    color: heard == null ? palette.text2 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          key: const Key('first-result-answer'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Echo understood',
                style: textTheme.labelMedium?.copyWith(
                  color: palette.text2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  answer ??
                      (state.gaveUp
                          ? "Echo is still working on it. You'll find it on Today."
                          : 'The answer shows here.'),
                  style: textTheme.bodyLarge?.copyWith(
                    color: answer == null ? palette.text2 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (answer != null) ...[
          const SizedBox(height: 16),
          Text(
            'That is all it takes. From now on Echo keeps your conversations, and what '
            'comes out of them, on Today.',
            style: textTheme.bodyMedium?.copyWith(color: palette.text2),
          ),
        ],
      ],
    );
  }
}
