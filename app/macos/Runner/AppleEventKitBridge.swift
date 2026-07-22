import EventKit
import FlutterMacOS

@MainActor
final class AppleEventKitBridge {
  private let store = EKEventStore()
  private let channel: FlutterMethodChannel

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "omi/apple_eventkit", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterError(code: "unavailable", message: nil, details: nil)) }
      Task { @MainActor in
        do {
          result(try await self.handle(call))
        } catch {
          result(FlutterError(code: "eventkit", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall) async throws -> Any {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let source = try source(from: arguments)
    switch call.method {
    case "status":
      return ["source": source.rawValue, "status": authorization(for: source)]
    case "request":
      return ["source": source.rawValue, "status": try await request(source)]
    case "read":
      try await requireAccess(source)
      let limit = min(max(arguments["limit"] as? Int ?? 200, 1), 2_500)
      switch source {
      case .calendar:
        let daysBack = min(max(arguments["daysBack"] as? Int ?? 365, 0), 3_650)
        let daysForward = min(max(arguments["daysForward"] as? Int ?? 30, 0), 3_650)
        return readEvents(daysBack: daysBack, daysForward: daysForward, limit: limit)
      case .reminders:
        return await readReminders(limit: limit)
      }
    default:
      throw BridgeError.invalidMethod
    }
  }

  private func source(from arguments: [String: Any]) throws -> Source {
    guard let value = arguments["source"] as? String, let source = Source(rawValue: value) else {
      throw BridgeError.invalidSource
    }
    return source
  }

  private func authorization(for source: Source) -> String {
    let status = EKEventStore.authorizationStatus(for: source.entityType)
    if #available(macOS 14.0, *) {
      switch status {
      case .fullAccess: return "full_access"
      case .writeOnly: return "write_only"
      case .notDetermined: return "not_determined"
      case .restricted: return "restricted"
      case .denied: return "denied"
      case .authorized: return "full_access"
      @unknown default: return "denied"
      }
    }
    switch status {
    case .authorized: return "full_access"
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    default: return "denied"
    }
  }

  private func request(_ source: Source) async throws -> String {
    if #available(macOS 14.0, *) {
      switch source {
      case .calendar: _ = try await store.requestFullAccessToEvents()
      case .reminders: _ = try await store.requestFullAccessToReminders()
      }
    } else {
      _ = try await store.requestAccess(to: source.entityType)
    }
    return authorization(for: source)
  }

  private func requireAccess(_ source: Source) async throws {
    var status = authorization(for: source)
    if status == "not_determined" { status = try await request(source) }
    guard status == "full_access" else { throw BridgeError.accessRequired(source.rawValue) }
  }

  private func readEvents(daysBack: Int, daysForward: Int, limit: Int) -> [[String: Any]] {
    let now = Date()
    let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
    let end = Calendar.current.date(byAdding: .day, value: daysForward, to: now) ?? now
    return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
      .sorted { $0.startDate > $1.startDate }
      .prefix(limit)
      .map { event in
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return [
          "id": "apple_calendar:\(identifier)",
          "nativeId": identifier,
          "source": Source.calendar.rawValue,
          "provider": "apple_eventkit",
          "title": event.title ?? "Untitled event",
          "notes": event.notes ?? "",
          "calendar": event.calendar.title,
          "startAt": iso(event.startDate),
          "endAt": iso(event.endDate),
          "occurredAt": iso(event.startDate),
          "recordedAt": iso(now),
          "isAllDay": event.isAllDay,
          "location": event.location ?? "",
        ]
      }
  }

  private func readReminders(limit: Int) async -> [[String: Any]] {
    let reminders = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: store.predicateForReminders(in: nil)) {
        continuation.resume(returning: $0 ?? [])
      }
    }
    let now = Date()
    return reminders.sorted { ($0.lastModifiedDate ?? .distantPast) > ($1.lastModifiedDate ?? .distantPast) }
      .prefix(limit)
      .map { reminder in
        let identifier = reminder.calendarItemIdentifier
        let dueAt = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let occurredAt = reminder.lastModifiedDate ?? reminder.creationDate ?? now
        return [
          "id": "apple_reminders:\(identifier)",
          "nativeId": identifier,
          "source": Source.reminders.rawValue,
          "provider": "apple_eventkit",
          "title": reminder.title ?? "Untitled reminder",
          "notes": reminder.notes ?? "",
          "calendar": reminder.calendar.title,
          "dueAt": dueAt.map(iso) ?? NSNull(),
          "occurredAt": iso(occurredAt),
          "recordedAt": iso(now),
          "isCompleted": reminder.isCompleted,
        ]
      }
  }

  private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private enum Source: String {
    case calendar
    case reminders

    var entityType: EKEntityType { self == .calendar ? .event : .reminder }
  }

  private enum BridgeError: LocalizedError {
    case accessRequired(String)
    case invalidMethod
    case invalidSource

    var errorDescription: String? {
      switch self {
      case .accessRequired(let source): return "Full \(source) access is required."
      case .invalidMethod: return "Unknown EventKit operation."
      case .invalidSource: return "Calendar or reminders must be selected."
      }
    }
  }
}
