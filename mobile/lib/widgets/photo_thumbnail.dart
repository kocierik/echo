import 'package:flutter/material.dart';

import '../models/photo.dart';
import '../theme/app_theme.dart';

typedef PhotoSourceLoader = Future<PhotoImageSource> Function(String photoId);

/// A photo from the wearable camera in a chat message; a tap opens it full screen.
final class PhotoThumbnail extends StatelessWidget {
  const PhotoThumbnail({
    required this.photoId,
    required this.loadSource,
    this.height = 200,
    this.caption,
    this.padding = const EdgeInsets.only(top: 8),
    super.key,
  });

  final String photoId;
  final PhotoSourceLoader loadSource;
  final double height;

  /// "Echo's camera · 10:15", on the photo's corner.
  final String? caption;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final image = Padding(
      padding: padding,
      child: FutureBuilder<PhotoImageSource>(
        future: loadSource(photoId),
        builder: (context, snapshot) {
          final source = snapshot.data;
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: source == null
                  ? ColoredBox(color: palette.surface2)
                  : Semantics(
                      button: true,
                      label: 'Photo from Echo. Open full screen',
                      child: GestureDetector(
                        key: Key('photo-$photoId'),
                        onTap: () => _open(context, source),
                        child: Hero(
                          tag: 'photo-$photoId',
                          child: _image(source, palette, BoxFit.cover),
                        ),
                      ),
                    ),
            ),
          );
        },
      ),
    );
    if (caption == null) return image;
    return Stack(
      children: [
        image,
        Positioned(
          left: 12,
          bottom: 12,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: palette.bar,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                caption!,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: palette.text),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _image(PhotoImageSource source, EchoPalette palette, BoxFit fit) {
    return Image.network(
      source.url.toString(),
      headers: source.headers,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => ColoredBox(
        color: palette.surface2,
        child: Center(
          child: Icon(Icons.broken_image_outlined, color: palette.text2),
        ),
      ),
    );
  }

  void _open(BuildContext context, PhotoImageSource source) {
    final palette = EchoPalette.of(context);
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Photo'),
          ),
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Hero(
                tag: 'photo-$photoId',
                child: _image(source, palette, BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
