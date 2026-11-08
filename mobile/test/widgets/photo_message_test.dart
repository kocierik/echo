import 'package:echo_app/models/chat_message.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/models/saved.dart';
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

  testWidgets('an answer that saved something has a chip opening it', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_app(MessageBubble(
      message: ChatMessage(
        text: 'Ho salvato la macchina: Via Roma 12, Milano.',
        isUser: false,
        saved: const [
          SavedChip(id: 'car', title: 'Your car', list: 'Your car', address: 'Via Roma 12'),
        ],
      ),
      onOpenSaved: (chip) => opened.add(chip.id),
    )));

    expect(find.text('Your car · Saved'), findsOneWidget);
    expect(find.text("Via Roma 12 · from the phone's location"), findsOneWidget);
    await tester.tap(find.byKey(const Key('saved-chip-car')));
    expect(opened, ['car']);
  });

  testWidgets('a photo answer: the photo large, then quick follow-ups', (tester) async {
    final now = DateTime(2026, 10, 20, 10, 15);
    final taps = <String>[];
    Widget bubble(DateTime? when) => _app(MessageBubble(
          message: ChatMessage(
            text: "È un avviso: l'ascensore è fermo fino a giovedì.",
            isUser: false,
            photoId: 'p1',
            timestamp: now,
            when: when,
          ),
          loadPhoto: _source,
          now: now,
          onTranslate: () => taps.add('translate'),
          onAskMore: () => taps.add('more'),
          onRemind: (at) => taps.add('remind $at'),
        ));

    await tester.pumpWidget(bubble(DateTime(2026, 10, 22, 9)));
    await tester.pump();
    expect(tester.getSize(find.byType(PhotoThumbnail)).height, greaterThanOrEqualTo(260));
    expect(find.textContaining("Echo's camera · "), findsOneWidget);
    await tester.tap(find.text('Translate it'));
    await tester.tap(find.text('Remind me Thursday'));
    await tester.tap(find.text('Ask more'));
    expect(taps, ['translate', 'remind ${DateTime(2026, 10, 22, 9)}', 'more']);

    // No date in the photo, or one already gone: no reminder to offer
    await tester.pumpWidget(bubble(null));
    expect(find.textContaining('Remind me'), findsNothing);
    await tester.pumpWidget(bubble(DateTime(2026, 10, 19, 9)));
    expect(find.textContaining('Remind me'), findsNothing);
    expect(find.text('Translate it'), findsOneWidget);
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

  testWidgets('a document can be added beside the camera', (tester) async {
    var added = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(ChatComposer(
      controller: controller,
      sending: false,
      onChanged: (_) {},
      onSend: () {},
      onCamera: () {},
      onDocument: () => added++,
    )));
    await tester.tap(find.byKey(const Key('chat-document')));

    expect(added, 1);
    expect(find.byKey(const Key('chat-camera')), findsOneWidget);
  });
}
