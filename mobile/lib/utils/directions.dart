import '../models/place.dart';
import '../models/saved.dart';

/// The way to a saved place in the phone's maps: Apple Maps on iOS, Google Maps on
/// Android (no map is drawn in the app).
Uri directionsUri(SavedPlace place, {required bool iOS}) {
  final destination = '${place.latitude},${place.longitude}';
  return iOS
      ? Uri.https('maps.apple.com', '/', {'daddr': destination})
      : Uri.https('www.google.com', '/maps/dir/', {'api': '1', 'destination': destination});
}

/// A stay in the phone's maps: at its coordinates, named, when the phone sent them;
/// else searched by its name or address.
Uri visitMapsUri(PlaceVisit visit, {required bool iOS}) {
  final lat = visit.latitude, lng = visit.longitude;
  final at = lat == null || lng == null ? null : '$lat,$lng';
  if (iOS) {
    return Uri.https('maps.apple.com', '/', {if (at != null) 'll': at, 'q': visit.label});
  }
  return Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': at ?? visit.label});
}
