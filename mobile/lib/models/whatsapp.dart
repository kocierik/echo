import 'package:flutter/foundation.dart';

/// The user's WhatsApp as the server sees it (`GET /api/whatsapp`).
@immutable
final class WhatsAppStatus {
  const WhatsAppStatus({required this.available, required this.state, this.phone});

  factory WhatsAppStatus.fromJson(Map<String, dynamic> json) => WhatsAppStatus(
        available: json['available'] as bool? ?? false,
        state: json['state'] as String? ?? 'unlinked',
        phone: json['phone'] as String?,
      );

  /// False on a server without the WhatsApp bridge: the app shows nothing about it.
  final bool available;

  /// "unlinked", "linking", "linked" or "unreachable".
  final String state;

  /// The linked number ("+39333…").
  final String? phone;

  bool get isLinked => state == 'linked';
}
