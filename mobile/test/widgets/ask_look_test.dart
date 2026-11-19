import 'package:echo_app/models/chat_message.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/chat_composer.dart';
import 'package:echo_app/widgets/echo_nav_bar.dart';
import 'package:echo_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

Color? _fillBehind(WidgetTester tester, Finder inner) {
  for (final w in tester.widgetList<Widget>(
      find.ancestor(of: inner, matching: find.byWidgetPredicate((w) => w is DecoratedBox || w is Material)))) {
    if (w is DecoratedBox) {
      final c = (w.decoration as BoxDecoration).color;
      if (c != null) return c;
    }
    if (w is Material && w.color != null) return w.color;
  }
  return null;
}

void main() {
  late EchoPalette palette;
  setUp(() => palette = AppTheme.light.extension<EchoPalette>()!);

  testWidgets('your question is on surface2, Echo answers on surface', (tester) async {
    await tester.pumpWidget(_app(Column(children: [
      MessageBubble(message: ChatMessage(text: 'mine', isUser: true)),
      MessageBubble(message: ChatMessage(text: 'theirs', isUser: false)),
    ])));
    expect(_fillBehind(tester, find.text('mine')), palette.surface2);
    expect(_fillBehind(tester, find.text('theirs')), palette.surface);
  });

  testWidgets('the input bar is on surface and Send is the accent', (tester) async {
    final c = TextEditingController(text: 'hi');
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(ChatComposer(
      controller: c,
      sending: false,
      onChanged: (_) {},
      onSend: () {},
    )));
    expect(tester.widget<Material>(find.byKey(const Key('chat-composer'))).color, palette.surface);
    final send = tester.widget<IconButton>(find.descendant(of: find.byKey(const Key('chat-send')), matching: find.byType(IconButton)));
    expect(send.style!.backgroundColor!.resolve({}), palette.accent);
  });

  testWidgets('the Ask button is an accent fill with an onAccent icon, at rest too',
      (tester) async {
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.bottomCenter,
      child: EchoNavBar(selectedIndex: 0, onSelect: (_) {}, onAskHold: (_) {}),
    )));
    final button = find.byKey(const Key('echo-ask-button'));
    final disc = tester.widget<AnimatedContainer>(
        find.descendant(of: button, matching: find.byType(AnimatedContainer)).first);
    expect((disc.decoration as BoxDecoration).color, palette.accent);
    final icon = tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon)));
    expect(icon.color, palette.onAccent);
  });
}
