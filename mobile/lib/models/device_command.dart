/// A command from the server for this phone or its wearable (`GET /device/commands`).
sealed class DeviceCommand {
  const DeviceCommand();

  /// Null for a malformed command, or a kind this version of the app does not know.
  static DeviceCommand? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    switch (json['type']) {
      case 'take_photo':
        final photoId = json['photo_id'];
        return photoId is String ? TakePhotoCommand(photoId) : null;
      case 'phone_action':
        final id = json['id'];
        final tool = json['tool'];
        final arguments = json['arguments'];
        if (id is! String || tool is! String) return null;
        return PhoneActionCommand(
          id: id,
          tool: tool,
          arguments: arguments is Map<String, dynamic> ? arguments : const {},
        );
      default:
        return null;
    }
  }
}

/// Take a photo with the wearable: a voice request ("Echo, what is this?").
final class TakePhotoCommand extends DeviceCommand {
  const TakePhotoCommand(this.photoId);

  final String photoId;
}

/// Run a Reminders or Calendar tool on this iPhone, then post what it did.
final class PhoneActionCommand extends DeviceCommand {
  const PhoneActionCommand({
    required this.id,
    required this.tool,
    required this.arguments,
  });

  final String id;
  final String tool;
  final Map<String, dynamic> arguments;
}
