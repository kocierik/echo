import 'package:echo_app/services/phone/stay_detector.dart';
import 'package:flutter_test/flutter_test.dart';

// About 111 m per 0.001 degree of latitude
const home = (45.4600, 9.1900);
const office = (45.4800, 9.2100);
final start = DateTime.utc(2026, 10, 24, 8);

Fix fix((double, double) where, int minutes, {double north = 0, double accuracy = 30}) => Fix(
      latitude: where.$1 + north,
      longitude: where.$2,
      accuracyM: accuracy,
      at: start.add(Duration(minutes: minutes)),
    );

void main() {
  test('a stay is sent open at ten minutes, then closed when the phone leaves', () {
    final detector = StayDetector();
    final sent = [
      for (final minutes in [0, 3, 6, 9]) ...detector.add(fix(home, minutes, north: 0.0003)),
    ];
    expect(sent, isEmpty);

    final open = detector.add(fix(home, 12));
    expect(open.single.leftAt, isNull);
    expect(open.single.arrivedAt, start);
    expect(open.single.key, 'android:${start.millisecondsSinceEpoch}');

    expect(detector.add(fix(home, 40)), isEmpty);
    expect(detector.add(fix(office, 45)), isEmpty);
    final closed = detector.add(fix(office, 48));

    expect(closed.single.key, open.single.key);
    expect(closed.single.leftAt, start.add(const Duration(minutes: 40)));
    expect(closed.single.latitude, closeTo(45.4601, 0.0005));
  });

  test('a short stop is not a visit', () {
    final detector = StayDetector();
    final sent = [
      ...detector.add(fix(home, 0)),
      ...detector.add(fix(home, 6)),
      ...detector.add(fix(office, 9)),
      ...detector.add(fix(office, 12)),
    ];

    expect(sent, isEmpty);
  });

  test('one far point does not end the stay', () {
    final detector = StayDetector();
    detector.add(fix(home, 0));
    detector.add(fix(home, 12));

    // A jump of a few hundred metres (a bad Wi-Fi fix), then home again
    expect(detector.add(fix(home, 15, north: 0.004)), isEmpty);
    expect(detector.add(fix(home, 18)), isEmpty);
    detector.add(fix(office, 60));
    final closed = detector.add(fix(office, 63));

    expect(closed.single.leftAt, start.add(const Duration(minutes: 18)));
  });

  test('a vague fix is left out', () {
    final detector = StayDetector();
    detector.add(fix(home, 0));
    detector.add(fix(office, 5, accuracy: 900));
    detector.add(fix(office, 8, accuracy: 900));

    expect(detector.add(fix(home, 11)).single.leftAt, isNull);
  });

  test('passing through places on the way is not a visit', () {
    final detector = StayDetector();
    final sent = [
      for (var i = 0; i < 12; i++) ...detector.add(fix(home, i * 3, north: i * 0.01)),
    ];

    expect(sent, isEmpty);
  });

  test('the stay going on survives a restart', () {
    final detector = StayDetector();
    detector.add(fix(home, 0));
    detector.add(fix(home, 12));

    final again = StayDetector.fromJson(detector.toJson());
    again.add(fix(office, 30));
    final closed = again.add(fix(office, 33));

    expect(closed.single.arrivedAt, start);
    expect(closed.single.leftAt, start.add(const Duration(minutes: 12)));
    expect(StayDetector.fromJson({'stay': 'broken'}).add(fix(home, 0)), isEmpty);
  });
}
