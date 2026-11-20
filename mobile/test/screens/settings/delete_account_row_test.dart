import 'package:echo_app/screens/settings/delete_account_row.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/app/session_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Step implements ActiveBleStopper, ApiCredentialsClearer, DeviceIdentityClearer,
    SessionCacheClearer {
  _Step(this.calls, this.name);
  final List<String> calls;
  final String name;
  @override
  Future<void> stop() async => calls.add(name);
  @override
  Future<void> clear() async => calls.add(name);
}

void main() {
  late List<String> calls;
  late List<String?> passwords;
  late SessionController session;
  late int loggedOut;
  Object? failure;

  setUp(() {
    calls = [];
    passwords = [];
    loggedOut = 0;
    failure = null;
    session = SessionController(
      bleStopper: _Step(calls, 'ble'),
      apiCredentials: _Step(calls, 'api'),
      deviceIdentity: _Step(calls, 'identity'),
      sessionCache: _Step(calls, 'cache'),
    );
  });

  Future<void> pump(WidgetTester tester, {bool withGoogle = false}) =>
      tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: DeleteAccountRow(
            sessionController: session,
            deleteAccount: (password) async {
              passwords.add(password);
              final error = failure;
              if (error != null) throw error;
            },
            onLoggedOut: () => loggedOut++,
            withGoogle: withGoogle,
          ),
        ),
      ));

  Future<void> confirmWith(WidgetTester tester, String password) async {
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('delete-account-password')), password);
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('a wrong password deletes nothing and says so', (tester) async {
    failure = const ApiException(
      statusCode: 403, code: 'forbidden', message: 'Wrong password.', retryable: false,
    );
    await pump(tester);

    await confirmWith(tester, 'not it');

    expect(passwords, ['not it']);
    expect(find.text('Wrong password.'), findsOneWidget);
    expect(calls, isEmpty);
    expect(loggedOut, 0);
  });

  testWidgets('deleted: the phone is signed out', (tester) async {
    await pump(tester);

    await confirmWith(tester, 'correct horse');

    expect(passwords, ['correct horse']);
    expect(calls, containsAll(['api', 'identity', 'cache']));
    expect(loggedOut, 1);
  });

  testWidgets('an account made with Google: Google confirms, no password asked', (tester) async {
    await pump(tester, withGoogle: true);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-account-password')), findsNothing);
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pumpAndSettle();

    expect(passwords, [null]);
    expect(loggedOut, 1);
  });

  testWidgets('backing out of Google deletes nothing and leaves the dialog', (tester) async {
    failure = const DeletionCancelled();
    await pump(tester, withGoogle: true);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-account-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete-account-confirm')), findsOneWidget);
    expect(calls, isEmpty);
    expect(loggedOut, 0);
  });

  testWidgets('cancel asks nothing of the server', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(passwords, isEmpty);
    expect(loggedOut, 0);
  });
}
