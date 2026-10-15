import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkType { wifi, mobile, ethernet, none, other }

final class NetworkPolicy {
  NetworkPolicy({bool allowCellular = true}) : _allowCellular = allowCellular;

  bool _allowCellular;
  bool get allowCellular => _allowCellular;

  void setAllowCellular(bool value) {
    _allowCellular = value;
  }

  bool canUpload(Set<NetworkType> types) {
    if (types.contains(NetworkType.wifi) ||
        types.contains(NetworkType.ethernet)) {
      return true;
    }
    return _allowCellular && types.contains(NetworkType.mobile);
  }
}

abstract interface class NetworkAccess {
  Future<Set<NetworkType>> currentTypes();
}

typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();

final class ConnectivityNetworkAccess implements NetworkAccess {
  ConnectivityNetworkAccess({
    Connectivity? connectivity,
    ConnectivityCheck? checkConnectivity,
  }) : _checkConnectivity =
            checkConnectivity ?? (connectivity ?? Connectivity()).checkConnectivity;

  final ConnectivityCheck _checkConnectivity;

  @override
  Future<Set<NetworkType>> currentTypes() async {
    final results = await _checkConnectivity();
    return results.map(_mapResult).toSet();
  }

  static NetworkType _mapResult(ConnectivityResult result) {
    return switch (result) {
      ConnectivityResult.wifi => NetworkType.wifi,
      ConnectivityResult.mobile => NetworkType.mobile,
      ConnectivityResult.ethernet => NetworkType.ethernet,
      ConnectivityResult.none => NetworkType.none,
      _ => NetworkType.other,
    };
  }
}