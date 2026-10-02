import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flutter_blue_plus exposes background restoration APIs', () {
    final configureRestoreState = () =>
        FlutterBluePlus.setOptions(restoreState: true);
    final createDevice = () =>
        BluetoothDevice.fromId('compile-time-capability-probe');

    expect(configureRestoreState, isA<Future<void> Function()>());
    expect(createDevice, isA<BluetoothDevice Function()>());
  });
}