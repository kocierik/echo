import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

final class EchoBottomNavigation extends StatelessWidget {
  const EchoBottomNavigation({
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  }) : assert(selectedIndex >= 0 && selectedIndex < _destinations.length);

  static const _destinations = <_EchoDestination>[
    _EchoDestination('Today', Icons.home_rounded),
    _EchoDestination('Transcripts', Icons.description_outlined),
    _EchoDestination('Ask', Icons.chat_bubble_outline_rounded),
  ];

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Material(
      color: palette.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: List.generate(_destinations.length, (index) {
                final destination = _destinations[index];
                final selected = index == selectedIndex;
                final color = selected ? palette.blue : palette.text2;
                return Expanded(
                  child: Semantics(
                    key: Key('echo-nav-$index'),
                    label: destination.label,
                    button: true,
                    selected: selected,
                    onTap: () => onDestinationSelected(index),
                    excludeSemantics: true,
                    child: Tooltip(
                      message: destination.label,
                      excludeFromSemantics: true,
                      child: InkWell(
                        onTap: () => onDestinationSelected(index),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(destination.icon, size: 22, color: color),
                            const SizedBox(height: 4),
                            Text(
                              destination.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: color),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

final class _EchoDestination {
  const _EchoDestination(this.label, this.icon);

  final String label;
  final IconData icon;
}