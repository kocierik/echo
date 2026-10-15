import Flutter
import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// "echo/live_activity": the Flutter side starts, updates and ends the one Live Activity.
/// Local only (no push token): updated while the app runs, which the wearable's BLE keeps
/// doing through the day.
final class LiveActivityBridge {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "echo/live_activity", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(ActivityKit)
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }
    switch call.method {
    case "available":
      result(ActivityAuthorizationInfo().areActivitiesEnabled)
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "args", message: "missing state", details: nil))
        return
      }
      let state = EchoActivityAttributes.ContentState(
        status: args["status"] as? String ?? "listening",
        battery: args["battery"] as? Int ?? -1,
        pendingMinutes: args["pendingMinutes"] as? Int ?? 0
      )
      update(state)
      result(true)
    case "end":
      end()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
    #else
    result(false)
    #endif
  }

  #if canImport(ActivityKit)
  @available(iOS 16.1, *)
  private func update(_ state: EchoActivityAttributes.ContentState) {
    if let activity = Activity<EchoActivityAttributes>.activities.first {
      Task { await activity.update(using: state) }
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    _ = try? Activity.request(
      attributes: EchoActivityAttributes(),
      contentState: state,
      pushType: nil
    )
  }

  @available(iOS 16.1, *)
  private func end() {
    for activity in Activity<EchoActivityAttributes>.activities {
      Task { await activity.end(dismissalPolicy: .immediate) }
    }
  }
  #endif
}
