import 'dart:convert';
import 'dart:io';

import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/api/build_defaults.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  _connectAppTests();

  _languageTests();

  test('signIn stores the issued key for the build server', () async {
    late http.Request sent;
    final store = _Store();
    final api = _api(store, (request) async {
      sent = request;
      return http.Response(
        jsonEncode({
          'api_key': 'phone-key',
          'device_id': 'd1',
          'user': {'id': 'u1', 'email': 'erik@example.com'},
        }),
        200,
      );
    });

    await api.signIn(email: 'erik@example.com', password: 'correct horse');

    expect(sent.url.toString(), '${BuildDefaults.serverUrl}/api/auth/login');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['email'], 'erik@example.com');
    expect(body['password'], 'correct horse');
    expect(body['platform'], anyOf('ios', 'android'));
    expect(body['device_name'], anyOf('iPhone', 'Android phone'));
    expect(sent.headers.containsKey('X-API-Key'), isFalse);
    expect(store.saved, (BuildDefaults.serverUrl, 'phone-key'));
  });

  test('signIn uses the server set in Settings when there is one', () async {
    late Uri url;
    final store = _Store(server: 'https://dev.echo.test');
    final api = _api(store, (request) async {
      url = request.url;
      return http.Response(
        '{"api_key":"k","device_id":"d","user":{"id":"u","email":"e@x.y"}}',
        200,
      );
    });

    await api.signIn(email: 'e@x.y', password: 'whatever');

    expect(url.toString(), 'https://dev.echo.test/api/auth/login');
    expect(store.saved?.$1, 'https://dev.echo.test');
  });

  test('signIn maps 401, 429, socket errors and 500 to SignInFailure', () async {
    Future<SignInException> failure(Future<http.Response> Function() answer) async {
      final api = _api(_Store(), (_) => answer());
      try {
        await api.signIn(email: 'erik@example.com', password: 'nope');
      } on SignInException catch (error) {
        return error;
      }
      fail('signIn did not throw');
    }

    final wrong = await failure(
        () async => http.Response('{"detail":"Wrong email or password."}', 401));
    expect(wrong.reason, SignInFailure.wrongCredentials);
    expect(wrong.message, 'Wrong email or password.');

    final limited = await failure(() async => http.Response(
        '{"detail":"Too many attempts. Try again in 15 minutes."}', 429));
    expect(limited.reason, SignInFailure.tooManyAttempts);
    expect(limited.message, 'Too many attempts. Try again in 15 minutes.');

    final offline = await failure(
        () async => throw const SocketException('Network is unreachable'));
    expect(offline.reason, SignInFailure.noConnection);
    expect(offline.message, 'No connection. Check your internet and try again.');

    final broken = await failure(() async => http.Response('oops', 500));
    expect(broken.reason, SignInFailure.server);
    expect(broken.message, 'Echo could not sign you in. Try again.');
  });

  test('a wrong password is not a revoked key', () async {
    final events = <void>[];
    final subscription = ApiClient.unauthorized.listen(events.add);
    addTearDown(subscription.cancel);
    final api = _api(_Store(),
        (_) async => http.Response('{"detail":"Wrong email or password."}', 401));

    await expectLater(
      api.signIn(email: 'erik@example.com', password: 'nope'),
      throwsA(isA<SignInException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });

  test('a 401 on a normal request is reported as unauthorized', () async {
    final events = <void>[];
    final subscription = ApiClient.unauthorized.listen(events.add);
    addTearDown(subscription.cancel);
    final api = _api(_Store(server: 'https://echo.test', key: 'old'),
        (_) async => http.Response('{"detail":"Invalid API key"}', 401));

    await expectLater(api.listDevices(), throwsA(anything));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
  });

  test('listDevices parses the server list', () async {
    final api = _api(_Store(server: 'https://echo.test', key: 'k'), (request) async {
      expect(request.url.path, '/api/auth/devices');
      return http.Response(
        jsonEncode([
          {
            'id': 'd1',
            'name': 'iPhone',
            'platform': 'ios',
            'created_at': '2026-10-16T08:00:00Z',
            'last_used_at': null,
            'current': true,
          },
          {
            'id': 'd2',
            'name': 'Android phone',
            'platform': 'android',
            'created_at': '2026-10-01T08:00:00Z',
            'last_used_at': '2026-10-15T20:00:00Z',
            'current': false,
          },
        ]),
        200,
      );
    });

    final devices = await api.listDevices();

    expect(devices.map((d) => d.name), ['iPhone', 'Android phone']);
    expect(devices.first.current, isTrue);
    expect(devices.first.lastUsedAt, isNull);
    expect(devices.last.lastUsedAt, DateTime.utc(2026, 10, 15, 20));
  });

  test('revokeDevice and signOutThisPhone call their endpoints', () async {
    final calls = <String>[];
    final api = _api(_Store(server: 'https://echo.test', key: 'k'), (request) async {
      calls.add('${request.method} ${request.url.path}');
      return http.Response('', 204);
    });

    await api.revokeDevice('d2');
    await api.signOutThisPhone();

    expect(calls, ['DELETE /api/auth/devices/d2', 'POST /api/auth/logout']);
  });

  test('signing out an already revoked phone counts as done', () async {
    final api = _api(_Store(server: 'https://echo.test', key: 'k'),
        (_) async => http.Response('{"detail":"Invalid API key"}', 401));

    await api.signOutThisPhone();
  });

  test('signing in again first signs out the old key', () async {
    final calls = <String>[];
    final store = _Store(server: 'https://echo.test', key: 'old');
    final api = _api(store, (request) async {
      calls.add('${request.method} ${request.url.path} ${request.headers['X-API-Key']}');
      if (request.url.path == '/api/auth/logout') return http.Response('', 204);
      return http.Response(
        '{"api_key":"new","device_id":"d","user":{"id":"u","email":"e@x.y"}}',
        200,
      );
    });

    await api.signIn(email: 'e@x.y', password: 'whatever');

    expect(calls, ['POST /api/auth/logout old', 'POST /api/auth/login null']);
    expect(store.saved?.$2, 'new');
  });

  test('a 401 for a key already replaced is not reported', () async {
    final events = <void>[];
    final subscription = ApiClient.unauthorized.listen(events.add);
    addTearDown(subscription.cancel);
    final store = _Store(server: 'https://echo.test', key: 'old');
    final api = _api(store, (_) async {
      // Signed in again while this request was on its way
      store.key = 'new';
      return http.Response('{"detail":"Invalid API key"}', 401);
    });

    await expectLater(api.listDevices(), throwsA(anything));
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });

  test('downloads and the chat stream report a 401 too', () async {
    final events = <void>[];
    final subscription = ApiClient.unauthorized.listen(events.add);
    addTearDown(subscription.cancel);
    final api = _api(_Store(server: 'https://echo.test', key: 'k'),
        (_) async => http.Response('{"detail":"Invalid API key"}', 401));

    await expectLater(api.exportData(), throwsA(anything));
    await expectLater(api.query('hi', onToken: (_) {}), throwsA(anything));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(2));
  });

  test('signIn names the phone by its model', () async {
    late http.Request sent;
    final api = _api(_Store(), (request) async {
      sent = request;
      return http.Response(
        '{"api_key":"k","device_id":"d","user":{"id":"u","email":"e@x.y"}}',
        200,
      );
    });

    await api.signIn(email: 'e@x.y', password: 'whatever', deviceName: 'iPhone 15 Pro');

    expect((jsonDecode(sent.body) as Map)['device_name'], 'iPhone 15 Pro');
  });

  test('register creates the account and keeps the phone signed in', () async {
    late http.Request sent;
    final store = _Store();
    final api = _api(store, (request) async {
      sent = request;
      return http.Response(
        '{"api_key":"new-account-key","device_id":"d","user":{"id":"u","email":"ada@example.com"}}',
        200,
      );
    });

    await api.register(email: ' ada@example.com ', password: 'correct horse', deviceName: 'Pixel 8');

    expect(sent.url.path, '/api/auth/register');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['email'], 'ada@example.com');
    expect(body['device_name'], 'Pixel 8');
    expect(store.saved?.$2, 'new-account-key');
  });

  test('register explains a taken email, a closed server and what to fix', () async {
    Future<SignInException> failure(int status, String detail) async {
      final api = _api(_Store(), (_) async => http.Response(jsonEncode({'detail': detail}), status));
      try {
        await api.register(email: 'ada@example.com', password: 'whatever long', deviceName: 'x');
      } on SignInException catch (error) {
        return error;
      }
      fail('register did not throw');
    }

    final taken = await failure(409, 'An account with this email already exists. Sign in instead.');
    expect(taken.reason, SignInFailure.accountExists);
    expect(taken.message, 'An account with this email already exists. Sign in instead.');

    final closed = await failure(403, 'Registration is closed.');
    expect(closed.reason, SignInFailure.registrationClosed);
    expect(closed.message, 'Registration is closed.');

    final invalid = await failure(400, 'Use at least 10 characters for the password.');
    expect(invalid.reason, SignInFailure.invalid);
    expect(invalid.message, 'Use at least 10 characters for the password.');

    final limited = await failure(429, 'Too many accounts from here. Try again in 60 minutes.');
    expect(limited.reason, SignInFailure.tooManyAttempts);
  });
}

