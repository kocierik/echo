import 'package:echo_app/models/chat_message.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/chat_composer.dart';
import 'package:echo_app/widgets/message_bubble.dart';
import 'package:echo_app/widgets/photo_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

Future<PhotoImageSource> _source(String id) async => PhotoImageSource(
      url: Uri.parse('https://echo.test/api/photos/$id/image'),
      headers: const {'X-API-Key': 'k'},
    );

void main() {
  testWidgets('an answer with a photo shows it', (tester) async {
    await tester.pumpWidget(_app(MessageBubble(
      message: ChatMessage(text: 'È un ficus.', isUser: false, photoId: 'p1'),
      loadPhoto: _source,
    )));
    await tester.pump();

    expect(find.byType(PhotoThumbnail), findsOneWidget);
    expect(find.byKey(const Key('photo-p1')), findsOneWidget);
    expect(find.text('È un ficus.'), findsOneWidget);
  });

  testWidgets('no photo without a loader or on the question', (tester) async {
    await tester.pumpWidget(_app(Column(children: [
      MessageBubble(
        message: ChatMessage(text: 'È un ficus.', isUser: false, photoId: 'p1'),
      ),
      MessageBubble(
        message:
            ChatMessage(text: 'Che pianta è?', isUser: true, photoId: 'p1'),
        loadPhoto: _source,
      ),
    ])));
    await tester.pump();

    expect(find.byType(PhotoThumbnail), findsNothing);
  });

  testWidgets('the camera button is there only with a camera action',
      (tester) async {
    var taken = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Widget composer({VoidCallback? onCamera, bool sending = false}) =>
        _app(ChatComposer(
          controller: controller,
          sending: sending,
          onChanged: (_) {},
          onSend: () {},
          onCamera: onCamera,
        ));

    await tester.pumpWidget(composer());
    expect(find.byKey(const Key('chat-camera')), findsNothing);

    await tester.pumpWidget(composer(onCamera: () => taken++));
    await tester.tap(find.byKey(const Key('chat-camera')));
    expect(taken, 1);

    await tester.pumpWidget(composer(onCamera: () => taken++, sending: true));
    await tester.tap(find.byKey(const Key('chat-camera')));
    expect(taken, 1); // disabled while Echo is answering
  });
}
