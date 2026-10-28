import 'package:echo_app/models/whatsapp.dart';
import 'package:echo_app/screens/settings/whatsapp_screen.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/whatsapp_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _WhatsApp implements WhatsAppApi {
  WhatsAppStatus status = const WhatsAppStatus(available: true, state: 'unlinked');
  final linked = <String>[];
  int unlinks = 0;
  bool failLink = false;
  int? linkStatus;
  int failChecks = 0;

  @override
  Future<WhatsAppStatus> getWhatsApp() async {
    if (failChecks > 0) {
      failChecks--;
      throw Exception('offline');
    }
    return status;
  }

  @override
  Future<String> linkWhatsApp(String phone) async {
    if (failLink) throw Exception('bad number');
    if (linkStatus != null) {
      throw ApiException(
        statusCode: linkStatus, code: 'http', message: 'server', retryable: false);
    }
    linked.add(phone);
    status = const WhatsAppStatus(available: true, state: 'linking');
    return 'ABCD1234';
  }

  @override
  Future<void> unlinkWhatsApp() async {
    unlinks++;
    status = const WhatsAppStatus(available: true, state: 'unlinked');
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _WhatsApp api) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: WhatsAppScreen(api: api, pollInterval: const Duration(seconds: 1)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('it says what it is, then links with a code and waits for WhatsApp',
      (tester) async {
    final api = _WhatsApp();
    await pump(tester, api);

    expect(find.textContaining('may block the number'), findsOneWidget);
    expect(find.textContaining('only in memory'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '+39 333 000 0000');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    expect(api.linked, ['+39 333 000 0000']);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.textContaining('Link with phone number instead'), findsOneWidget);

    api.status = const WhatsAppStatus(available: true, state: 'linked', phone: '+393330000000');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Linked: +393330000000'), findsOneWidget);
    expect(find.byKey(const Key('whatsapp-code')), findsNothing);
  });

  testWidgets('a code never typed gives the form back', (tester) async {
    final api = _WhatsApp();
    await pump(tester, api);
    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '+39 333 000 0000');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    // The bridge gave the link up
    api.status = const WhatsAppStatus(available: true, state: 'unlinked');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('whatsapp-code')), findsNothing);
    expect(find.byKey(const Key('whatsapp-phone')), findsOneWidget);
    expect(find.textContaining('The code expired'), findsOneWidget);
  });

  testWidgets('a failed check keeps checking', (tester) async {
    final api = _WhatsApp();
    await pump(tester, api);
    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '+39 333 000 0000');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    api.failChecks = 1;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    api.status = const WhatsAppStatus(available: true, state: 'linked', phone: '+393330000000');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Linked: +393330000000'), findsOneWidget);
  });

  testWidgets('a number without its country code is not sent', (tester) async {
    final api = _WhatsApp();
    await pump(tester, api);

    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '333 000 0000');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    expect(api.linked, isEmpty);
    expect(find.textContaining('country code'), findsOneWidget);
  });

  testWidgets('WhatsApp not answering in time says so', (tester) async {
    final api = _WhatsApp()..linkStatus = 504;
    await pump(tester, api);

    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '+39 333 000 0000');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not answer in time'), findsOneWidget);
  });

  testWidgets('a number WhatsApp refused says it may be blocked', (tester) async {
    final api = _WhatsApp()..status = const WhatsAppStatus(available: true, state: 'blocked');
    await pump(tester, api);

    expect(find.textContaining('may be blocked'), findsOneWidget);
    expect(find.byKey(const Key('whatsapp-phone')), findsOneWidget);
  });

  testWidgets('a number that does not work says so', (tester) async {
    final api = _WhatsApp()..failLink = true;
    await pump(tester, api);

    await tester.enterText(find.byKey(const Key('whatsapp-phone')), '+39 333');
    await tester.tap(find.byKey(const Key('whatsapp-link')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not get a code'), findsOneWidget);
  });

  testWidgets('unlinking asks first', (tester) async {
    final api = _WhatsApp()
      ..status = const WhatsAppStatus(available: true, state: 'linked', phone: '+393330000000');
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('whatsapp-unlink')));
    await tester.pumpAndSettle();
    expect(api.unlinks, 0);
    await tester.tap(find.text('Unlink').last);
    await tester.pumpAndSettle();

    expect(api.unlinks, 1);
    expect(find.byKey(const Key('whatsapp-phone')), findsOneWidget);
  });

  testWidgets('a bridge out of reach says so', (tester) async {
    final api = _WhatsApp()
      ..status = const WhatsAppStatus(available: true, state: 'unreachable');
    await pump(tester, api);

    expect(find.textContaining('cannot reach WhatsApp'), findsOneWidget);
  });

  test('the status reads the server', () {
    final status = WhatsAppStatus.fromJson(
      const {'available': true, 'state': 'linked', 'phone': '+39333'},
    );
    expect((status.available, status.state, status.phone), (true, 'linked', '+39333'));
    expect(status.isLinked, isTrue);
  });
}
