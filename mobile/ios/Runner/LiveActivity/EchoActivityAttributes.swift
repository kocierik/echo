import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// What the Live Activity shows; compiled into the app and into the widget extension.
@available(iOS 16.1, *)
struct EchoActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// "listening", "muted" or "offline".
    var status: String
    /// 0-100, or -1 when the wearable does not measure it.
    var battery: Int
    /// Minutes of speech on the wearable waiting to reach the phone.
    var pendingMinutes: Int
  }
}
#endif
