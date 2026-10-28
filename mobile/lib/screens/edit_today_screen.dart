import 'package:flutter/material.dart';

import '../models/today_layout.dart';
import '../theme/app_theme.dart';

/// Edit Today: each section shown or hidden, in the order the user drags them to. Every
/// change is given to [onChanged] at once (it saves).
final class EditTodayScreen extends StatefulWidget {
  const EditTodayScreen({required this.layout, required this.onChanged, super.key});

  final TodayLayout layout;
  final ValueChanged<TodayLayout> onChanged;

  @override
  State<EditTodayScreen> createState() => _EditTodayScreenState();
}

final class _EditTodayScreenState extends State<EditTodayScreen> {
  late TodayLayout _layout = widget.layout;

  void _change(TodayLayout layout) {
    setState(() => _layout = layout);
    widget.onChanged(layout);
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Edit Today')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Drag to reorder. Things to confirm always stay on top.',
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ),
          Expanded(
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              onReorder: (from, to) => _change(_layout.moved(from, to)),
              footer: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: TextButton(
                    key: const Key('edit-today-reset'),
                    onPressed: () => _change(TodayLayout.defaults),
                    child: const Text('Reset to default'),
                  ),
                ),
              ),
              children: [
                for (final (index, section) in _layout.order.indexed)
                  Padding(
                    key: Key('edit-today-${section.name}'),
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: palette.surface,
                      borderRadius: BorderRadius.circular(AppTheme.panelRadius),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: Padding(
                              key: Key('edit-today-handle-${section.name}'),
                              padding: const EdgeInsets.all(14),
                              child: Icon(Icons.drag_handle_rounded, color: palette.text2),
                            ),
                          ),
                          Expanded(child: Text(section.label, style: textTheme.bodyLarge)),
                          Switch(
                            key: Key('edit-today-switch-${section.name}'),
                            value: !_layout.isHidden(section),
                            onChanged: (_) => _change(_layout.toggled(section)),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
