import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;

  /// Rows next to each other share a panel; a [SettingsSection] right before them is its header.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    // Pushed pages sit in a tab Navigator whose bottom padding is the floating bar.
    final bottom = MediaQuery.paddingOf(context).bottom + 32;
    return Scaffold(
      backgroundColor: palette.background,
      body: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(title),
            backgroundColor: palette.bar,
            border: Border(bottom: BorderSide(color: palette.border, width: 0.5)),
          ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: bottom),
            sliver: SliverList(
              delegate: SliverChildListDelegate(groupSettingsRows(children)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Puts each run of [SettingsRow]s in a [SettingsGroup], headed by the [SettingsSection] before it.
List<Widget> groupSettingsRows(List<Widget> children) {
  final grouped = <Widget>[];
  var run = <Widget>[];
  String? header;
  void flushHeader() {
    if (header != null) grouped.add(SettingsSection(header!));
    header = null;
  }

  void flush() {
    if (run.isEmpty) return;
    grouped.add(SettingsGroup(header: header, children: run));
    header = null;
    run = [];
  }

  for (final child in children) {
    if (child is SettingsRow) {
      run.add(child);
    } else if (child is SettingsSection) {
      flush();
      flushHeader();
      header = child.label;
    } else {
      flush();
      flushHeader();
      grouped.add(child);
    }
  }
  flush();
  flushHeader();
  return grouped;
}

/// Rows in one inset grouped panel, with a hairline between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.children, this.header, super.key});

  final List<Widget> children;
  final String? header;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return CupertinoListSection.insetGrouped(
      backgroundColor: palette.background,
      separatorColor: palette.border,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
      ),
      header: header == null
          ? null
          : Text(header!, style: TextStyle(color: palette.text2, fontSize: 13)),
      children: children,
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 20, 8),
      child: Text(label, style: TextStyle(color: palette.text2, fontSize: 13)),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.destructive = false,
    this.leading,
    super.key,
  });

  final IconData icon;

  /// In place of [icon] (an assistant's emoji).
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final foreground = destructive ? palette.red : palette.text;
    return CupertinoListTile(
      backgroundColor: palette.surface,
      backgroundColorActivated: palette.surface2,
      onTap: onTap,
      leading: leading ??
          Icon(icon, size: 22, color: destructive ? palette.red : palette.accent),
      title: Text(title, maxLines: 3, style: TextStyle(color: foreground)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 4, style: TextStyle(color: palette.text2)),
      additionalInfo: value == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(value!,
                  overflow: TextOverflow.ellipsis, style: TextStyle(color: palette.text2)),
            ),
      trailing: trailing ?? (onTap == null ? null : const CupertinoListTileChevron()),
    );
  }
}

class SettingsMessage extends StatelessWidget {
  const SettingsMessage(this.text, {this.error = false, super.key});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: error ? palette.red : palette.green,
            ),
      ),
    );
  }
}