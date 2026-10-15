import EventKit
import Flutter
import Foundation

/// "echo/eventkit": Reminders and Calendar for Echo (lib/services/phone/phone_calendar.dart).
/// Dates cross the channel as epoch milliseconds; failures as FlutterError "eventkit".
final class EventKitBridge {
  private let channel: FlutterMethodChannel
  private let store = EKEventStore()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "echo/eventkit", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let type: EKEntityType = (args["app"] as? String) == "calendar" ? .event : .reminder
    switch call.method {
    case "access":
      result(accessName(type))
    case "requestAccess":
      requestAccess(type) { granted in result(granted) }
    case "createReminder":
      result(run { try self.createReminder(args) })
    case "openReminders":
      openReminders(args, result: result)
    case "createEvent":
      result(run { try self.createEvent(args) })
    case "events":
      result(run { try self.events(args) })
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Access

  private func accessName(_ type: EKEntityType) -> String {
    let status = EKEventStore.authorizationStatus(for: type)
    if status == .notDetermined { return "notAsked" }
    if #available(iOS 17.0, *) {
      // Write-only access cannot read: not enough to answer "what do I have?"
      return status == .fullAccess ? "granted" : "denied"
    }
    return status.rawValue == 3 ? "granted" : "denied"  // .authorized before iOS 17
  }

  private func requestAccess(_ type: EKEntityType, done: @escaping (Bool) -> Void) {
    let reply: (Bool, Error?) -> Void = { [weak self] granted, _ in
      DispatchQueue.main.async {
        // A store made before the access was given does not see the data until reset
        if granted { self?.store.reset() }
        done(granted)
      }
    }
    if #available(iOS 17.0, *) {
      if type == .reminder {
        store.requestFullAccessToReminders(completion: reply)
      } else {
        store.requestFullAccessToEvents(completion: reply)
      }
    } else {
      store.requestAccess(to: type, completion: reply)
    }
  }

  // MARK: Reminders

  private func createReminder(_ args: [String: Any]) throws -> [String: Any] {
    let reminder = EKReminder(eventStore: store)
    reminder.title = try required(args, "title")
    reminder.notes = optional(args, "notes")
    reminder.calendar = try reminderList(named: optional(args, "list"))
    if let due = date(args["due"]) {
      let hasTime = args["dueHasTime"] as? Bool ?? true
      let units: Set<Calendar.Component> =
        hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
      reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
      // The alert at the time is what makes a reminder "remind"
      if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
    }
    try store.save(reminder, commit: true)
    return reminderJSON(reminder)
  }

  private func openReminders(_ args: [String: Any], result: @escaping FlutterResult) {
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: date(args["dueBefore"]), calendars: nil)
    store.fetchReminders(matching: predicate) { [weak self] reminders in
      let items = (reminders ?? []).compactMap { self?.reminderJSON($0) }
      DispatchQueue.main.async { result(items) }
    }
  }

  private func reminderList(named name: String?) throws -> EKCalendar {
    if let name = name,
      let list = store.calendars(for: .reminder).first(where: {
        $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications
      })
    {
      return list
    }
    guard let list = store.defaultCalendarForNewReminders() else {
      throw BridgeError("There is no Reminders list to add to")
    }
    return list
  }

  private func reminderJSON(_ reminder: EKReminder) -> [String: Any] {
    var item: [String: Any] = [
      "id": reminder.calendarItemIdentifier,
      "title": reminder.title ?? "",
      "list": reminder.calendar?.title ?? "",
    ]
    if let notes = reminder.notes, !notes.isEmpty { item["notes"] = notes }
    if let components = reminder.dueDateComponents,
      let due = Calendar.current.date(from: components)
    {
      item["due"] = ms(due)
      item["dueHasTime"] = components.hour != nil
    }
    return item
  }

  // MARK: Calendar

  private func createEvent(_ args: [String: Any]) throws -> [String: Any] {
    guard let start = date(args["start"]), let end = date(args["end"]) else {
      throw BridgeError("start and end are required")
    }
    let event = EKEvent(eventStore: store)
    event.title = try required(args, "title")
    event.startDate = start
    event.endDate = end
    event.isAllDay = args["allDay"] as? Bool ?? false
    event.location = optional(args, "location")
    event.notes = optional(args, "notes")
    event.calendar = try eventCalendar(named: optional(args, "calendar"))
    try store.save(event, span: .thisEvent, commit: true)
    return eventJSON(event)
  }

  private func events(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let start = date(args["start"]), let end = date(args["end"]) else {
      throw BridgeError("start and end are required")
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate)
      .sorted { $0.startDate < $1.startDate }
      .map(eventJSON)
  }

  private func eventCalendar(named name: String?) throws -> EKCalendar {
    if let name = name,
      let calendar = store.calendars(for: .event).first(where: {
        $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.allowsContentModifications
      })
    {
      return calendar
    }
    guard let calendar = store.defaultCalendarForNewEvents else {
      throw BridgeError("There is no calendar to add to")
    }
    return calendar
  }

  private func eventJSON(_ event: EKEvent) -> [String: Any] {
    var item: [String: Any] = [
      "id": event.calendarItemIdentifier,
      "title": event.title ?? "",
      "start": ms(event.startDate),
      "end": ms(event.endDate),
      "allDay": event.isAllDay,
      "calendar": event.calendar?.title ?? "",
      "attendees": (event.attendees ?? []).filter { !$0.isCurrentUser }.map {
        ["name": $0.name ?? "", "email": email(of: $0)]
      },
    ]
    if let location = event.location, !location.isEmpty { item["location"] = location }
    if let notes = event.notes, !notes.isEmpty { item["notes"] = notes }
    return item
  }

  private func email(of participant: EKParticipant) -> String {
    let url = participant.url.absoluteString
    return url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : ""
  }

  // MARK: Helpers

  private func run(_ body: () throws -> Any) -> Any {
    do {
      return try body()
    } catch let error as BridgeError {
      return FlutterError(code: "eventkit", message: error.message, details: nil)
    } catch {
      return FlutterError(code: "eventkit", message: error.localizedDescription, details: nil)
    }
  }

  private func required(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = optional(args, key) else { throw BridgeError("\(key) is required") }
    return value
  }

  private func optional(_ args: [String: Any], _ key: String) -> String? {
    guard let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }

  private func date(_ value: Any?) -> Date? {
    guard let ms = value as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: ms.doubleValue / 1000)
  }

  private func ms(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
}

private struct BridgeError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}