void _languageTests() {
  test('register sends the language the user speaks', () async {
    late http.Request sent;
    final api = _api(_Store(), (request) async {
      sent = request;
      return http.Response(
        '{"api_key":"k","device_id":"d","user":{"id":"u","email":"ada@example.com"}}',
        200,
      );
    });

    await api.register(
      email: 'ada@example.com', password: 'whatever long', deviceName: 'x', language: 'it');

    expect((jsonDecode(sent.body) as Map)['language'], 'it');
  });

  test('me reads the account, setLanguage changes it', () async {
    final calls = <String>[];
    final api = _api(_Store(server: 'https://echo.test', key: 'k'), (request) async {
      calls.add('${request.method} ${request.url.path} ${request.body}');
      return http.Response('{"email":"ada@example.com","language":"it"}', 200);
    });

    final me = await api.me();
    final changed = await api.setLanguage('it');

    expect(me.language, 'it');
    expect(me.email, 'ada@example.com');
    expect(changed.language, 'it');
    expect(calls, ['GET /api/auth/me ', 'PATCH /api/auth/me {"language":"it"}']);
  });
}

void _connectAppTests() {
  test('connectApp asks for a read key and builds the MCP address', () async {
    late http.Request sent;
    final api = _api(_Store(server: 'https://echo.test', key: 'k'), (request) async {
      sent = request;
      return http.Response('{"id":"a1","name":"Claude Code","api_key":"rk"}', 201);
    });

    final app = await api.connectApp('Claude Code');

    expect(sent.url.path, '/api/auth/connected-apps');
    expect(jsonDecode(sent.body), {'name': 'Claude Code'});
    expect(app.apiKey, 'rk');
    expect(app.mcpUrl, 'https://echo.test/mcp');
  });

  test('without a server in Settings, the address is the built-in one', () async {
    final api = _api(_Store(key: 'k'), (request) async {
      return http.Response('{"id":"a1","name":"Cursor","api_key":"rk"}', 201);
    });

    expect((await api.connectApp('Cursor')).mcpUrl, '${BuildDefaults.serverUrl}/mcp');
  });
}

ApiService _api(_Store store, Future<http.Response> Function(http.Request) answer) {
  return ApiService(client: MockClient(answer), credentialStore: store);
}

final class _Store implements ApiCredentialStore {
  _Store({this.server = '', this.key});

  final String server;
  String? key;
  (String, String)? saved;

  @override
  Future<bool> get configured async => key != null;

  @override
  Future<Map<String, String>> get headers async => {
        'X-API-Key': key ?? '',
        'Content-Type': 'application/json',
      };

  @override
  Future<String> get serverUrl async => server;

  @override
  Future<void> clear() async {}

  @override
  Future<void> configure(String serverUrl, String apiKey) async {
    saved = (serverUrl, apiKey);
  }
}
