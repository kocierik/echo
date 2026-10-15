import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_view_state.dart';
import '../../services/app/app_controller.dart';
import 'settings_components.dart';

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({required this.appController, super.key});

  final AppController appController;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appController,
      builder: (context, state, child) {
        return SettingsPageScaffold(
          title: 'Appearance',
          children: [
            const SettingsSection('THEME'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SegmentedButton<ThemePreference>(
                key: const Key('theme-mode-control'),
                segments: const [
                  ButtonSegment(
                    value: ThemePreference.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemePreference.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemePreference.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {state.themePreference},
                onSelectionChanged: (selection) {
                  unawaited(appController.setTheme(selection.single));
                },
              ),
            ),
          ],
        );
      },
    );
  }
}