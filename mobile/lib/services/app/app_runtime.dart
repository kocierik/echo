import 'app_lifecycle_coordinator.dart';

abstract final class AppRuntime {
  static AppLifecycleCoordinator? _coordinator;

  static AppLifecycleCoordinator get coordinator {
    final value = _coordinator;
    if (value == null) {
      throw StateError('AppRuntime has not been initialized');
    }
    return value;
  }

  /// The coordinator, or null before [initialize] (tests build screens without one).
  static AppLifecycleCoordinator? get maybeCoordinator => _coordinator;

  static void initialize(AppLifecycleCoordinator coordinator) {
    _coordinator = coordinator;
  }
}