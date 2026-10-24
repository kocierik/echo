import CoreLocation
import Flutter
import Foundation
import MapKit
import UIKit

/// "echo/visits": Places visited on the iPhone (lib/services/phone/visit_sources.dart).
///
/// The system's visit detection (`startMonitoringVisits`, low power, no continuous GPS)
/// needs "Always". iOS wakes or relaunches Echo for a visit, possibly without its Flutter
/// side: the recorder is made at launch (AppDelegate), names the visit (Apple's place name
/// where there is one, and the address), keeps it until Dart takes it ("take"), and says
/// "visits" when Dart is there. Times cross the channel as epoch milliseconds.
///
/// No background mode is needed: visit events reach a suspended or terminated app.
final class VisitRecorder: NSObject, CLLocationManagerDelegate {
  static let shared = VisitRecorder()

  private static let onKey = "echo_visits_on"
  private static let pendingKey = "echo_visits_pending"
  /// Kept on the phone at most, if Dart does not take them for a long time
  private static let maxPending = 500
  /// A visit vaguer than this does not say where the user was
  private static let maxAccuracy: CLLocationDistance = 300
  /// A point of interest this close is the place's name
  private static let nameRadius: CLLocationDistance = 30

  private let manager = CLLocationManager()
  private let geocoder = CLGeocoder()
  private let defaults = UserDefaults.standard
  private var channel: FlutterMethodChannel?

  /// "requestAlways" waiting for the user's answer
  private var accessReply: FlutterResult?
  private var askingAlways = false
  private var promptShown = false
  private var observers: [NSObjectProtocol] = []

