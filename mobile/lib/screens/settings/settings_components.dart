import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: children,
      ),
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
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: palette.text2,
              fontSize: 12,
            ),
      ),
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
    super.key,
  });

  final IconData icon;
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
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 66),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            minVerticalPadding: 8,
            leading: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (destructive ? palette.red : palette.blue)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                size: 20,
                color: destructive ? palette.red : palette.blue,
              ),
            ),
            title: Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: subtitle == null
                ? null
                : Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: palette.text2),
                  ),
            trailing: trailing ??
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (value != null)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          value!,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: palette.text2),
                        ),
                      ),
                    if (onTap != null)
                      Icon(Icons.chevron_right_rounded, color: palette.text2),
                  ],
                ),
            onTap: onTap,
          ),
        ),
        Divider(height: 1, indent: 72, color: palette.border),
      ],
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