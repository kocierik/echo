import ActivityKit
import SwiftUI
import WidgetKit

@main
struct EchoActivityBundle: WidgetBundle {
  var body: some Widget {
    EchoLiveActivity()
  }
}

/// Lock Screen and Dynamic Island: is Echo listening, its battery, speech waiting to sync.
struct EchoLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: EchoActivityAttributes.self) { context in
      LockScreenView(state: context.state)
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.75))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          StatusIcon(status: context.state.status)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(statusText(context.state.status)).font(.headline)
        }
        DynamicIslandExpandedRegion(.trailing) {
          BatteryText(battery: context.state.battery)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if context.state.pendingMinutes > 0 {
            Text("\(context.state.pendingMinutes) min of speech to sync").font(.caption)
          }
        }
      } compactLeading: {
        StatusIcon(status: context.state.status)
      } compactTrailing: {
        BatteryText(battery: context.state.battery)
      } minimal: {
        StatusIcon(status: context.state.status)
      }
    }
  }
}

private func statusText(_ status: String) -> String {
  switch status {
  case "muted": return "Echo is muted"
  case "offline": return "Echo is offline"
  default: return "Echo is listening"
  }
}

private struct StatusIcon: View {
  let status: String

  var body: some View {
    switch status {
    case "muted":
      Image(systemName: "mic.slash.fill").foregroundColor(.red)
    case "offline":
      Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundColor(.gray)
    default:
      Image(systemName: "waveform").foregroundColor(.green)
    }
  }
}

private struct BatteryText: View {
  let battery: Int

  var body: some View {
    if battery >= 0 {
      Text("\(battery)%").foregroundColor(battery < 15 ? .red : .primary)
    } else {
      Image(systemName: "battery.0").foregroundColor(.gray)
    }
  }
}

private struct LockScreenView: View {
  let state: EchoActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 12) {
      StatusIcon(status: state.status).font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(statusText(state.status)).font(.headline).foregroundColor(.white)
        if state.pendingMinutes > 0 {
          Text("\(state.pendingMinutes) min of speech to sync")
            .font(.caption)
            .foregroundColor(.white.opacity(0.8))
        }
      }
      Spacer()
      BatteryText(battery: state.battery).foregroundColor(.white)
    }
  }
}
