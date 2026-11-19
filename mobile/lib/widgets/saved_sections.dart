import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../models/saved.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'echo_grouped.dart';
import 'panel.dart';
import 'photo_thumbnail.dart';

/// Today's row to Saved: how many things, and the list one was last saved in.
final class SavedRow extends StatelessWidget {
  const SavedRow({required this.total, required this.onOpen, this.latestList, super.key});

  final int total;
  final String? latestList;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Panel(
      key: const Key('saved-row'),
      onTap: onOpen,
      child: Row(
        children: [
          Icon(CupertinoIcons.bookmark, color: palette.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved', style: textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  [
                    total == 1 ? '1 thing' : '$total things',
                    if (latestList != null) 'latest in $latestList',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Icon(CupertinoIcons.chevron_forward, size: 18, color: palette.text2),
        ],
      ),
    );
  }
}

/// A thing kept with its place (the car): where, since when, the way there, "Found it".
final class SavedPlaceCard extends StatelessWidget {
  const SavedPlaceCard({
    required this.item,
    required this.now,
    required this.onDirections,
    required this.onFound,
    required this.onOpen,
    this.distance,
    this.busy = false,
    super.key,
  });

  final SavedItem item;
  final DateTime now;
  final VoidCallback onDirections;
  final VoidCallback onFound;
  final VoidCallback onOpen;

  /// "650 m away", worked out on the phone when it may already read its position.
  final String? distance;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final place = item.place!;
    final note = keepNote(latestOnly: item.latestOnly, keepDays: item.keepDays);
    return Panel(
      key: Key('saved-place-${item.id}'),
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(item.list, style: textTheme.titleLarge)),
              Text(sinceLabel(item.savedAt, now), style: textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            place.address ?? 'A place without an address',
            style: textTheme.bodyLarge?.copyWith(height: 1.4),
          ),
          if (item.fieldsLine case final fields?)
            Text(fields, style: textTheme.bodyLarge?.copyWith(height: 1.4)),
          if (distance != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(distance!, style: textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: Key('saved-directions-${item.id}'),
                  onPressed: onDirections,
                  child: const Text('Directions'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: Key('saved-found-${item.id}'),
                  onPressed: busy ? null : onFound,
                  child: const Text('Found it'),
                ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note, style: textTheme.bodySmall?.copyWith(color: palette.text2)),
          ],
        ],
      ),
    );
  }
}

/// A list of the Saved page: a grid of photos when its things have them, rows
/// otherwise; "All N" when there are more than shown.
final class SavedListPanel extends StatelessWidget {
  const SavedListPanel({
    required this.list,
    required this.now,
    required this.onOpenItem,
    required this.onAll,
    this.loadPhoto,
    super.key,
  });

  final SavedListSummary list;
  final DateTime now;
  final ValueChanged<SavedItem> onOpenItem;
  final VoidCallback onAll;
  final PhotoSourceLoader? loadPhoto;

  static const gridShown = 3;
  static const rowsShown = 4;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final grid = loadPhoto != null && list.items.any((i) => i.photoId != null);
    final shown = list.items.take(grid ? gridShown : rowsShown).toList();
    final more = list.count > shown.length;
    return EchoGroup(
      key: Key('saved-list-${list.id}'),
      header: more ? list.name : '${list.name} · ${list.count}',
      children: [
        if (grid)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, item) in shown.indexed) ...[
                  if (index > 0) const SizedBox(width: 8),
                  Expanded(child: _Tile(item: item, now: now, loadPhoto: loadPhoto!, onTap: onOpenItem)),
                ],
                for (var i = shown.length; i < gridShown; i++) ...[
                  const SizedBox(width: 8),
                  const Expanded(child: SizedBox()),
                ],
              ],
            ),
          )
        else
          for (final item in shown)
            SavedItemRow(item: item, now: now, onTap: () => onOpenItem(item)),
        if (more)
          InkWell(
            key: Key('saved-all-${list.id}'),
            onTap: onAll,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('All ${list.count}',
                          style: TextStyle(color: palette.accent, fontSize: 16)),
                    ),
                    Icon(CupertinoIcons.chevron_forward, size: 18, color: palette.text2),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A photo of the grid, its title and its moment.
final class _Tile extends StatelessWidget {
  const _Tile({required this.item, required this.now, required this.loadPhoto, required this.onTap});

  final SavedItem item;
  final DateTime now;
  final PhotoSourceLoader loadPhoto;
  final ValueChanged<SavedItem> onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: item.title,
      excludeSemantics: true,
      child: InkWell(
        key: Key('saved-item-${item.id}'),
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
        onTap: () => onTap(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.tileRadius),
              child: SizedBox(
                height: 104,
                width: double.infinity,
                child: item.photoId == null
                    ? ColoredBox(
                        color: palette.surface2,
                        child: Icon(CupertinoIcons.bookmark, color: palette.text2),
                      )
                    : IgnorePointer(
                        child: PhotoThumbnail(
                          photoId: item.photoId!,
                          loadSource: loadPhoto,
                          height: 104,
                          padding: EdgeInsets.zero,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.labelLarge),
            Text(
              _moment(item, now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// "With Marco, Sat", "Desk drawer, the study · 3 days ago".
String _moment(SavedItem item, DateTime now) {
  final when = _ago(item.savedAt, now);
  final about = item.subtitle;
  return about == null ? when : '$about · $when';
}

String _ago(DateTime at, DateTime now) {
  final days = dayOf(now).difference(dayOf(at)).inDays;
  if (days == 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  return shortDate(at.toLocal());
}

/// A thing as a row: its title, and what it is about with when.
final class SavedItemRow extends StatelessWidget {
  const SavedItemRow({required this.item, required this.now, required this.onTap, super.key});

  final SavedItem item;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: Key('saved-item-${item.id}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: textTheme.titleSmall),
              const SizedBox(height: 3),
              Text(
                _moment(item, now),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A list with amounts: this week's total ("€184.30 this week · 7 things").
final class SavedSumCard extends StatelessWidget {
  const SavedSumCard({required this.list, required this.onOpen, super.key});

  final SavedListSummary list;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return EchoGroup(
      key: Key('saved-sum-${list.id}'),
      children: [
        InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(list.name, style: textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(list.weekSum!.label(), style: textTheme.bodyLarge),
                    ],
                  ),
                ),
                Icon(CupertinoIcons.chevron_forward, size: 18, color: palette.text2),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
