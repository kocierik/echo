import 'package:flutter/foundation.dart';

import 'action_models.dart';

@immutable
final class ChatSource {
  const ChatSource({
    required this.label,
    required this.text,
    this.chunkId,
    this.url,
  });

  final String label;
  final String text;
  final String? chunkId;
  final Uri? url;
}

@immutable
final class ChatMessage {
  ChatMessage({
    required this.text,
    required this.isUser,
    this.index,
    this.feedback,
    this.timestamp,
    List<ChatSource> sources = const [],
    this.failed = false,
    this.isError = false,
    this.pendingAction,
    this.clientRequestId,
  }) : sources = List<ChatSource>.unmodifiable(sources);

  final String text;
  final bool isUser;
  final int? index;
  final String? feedback;
  final DateTime? timestamp;
  final List<ChatSource> sources;
  final bool failed;
  final bool isError;
  final PendingAction? pendingAction;

  /// For a user message: the id sent as `client_request_id`, reused on retry.
  final String? clientRequestId;

  ChatMessage copyWith({
    String? text,
    bool? isUser,
    int? index,
    Object? feedback = _unset,
    Object? timestamp = _unset,
    List<ChatSource>? sources,
    bool? failed,
    bool? isError,
    Object? pendingAction = _unset,
  }) {
    return ChatMessage(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      index: index ?? this.index,
      feedback:
          identical(feedback, _unset) ? this.feedback : feedback as String?,
      timestamp:
          identical(timestamp, _unset) ? this.timestamp : timestamp as DateTime?,
      sources: sources ?? this.sources,
      failed: failed ?? this.failed,
      isError: isError ?? this.isError,
      pendingAction: identical(pendingAction, _unset)
          ? this.pendingAction
          : pendingAction as PendingAction?,
      clientRequestId: clientRequestId,
    );
  }
}

const _unset = Object();
