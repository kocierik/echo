import 'package:echo_app/models/signed_in_device.dart';
import 'package:echo_app/screens/settings/devices_screen.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _connectedAppTests();

  final now = DateTime(2026, 10, 16, 10);

  Future<void> pump(WidgetTester tester, _FakeDevices api,
      {Future<void> Function()? signOut}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: DevicesScreen(
          api: api, signOut: signOut ?? () async {}, clock: () => now),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lists phones with this one first', (tester) async {
    final api = _FakeDevices([
      SignedInDevice(
          id: 'old',
          name: 'Pixel',
          current: false,
          platform: 'android',
          lastUsedAt: DateTime(2026, 10, 15, 20)),
      const SignedInDevice(
          id: 'me', name: 'iPhone', current: true, platform: 'ios'),
    ]);

    await pump(tester, api);

    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Last used Yesterday'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('iPhone')).dy,
      lessThan(tester.getTopLeft(find.text('Pixel')).dy),
    );
    expect(find.byKey(const Key('devices-sign-out')), findsOneWidget);
    expect(find.byKey(const Key('devices-revoke-old')), findsOneWidget);
  });

  testWidgets('revoke removes the row', (tester) async {
    final api = _FakeDevices([
      const SignedInDevice(id: 'me', name: 'iPhone', current: true),
      const SignedInDevice(id: 'old', name: 'Pixel', current: false),
    ]);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('devices-revoke-old')));
    await tester.pumpAndSettle();
    expect(find.text('Revoke Pixel?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    expect(api.revoked, ['old']);
    expect(find.text('Pixel'), findsNothing);
    expect(find.text('iPhone'), findsOneWidget);
  });

  testWidgets('sign out of this phone logs out', (tester) async {
    var signedOut = 0;
    final api = _FakeDevices(
        [const SignedInDevice(id: 'me', name: 'iPhone', current: true)]);
    await pump(tester, api, signOut: () async => signedOut++);

    await tester.tap(find.byKey(const Key('devices-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(signedOut, 1);
  });

  testWidgets('a failed load offers Retry', (tester) async {
    final api = _FakeDevices(
        [const SignedInDevice(id: 'me', name: 'iPhone', current: true)])
      ..failing = true;
    await pump(tester, api);
    expect(find.text('Server down'), findsOneWidget);

    api.failing = false;
    await tester.tap(find.byKey(const Key('devices-retry')));
    await tester.pumpAndSettle();
    expect(find.text('iPhone'), findsOneWidget);
  });

  testWidgets('keys made on the server are listed apart from the phones', (tester) async {
    final api = _FakeDevices([
      const SignedInDevice(id: 'me', name: 'iPhone 15 Pro', current: true, platform: 'ios'),
      const SignedInDevice(id: 'script', name: 'key-20261001-101500', current: false),
    ]);

    await pump(tester, api);

    expect(find.text('PHONES'), findsOneWidget);
    expect(find.text('OTHER KEYS'), findsOneWidget);
    expect(find.text('A key made on the server, for scripts'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('OTHER KEYS')).dy,
      greaterThan(tester.getTopLeft(find.text('iPhone 15 Pro')).dy),
    );
    expect(find.byKey(const Key('devices-revoke-script')), findsOneWidget);
  });
}

void _connectedAppTests() {
  final now = DateTime(2026, 10, 16, 10);

  Future<void> pump(WidgetTester tester, _FakeDevices api) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: DevicesScreen(api: api, signOut: () async {}, clock: () => now),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('connected apps have their own section', (tester) async {
    await pump(tester, _FakeDevices([
      const SignedInDevice(id: 'me', name: 'iPhone', current: true, platform: 'ios'),
      SignedInDevice(
        id: 'cc',
        name: 'Claude Code',
        current: false,
        scope: 'read',
        lastUsedAt: DateTime(2026, 10, 15, 20),
      ),
      const SignedInDevice(id: 'cu', name: 'Cursor', current: false, scope: 'read'),
    ]));

    expect(find.text('CONNECTED APPS'), findsOneWidget);
    // The one sign that an assistant is reading your memory, or a key you forgot
    expect(find.text('Last used Yesterday · read-only'), findsOneWidget);
    expect(find.text('Never used · read-only'), findsOneWidget);
    expect(find.text('OTHER KEYS'), findsNothing);
    expect(
      tester.getTopLeft(find.text('CONNECTED APPS')).dy,
      lessThan(tester.getTopLeft(find.text('Claude Code')).dy),
    );
  });

  testWidgets('connecting an assistant shows its key and setup once', (tester) async {
    final api = _FakeDevices([
      const SignedInDevice(id: 'me', name: 'iPhone', current: true, platform: 'ios'),
    ]);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('connect-app')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Claude Code'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(api.connected, ['Claude Code']);
    expect(find.text('secret-key-123'), findsOneWidget);
    expect(find.text('https://echo.test/mcp'), findsOneWidget);
    expect(find.textContaining('claude mcp add --transport http echo https://echo.test/mcp'),
        findsOneWidget);
    expect(find.textContaining('"Authorization": "Bearer secret-key-123"'), findsOneWidget);
    expect(find.text("You won't see this key again."), findsOneWidget);

    await tester.tap(find.text('Copy key'));
    await tester.pump();
    expect(copied, 'secret-key-123');
  });

  testWidgets('a connected app is revoked like a phone', (tester) async {
    final api = _FakeDevices([
      const SignedInDevice(id: 'me', name: 'iPhone', current: true, platform: 'ios'),
      const SignedInDevice(id: 'cc', name: 'Claude Code', current: false, scope: 'read'),
    ]);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('devices-revoke-cc')));
    await tester.pumpAndSettle();
    expect(find.text('It will lose access to your memory.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    expect(api.revoked, ['cc']);
  });
}

final class _FakeDevices implements DevicesApi {
  _FakeDevices(this.devices);

  List<SignedInDevice> devices;
  bool failing = false;
  final revoked = <String>[];

  @override
  Future<List<SignedInDevice>> listDevices() async {
    if (failing) {
      throw const ApiException(
        statusCode: 500,
        code: 'server',
        message: 'Server down',
        retryable: true,
      );
    }
    return List.of(devices);
  }

  @override
  Future<void> revokeDevice(String id) async => revoked.add(id);

  @override
  Future<void> signOutThisPhone() async {}

  final connected = <String>[];

  @override
  Future<ConnectedAppKey> connectApp(String name) async {
    connected.add(name);
    devices = [
      ...devices,
      SignedInDevice(id: 'app-${connected.length}', name: name, current: false, scope: 'read'),
    ];
    return ConnectedAppKey(
      id: 'app-${connected.length}',
      name: name,
      apiKey: 'secret-key-123',
      mcpUrl: 'https://echo.test/mcp',
    );
  }
}
