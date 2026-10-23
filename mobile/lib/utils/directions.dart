import '../models/saved.dart';

/// The way to a saved place in the phone's maps: Apple Maps on iOS, Google Maps on
/// Android (no map is drawn in the app).
Uri directionsUri(SavedPlace place, {required bool iOS}) {
  final destination = '${place.latitude},${place.longitude}';
  return iOS
      ? Uri.https('maps.apple.com', '/', {'daddr': destination})
      : Uri.https('www.google.com', '/maps/dir/', {'api': '1', 'destination': destination});
}
