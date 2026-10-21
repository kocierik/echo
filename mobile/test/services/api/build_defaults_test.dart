import 'package:echo_app/services/api/build_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a test account needs both its email and password', () {
    expect(BuildDefaults.devAccountFrom('', ''), isNull);
    expect(BuildDefaults.devAccountFrom('dev@echo.test', ''), isNull);
    expect(
      BuildDefaults.devAccountFrom(' dev@echo.test ', 'pw'),
      (email: 'dev@echo.test', password: 'pw'),
    );
  });

  test('no test account unless one is passed at build time', () {
    // flutter test passes no ECHO_DEV_* defines
    expect(BuildDefaults.devAccount(), isNull);
  });
}
