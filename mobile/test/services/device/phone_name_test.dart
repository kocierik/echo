import 'package:echo_app/services/device/phone_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iPhone identifiers become model names', () {
    expect(iosModelName('iPhone16,1'), 'iPhone 15 Pro');
    expect(iosModelName('iPhone17,3'), 'iPhone 16');
    expect(iosModelName('iPhone14,6'), 'iPhone SE (3rd generation)');
  });

  test('an iPhone not in the table, or the simulator, is just iPhone', () {
    expect(iosModelName('iPhone99,9'), 'iPhone');
    expect(iosModelName('arm64'), 'iPhone');
    expect(iosModelName(''), 'iPhone');
  });

  test('Android names join the maker and the model once', () {
    expect(androidModelName('Google', 'Pixel 8'), 'Google Pixel 8');
    expect(androidModelName('samsung', 'SM-S921B'), 'Samsung SM-S921B');
    expect(androidModelName('Xiaomi', 'Xiaomi 14'), 'Xiaomi 14');
    expect(androidModelName('', ''), 'Android phone');
  });
}
