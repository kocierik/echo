import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkPolicy', () {
    test('default policy allows wifi, mobile, and ethernet', () {
      final policy = NetworkPolicy();

      expect(policy.canUpload({NetworkType.wifi}), isTrue);
      expect(policy.canUpload({NetworkType.mobile}), isTrue);
      expect(policy.canUpload({NetworkType.ethernet}), isTrue);
    });

    test('wifi-only policy rejects mobile but allows wifi and ethernet', () {
      final policy = NetworkPolicy(allowCellular: false);

      expect(policy.canUpload({NetworkType.mobile}), isFalse);
      expect(policy.canUpload({NetworkType.wifi}), isTrue);
      expect(policy.canUpload({NetworkType.ethernet}), isTrue);
    });

    test('rejects none and an empty connectivity result', () {
      final policy = NetworkPolicy();

      expect(policy.canUpload({NetworkType.none}), isFalse);
      expect(policy.canUpload(<NetworkType>{}), isFalse);
    });

    test('runtime cellular changes affect the same policy object', () {
      final policy = NetworkPolicy();
      final original = policy;

      policy.setAllowCellular(false);

      expect(identical(policy, original), isTrue);
      expect(policy.allowCellular, isFalse);
      expect(policy.canUpload({NetworkType.mobile}), isFalse);

      policy.setAllowCellular(true);
      expect(policy.canUpload({NetworkType.mobile}), isTrue);
    });
  });

  test('ConnectivityNetworkAccess checks and maps connectivity on every call',
      () async {
    var calls = 0;
    final access = ConnectivityNetworkAccess(
      checkConnectivity: () async {
        calls++;
        return calls == 1
            ? [ConnectivityResult.wifi, ConnectivityResult.vpn]
            : [ConnectivityResult.mobile];
      },
    );

    expect(
      await access.currentTypes(),
      {NetworkType.wifi, NetworkType.other},
    );
    expect(await access.currentTypes(), {NetworkType.mobile});
    expect(calls, 2);
  });
}
