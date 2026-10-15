import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The system share sheet, behind an interface for tests.
abstract interface class Sharing {
  Future<void> shareText(String text, {String? subject});

  /// Writes [contents] to a temporary file named [fileName] and shares it.
  Future<void> shareFile(String fileName, List<int> contents, {String? subject});
}

final class SystemSharing implements Sharing {
  const SystemSharing();

  @override
  Future<void> shareText(String text, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  @override
  Future<void> shareFile(String fileName, List<int> contents, {String? subject}) async {
    final folder = await getTemporaryDirectory();
    final file = File('${folder.path}/$fileName');
    await file.writeAsBytes(contents, flush: true);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: subject),
      );
    } finally {
      // The export holds the whole memory: no copy left behind
      if (await file.exists()) await file.delete();
    }
  }
}
