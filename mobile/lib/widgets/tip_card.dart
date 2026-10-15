import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// A one-time hint: shown until the user closes it or does what it suggests.
final class TipCard extends StatefulWidget {
  const TipCard({
    required this.tipKey,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.preferences,
    super.key,
  });

  /// Remembered as seen under "tip_seen_<tipKey>".
  final String tipKey;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Injected in tests; the app's shared preferences otherwise.
  final Future<SharedPreferences> Function()? preferences;

  static String seenKey(String tipKey) => 'tip_seen_$tipKey';

  @override
  State<TipCard> createState() => _TipCardState();
}

final class _TipCardState extends State<TipCard> {
  SharedPreferences? _preferences;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preferences = await (widget.preferences ?? SharedPreferences.getInstance)();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        _visible = !(preferences.getBool(TipCard.seenKey(widget.tipKey)) ?? false);
      });
    } catch (_) {
      // No preferences (tests, a broken store): no tip
    }
  }

  Future<void> _close() async {
    setState(() => _visible = false);
    await _preferences?.setBool(TipCard.seenKey(widget.tipKey), true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: Key('tip-${widget.tipKey}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: palette.blue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.lightbulb_outline_rounded, size: 18, color: palette.blue),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.text, style: textTheme.bodyMedium),
                if (widget.actionLabel != null && widget.onAction != null)
                  TextButton(
                    key: Key('tip-action-${widget.tipKey}'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () {
                      _close();
                      widget.onAction!();
                    },
                    child: Text(widget.actionLabel!),
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('tip-close-${widget.tipKey}'),
            tooltip: 'Close tip',
            icon: Icon(Icons.close_rounded, size: 18, color: palette.text2),
            onPressed: _close,
          ),
        ],
      ),
    );
  }
}
