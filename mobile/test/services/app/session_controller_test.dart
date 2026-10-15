import 'package:echo_app/services/app/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logout stops BLE before clearing every local store', () async {
    final calls = <String>[];
    final controller = _controller(calls);
    addTearDown(controller.dispose);

    await controller.logout();

    expect(calls, ['ble', 'api', 'identity', 'cache']);
    expect(controller.state.loggedOut, isTrue);
    expect(controller.state.error, isNull);
  });

  test('logout emits loggingOut before loggedOut', () async {
    final calls = <String>[];
    final controller = _controller(calls);
    final states = <SessionState>[];
    final subscription = controller.stream.listen(states.add);
    addTearDown(() async {
      await subscription.cancel();
      await controller.dispose();
    });

    await controller.logout();
    // Stream events are delivered asynchronously: let the last one arrive
    await Future<void>.delayed(Duration.zero);

    expect(states.map((state) => state.status), [
      SessionStatus.loggingOut,
      SessionStatus.loggedOut,
    ]);
  });

  test('attempts API, identity, and cache clear when one cleanup fails',
      () async {
    final calls = <String>[];
    final controller = _controller(
      calls,
      identityError: StateError('identity unavailable'),
    );
    addTearDown(controller.dispose);

    await controller.logout();

    expect(calls, ['ble', 'api', 'identity', 'cache']);
    expect(controller.state.cleanupFailed, isTrue);
    expect(controller.state.error, contains('identity unavailable'));
  });

  test('attempts API clear even when BLE stop fails', () async {
    final calls = <String>[];
    final controller = _controller(
      calls,
      bleError: StateError('disconnect failed'),
      apiError: StateError('secure delete failed'),
    );
    addTearDown(controller.dispose);

    await controller.logout();

    expect(calls, ['ble', 'api', 'identity', 'cache']);
    expect(controller.state.cleanupFailed, isTrue);
    expect(controller.state.error, contains('disconnect failed'));
    expect(controller.state.error, contains('secure delete failed'));
  });
}

SessionController _controller(
  List<String> calls, {
  Object? bleError,
  Object? apiError,
  Object? identityError,
  Object? cacheError,
}) {
  return SessionController(
    bleStopper: _BleStopper(calls, bleError),
    apiCredentials: _Clearer(calls, 'api', apiError),
    deviceIdentity: _Clearer(calls, 'identity', identityError),
    sessionCache: _Clearer(calls, 'cache', cacheError),
  );
}

final class _BleStopper implements ActiveBleStopper {
  _BleStopper(this.calls, this.error);

  final List<String> calls;
  final Object? error;

  @override
  Future<void> stop() async {
    calls.add('ble');
    if (error != null) throw error!;
  }
}

final class _Clearer
    implements
        ApiCredentialsClearer,
        DeviceIdentityClearer,
        SessionCacheClearer {
  _Clearer(this.calls, this.name, this.error);

  final List<String> calls;
  final String name;
  final Object? error;

  @override
  Future<void> clear() async {
    calls.add(name);
    if (error != null) throw error!;
  }
}