  private override init() {
    super.init()
    manager.delegate = self
    // Relaunched for a visit, or started again: keep noticing while the option is on
    if defaults.bool(forKey: Self.onKey) { manager.startMonitoringVisits() }
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "echo/visits", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "access":
      accessName { result($0) }
    case "requestAlways":
      requestAlways(result)
    case "start":
      defaults.set(true, forKey: Self.onKey)
      manager.startMonitoringVisits()
      result(nil)
    case "stop":
      // At once: nothing more is noticed, and nothing kept here is sent
      defaults.set(false, forKey: Self.onKey)
      manager.stopMonitoringVisits()
      defaults.removeObject(forKey: Self.pendingKey)
      result(nil)
    case "take":
      result(pending())
      defaults.removeObject(forKey: Self.pendingKey)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Access

  private var status: CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  private func accessName(_ done: @escaping (String) -> Void) {
    let status = self.status
    // Asking whether location is on can block: not on the main thread
    DispatchQueue.global(qos: .userInitiated).async {
      let enabled = CLLocationManager.locationServicesEnabled()
      DispatchQueue.main.async {
        if !enabled {
          done("off")
          return
        }
        switch status {
        case .authorizedAlways: done("always")
        case .authorizedWhenInUse: done("whileInUse")
        case .notDetermined: done("notAsked")
        default: done("denied")
        }
      }
    }
  }

  /// "While in use" first when never asked, then the upgrade to "Always". iOS shows the
  /// upgrade only once: when it shows nothing, the answer is the current access.
  private func requestAlways(_ result: @escaping FlutterResult) {
    if accessReply != nil {
      result(FlutterError(code: "visits", message: "Already asking", details: nil))
      return
    }
    switch status {
    case .notDetermined:
      accessReply = result
      askingAlways = false
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse:
      accessReply = result
      askAlways()
    default:
      accessName { result($0) }
    }
  }

  private func askAlways() {
    askingAlways = true
    promptShown = false
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.promptShown = true })
    observers.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // The user answered the prompt; the new access may take a moment
        guard let self = self, self.promptShown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finishAsking() }
      })
    manager.requestAlwaysAuthorization()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, !self.promptShown else { return }
      self.finishAsking()
    }
  }

  private func finishAsking() {
    guard let reply = accessReply else { return }
    accessReply = nil
    askingAlways = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    accessName { reply($0) }
  }

  private func authorizationChanged() {
    guard accessReply != nil else { return }
    switch status {
    case .notDetermined:
      return  // the first prompt is still on screen
    case .authorizedWhenInUse where !askingAlways:
      askAlways()
    default:
      finishAsking()
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationChanged()
  }

  func locationManager(
    _ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus
  ) {
    if #available(iOS 14.0, *) { return }  // the method above
    authorizationChanged()
  }

  // MARK: Visits

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    // An arrival iOS does not know, or a vague fix: not a visit
    guard visit.arrivalDate != .distantPast,
      visit.horizontalAccuracy >= 0, visit.horizontalAccuracy <= Self.maxAccuracy,
      defaults.bool(forKey: Self.onKey)
    else { return }
    let arrived = visit.arrivalDate
    let left = visit.departureDate == .distantFuture ? nil : visit.departureDate
    let coordinate = visit.coordinate
    let accuracy = visit.horizontalAccuracy
    // Naming takes a network call: time to finish it in the background
    var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "echo.visit") {
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    }
    describe(coordinate) { [weak self] name, address in
      self?.keep(
        arrived: arrived, left: left, coordinate: coordinate, accuracy: accuracy,
        name: name, address: address)
      if task != .invalid {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
      }
    }
  }

  private func keep(
    arrived: Date, left: Date?, coordinate: CLLocationCoordinate2D,
    accuracy: CLLocationAccuracy, name: String?, address: String?
  ) {
    // Turned off while the place was named
    guard defaults.bool(forKey: Self.onKey) else { return }
    let key = "ios:\(Int64(arrived.timeIntervalSince1970))"
    var visit: [String: Any] = [
      "key": key,
      "arrived": ms(arrived),
      "latitude": coordinate.latitude,
      "longitude": coordinate.longitude,
      "accuracy": accuracy,
    ]
    if let left = left { visit["left"] = ms(left) }
    if let name = name { visit["name"] = name }
    if let address = address { visit["address"] = address }
    var all = pending().filter { ($0["key"] as? String) != key }
    all.append(visit)
    defaults.set(Array(all.suffix(Self.maxPending)), forKey: Self.pendingKey)
    channel?.invokeMethod("visits", arguments: nil)
  }

  private func pending() -> [[String: Any]] {
    defaults.array(forKey: Self.pendingKey) as? [[String: Any]] ?? []
  }

  private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

  // MARK: Names

  /// Apple's name for the place, when the visit is at one (the placemark's point of
  /// interest, else one within a few metres), and the address. Both may be nil; at most
  /// 20 s.
  private func describe(
    _ coordinate: CLLocationCoordinate2D, done: @escaping (String?, String?) -> Void
  ) {
    var finished = false
    let finish: (String?, String?) -> Void = { name, address in
      guard !finished else { return }
      finished = true
      done(name, address)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(nil, nil) }
    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
      let mark = placemarks?.first
      let street = [mark?.thoroughfare, mark?.subThoroughfare]
        .compactMap { $0 }
        .joined(separator: " ")
      let parts = [street.isEmpty ? mark?.name : street, mark?.locality].compactMap { $0 }
      let address = parts.isEmpty ? nil : parts.joined(separator: ", ")
      // The placemark's own name is a place's when it is not the street or its number
      var placeName = mark?.areasOfInterest?.first
      if placeName == nil, let named = mark?.name, !street.isEmpty,
        !named.hasPrefix(mark?.thoroughfare ?? named), named != street
      {
        placeName = named
      }
      DispatchQueue.main.async {
        if let placeName = placeName {
          finish(placeName, address)
        } else if let self = self {
          self.pointOfInterest(near: location) { finish($0, address) }
        } else {
          finish(nil, address)
        }
      }
    }
  }

  private func pointOfInterest(near location: CLLocation, done: @escaping (String?) -> Void) {
    guard #available(iOS 14.0, *) else {
      done(nil)
      return
    }
    let request = MKLocalPointsOfInterestRequest(
      center: location.coordinate, radius: Self.nameRadius)
    request.pointOfInterestFilter = .includingAll
    MKLocalSearch(request: request).start { response, _ in
      let nearest = response?.mapItems
        .compactMap { item -> (String, CLLocationDistance)? in
          guard let name = item.name, let place = item.placemark.location else { return nil }
          return (name, place.distance(from: location))
        }
        .filter { $0.1 <= Self.nameRadius }
        .min { $0.1 < $1.1 }
      done(nearest?.0)
    }
  }
}
