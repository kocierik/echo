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
      case 'voice_update':
        return const VoiceUpdateCommand();
      case 'get_location':
        final id = json['id'];
        final itemId = json['item_id'];
        if (id is! String) return null;
        return GetLocationCommand(id: id, itemId: itemId is String ? itemId : null);
      case 'person_brief':
        final personId = json['person_id'];
        final title = json['title'];
        final body = json['body'];
        if (personId is! String || title is! String || body is! String) return null;
        return PersonBriefCommand(personId: personId, title: title, body: body);
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

/// New answers in the thread with Echo (a routine ran): check them and notify.
final class VoiceUpdateCommand extends DeviceCommand {
  const VoiceUpdateCommand();
}

/// Where the phone is, for a thing the user is saving with its place (the car).
final class GetLocationCommand extends DeviceCommand {
  const GetLocationCommand({required this.id, this.itemId});

  final String id;

  /// The thing the place is for: it goes there later when it cannot be read now.
  final String? itemId;
}

/// Someone the user knows started talking: what to know about them, shown at once.
final class PersonBriefCommand extends DeviceCommand {
  const PersonBriefCommand({
    required this.personId,
    required this.title,
    required this.body,
  });

  final String personId;
  final String title;
  final String body;
}
