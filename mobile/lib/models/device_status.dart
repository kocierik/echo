enum DeviceConnectionState {
  unpaired,
  bluetoothOff,
  scanning,
  connecting,
  bonding,
  listening,
  muted,
  reconnecting,
  offline,
  error,
}

final class DeviceStatus {
  const DeviceStatus({
    required this.connectionState,
    this.batteryPercent,
    this.protocolVersion,
    this.firmwareVersion,
    this.bufferCount = 0,
    this.bufferBytes = 0,
    this.droppedSegments = 0,
    this.overflowed = false,
    this.error,
  });

  static const Object _unset = Object();

  final DeviceConnectionState connectionState;
  final int? batteryPercent;
  final int? protocolVersion;
  final String? firmwareVersion;
  final int bufferCount;
  final int bufferBytes;
  final int droppedSegments;
  final bool overflowed;
  final String? error;

  DeviceStatus copyWith({
    DeviceConnectionState? connectionState,
    Object? batteryPercent = _unset,
    Object? protocolVersion = _unset,
    Object? firmwareVersion = _unset,
    int? bufferCount,
    int? bufferBytes,
    int? droppedSegments,
    bool? overflowed,
    Object? error = _unset,
  }) {
    return DeviceStatus(
      connectionState: connectionState ?? this.connectionState,
      batteryPercent: identical(batteryPercent, _unset)
          ? this.batteryPercent
          : batteryPercent as int?,
        protocolVersion: identical(protocolVersion, _unset)
          ? this.protocolVersion
          : protocolVersion as int?,
        firmwareVersion: identical(firmwareVersion, _unset)
          ? this.firmwareVersion
          : firmwareVersion as String?,
      bufferCount: bufferCount ?? this.bufferCount,
      bufferBytes: bufferBytes ?? this.bufferBytes,
      droppedSegments: droppedSegments ?? this.droppedSegments,
      overflowed: overflowed ?? this.overflowed,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceStatus &&
            connectionState == other.connectionState &&
            batteryPercent == other.batteryPercent &&
            protocolVersion == other.protocolVersion &&
            firmwareVersion == other.firmwareVersion &&
            bufferCount == other.bufferCount &&
            bufferBytes == other.bufferBytes &&
            droppedSegments == other.droppedSegments &&
            overflowed == other.overflowed &&
            error == other.error;
  }

  @override
  int get hashCode => Object.hash(
        connectionState,
        batteryPercent,
        protocolVersion,
        firmwareVersion,
        bufferCount,
        bufferBytes,
        droppedSegments,
        overflowed,
        error,
      );

  @override
  String toString() {
    return 'DeviceStatus('
        'connectionState: $connectionState, '
        'batteryPercent: $batteryPercent, '
        'protocolVersion: $protocolVersion, '
        'firmwareVersion: $firmwareVersion, '
        'bufferCount: $bufferCount, '
        'bufferBytes: $bufferBytes, '
        'droppedSegments: $droppedSegments, '
        'overflowed: $overflowed, '
        'error: $error)';
  }
}