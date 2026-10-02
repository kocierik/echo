import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../theme/app_theme.dart';
import 'device_status_strip.dart';
import 'echo_bottom_navigation.dart';

final class EchoAppShell extends StatelessWidget {
  const EchoAppShell({
    required this.selectedIndex,
    required this.status,
    required this.onDestinationSelected,
    required this.onSettingsTap,
    required this.children,
    this.onStatusTap,
    super.key,
  })  : assert(selectedIndex >= 0 && selectedIndex < 3),
        assert(children.length == 3);

  final int selectedIndex;
  final DeviceStatus status;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onStatusTap;
  final VoidCallback onSettingsTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return ColoredBox(
      color: palette.background,
      child: Column(
        children: [
          ColoredBox(
            color: palette.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Expanded(
                      child: DeviceStatusStrip(
                        status: status,
                        onTap: onStatusTap,
                      ),
                    ),
                    SizedBox.square(
                      dimension: 56,
                      child: IconButton(
                        key: const Key('echo-settings-action'),
                        tooltip: 'Settings',
                        onPressed: onSettingsTap,
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: selectedIndex,
              sizing: StackFit.expand,
              children: children,
            ),
          ),
          EchoBottomNavigation(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
          ),
        ],
      ),
    );
  }
}