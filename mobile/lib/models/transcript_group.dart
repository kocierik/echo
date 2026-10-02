import 'package:flutter/foundation.dart';

import 'segment.dart';

@immutable
final class TranscriptGroup {
  TranscriptGroup({
    required this.label,
    required this.day,
    required List<RecentSegment> items,
  }) : items = List<RecentSegment>.unmodifiable(items);

  final String label;
  final DateTime day;
  final List<RecentSegment> items;
}