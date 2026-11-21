import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// The phone's own camera, or a photo from its library (Ask's + menu).
abstract interface class PhoneCamera {
  /// A JPEG, or null when the user closed the camera (or the library) without a photo.
  Future<Uint8List?> capture({bool fromLibrary = false});
}

/// The system camera (or photo picker) through image_picker: no CAMERA permission on Android (the camera
/// app takes the photo), NSCameraUsageDescription on iOS. Small enough for the server's
/// 1 MB limit: 1280 px on the long side, quality 75.
final class ImagePickerPhoneCamera implements PhoneCamera {
  ImagePickerPhoneCamera({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> capture({bool fromLibrary = false}) async {
    final photo = await _picker.pickImage(
      source: fromLibrary ? ImageSource.gallery : ImageSource.camera,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 75,
    );
    return photo?.readAsBytes();
  }
}
