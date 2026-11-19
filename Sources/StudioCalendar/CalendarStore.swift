import AppKit
import EventKit
import Foundation

/// Reads and writes calendars through the Mac's own calendar accounts, so every change syncs
/// to Google or iCloud and shows up on the phone too.
@MainActor
final class CalendarStore: ObservableObject {
    let ek = EKEventStore()
    @Published var authorized = false
    @Published var events: [CalEvent] = []
    @Published var problem: String?
    @Published var now = Date()
    @Published private(set) var calendars: [EKCalendar] = []
    @Published var shownIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(shownIDs), forKey: "shownCalendars"); reload() }
    }
    @Published var targetID: String? {
        didSet { UserDefaults.standard.set(targetID, forKey: "targetCalendar") }
    }
    private var timer: Timer?

    var target: EKCalendar? { calendars.first { $0.calendarIdentifier == targetID } }
    var calendarName: String { target?.title ?? "–" }

    /// Working hours used for "when am I free?" answers.
    var dayStartHour: Int { UserDefaults.standard.object(forKey: "dayStart") as? Int ?? 8 }
    var dayEndHour: Int { UserDefaults.standard.object(forKey: "dayEnd") as? Int ?? 20 }

    init() {
        shownIDs = Set(UserDefaults.standard.stringArray(forKey: "shownCalendars") ?? [])
        targetID = UserDefaults.standard.string(forKey: "targetCalendar")
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendars(); self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let old = self.now
                self.now = Date()
                if !Calendar.current.isDate(old, inSameDayAs: self.now) { self.reload() }
            }
        }
    }

    func requestAccess() async {
        do {
            let ok = try await ek.requestFullAccessToEvents()
            authorized = ok
            if ok {
                problem = nil
                refreshCalendars()
                reload()
            } else {
                problem = "No calendar access. Allow it in System Settings > Privacy & Security > Calendars."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Picks sensible defaults the first time: show and write to the calendar named in "calendarTitle",
    /// otherwise the system default calendar.
    func refreshCalendars() {
        calendars = ek.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
        let ids = Set(calendars.map(\.calendarIdentifier))
        if targetID == nil || !ids.contains(targetID!) {
            let wanted = UserDefaults.standard.string(forKey: "calendarTitle")
            let hub = calendars.first { $0.title == wanted && $0.allowsContentModifications }
                ?? ek.defaultCalendarForNewEvents
            targetID = hub?.calendarIdentifier
        }
        let valid = shownIDs.intersection(ids)
        if valid.isEmpty, let t = targetID { shownIDs = [t] } else if valid != shownIDs { shownIDs = valid }
    }

    func reload() {
        guard authorized else { return }
        let cals = calendars.filter { shownIDs.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { events = []; return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -35, to: today)!
        let end = cal.date(byAdding: .day, value: 60, to: today)!
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
        var list = ek.events(matching: pred).map(CalEvent.init)
        // Copies (e.g. synced in from a work calendar) lose their guest list. Claude still joins when the
        // same Meet call sits on the calendar Claude Meetings watches.
        let watched = calendars.filter { $0.title.lowercased() == ClaudeMeetings.account }
        if ClaudeMeetings.enabled, !watched.isEmpty {
            let codes = Set(ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: watched))
                .compactMap { MeetingLink.find(in: $0) }.filter(ClaudeMeetings.isMeet).map { $0.path.lowercased() })
            for i in list.indices where !list[i].claudeJoins {
                if let u = list[i].meetingURL, ClaudeMeetings.isMeet(u), codes.contains(u.path.lowercased()) { list[i].claudeJoins = true }
            }
        }
        events = list.sorted { $0.start < $1.start }
        now = Date()
    }

    // MARK: queries

    func timed(on day: Date) -> [CalEvent] {
        let cal = Calendar.current
        return events.filter { !$0.allDay && cal.isDate($0.start, inSameDayAs: day) }
    }

    func allDay(on day: Date) -> [CalEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        return events.filter { $0.allDay && $0.start < dayEnd && $0.end > dayStart }
    }

    var current: CalEvent? { events.first { !$0.allDay && $0.start <= now && $0.end > now } }
    var nextEvent: CalEvent? { events.first { !$0.allDay && $0.start > now } }

    /// The call to join now: running, or starting within the next 15 minutes.
    var joinable: CalEvent? {
        let soon = Date().addingTimeInterval(15 * 60)
        let calls = events.filter { !$0.allDay && $0.meetingURL != nil && $0.start <= soon && $0.end > Date() }
        // A call about to start beats one that is already ending.
        return calls.max { $0.start < $1.start }
    }

    /// Opens the call link in the default browser (or the Zoom/Teams app if it takes the link).
    @discardableResult
    func join(_ ev: CalEvent) -> Bool {
        guard let url = ev.meetingURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Free gaps of at least `minimum` minutes inside working hours.
    func freeSlots(on day: Date, minimum: Int = 30) -> [(Date, Date)] {
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: day)
        var cursor = cal.date(byAdding: .hour, value: dayStartHour, to: d0)!
        let limit = cal.date(byAdding: .hour, value: dayEndHour, to: d0)!
        if cal.isDateInToday(day), now > cursor {
            let m = cal.component(.minute, from: now)
            cursor = cal.date(byAdding: .minute, value: (15 - m % 15) % 15, to: now)!
        }
        var out: [(Date, Date)] = []
        for e in timed(on: day) where e.end > cursor {
            if e.start.timeIntervalSince(cursor) >= Double(minimum * 60), e.start <= limit { out.append((cursor, min(e.start, limit))) }
            cursor = max(cursor, e.end)
            if cursor >= limit { break }
        }
        if limit.timeIntervalSince(cursor) >= Double(minimum * 60) { out.append((cursor, limit)) }
        return out
    }

    // MARK: changes

    @discardableResult
    func add(title: String, start: Date, end: Date, kind: Category? = nil, location: String? = nil, todo: String? = nil) -> Bool {
        guard let target else { problem = "No calendar to add to."; return false }
        let e = EKEvent(eventStore: ek)
        e.calendar = target
        e.title = title
        e.startDate = start
        e.endDate = end
        let tags = [kind?.tag, todo.map { "[todo:" + $0 + "]" }].compactMap { $0 }
        if !tags.isEmpty { e.notes = tags.joined(separator: " ") }
        if let location, !location.isEmpty { e.location = location }
        return save(e, verb: "save")
    }

    private func find(_ ev: CalEvent) -> EKEvent? {
        let cals = calendars.filter { $0.calendarIdentifier == ev.calendarID }
        guard !cals.isEmpty else { return nil }
        let pred = ek.predicateForEvents(withStart: ev.start.addingTimeInterval(-60), end: ev.end.addingTimeInterval(60), calendars: cals)
        return ek.events(matching: pred).first { $0.eventIdentifier == ev.ekID && abs($0.startDate.timeIntervalSince(ev.start)) < 1 }
    }

    @discardableResult
    func rename(_ ev: CalEvent, to title: String) -> Bool {
        guard let e = find(ev) else { return false }
        e.title = title
        return save(e, verb: "rename")
    }

    @discardableResult
    func move(_ ev: CalEvent, start: Date, end: Date) -> Bool {
        guard let e = find(ev) else { return false }
        e.startDate = start
        e.endDate = end
        return save(e, verb: "move")
    }

    @discardableResult
    func delete(_ ev: CalEvent) -> Bool {
        guard let e = find(ev) else { return false }
        do { try ek.remove(e, span: .thisEvent, commit: true); reload(); return true } catch {
            problem = "Could not delete: \(error.localizedDescription)"
            return false
        }
    }

    private func save(_ e: EKEvent, verb: String) -> Bool {
        do { try ek.save(e, span: .thisEvent, commit: true); reload(); return true } catch {
            problem = "Could not \(verb): \(error.localizedDescription)"
            return false
        }
    }

    // MARK: people

    /// Everyone you met in the last half year, from the attendee lists: "Name <email>", most recent first.
    func people(limit: Int = 200) -> [String] {
        guard authorized else { return [] }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -180, to: now)!
        let end = cal.date(byAdding: .day, value: 60, to: now)!
        let evs = ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate > $1.startDate }
        var seen = Set<String>()
        var out: [String] = []
        for e in evs {
            for p in e.attendees ?? [] where !p.isCurrentUser && p.participantType == .person {
                let mail = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased()
                guard mail.contains("@"), !mail.contains("calendar.google.com"), seen.insert(mail).inserted else { continue }
                let name = p.name.flatMap { $0.contains("@") ? nil : $0 } ?? ""
                out.append(name.isEmpty ? mail : "\(name) <\(mail)>")
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: Claude context

    /// The coming days as short lines with ids (#1, #2 …) and free time, plus the id map.
    func context(days: Int = 14) -> (text: String, ids: [String: CalEvent]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var ids: [String: CalEvent] = [:]
        var n = 0
        var lines: [String] = []
        for i in 0..<days {
            let day = cal.date(byAdding: .day, value: i, to: today)!
            lines.append(Fmt.promptDay.string(from: day) + ":")
            for e in allDay(on: day) {
                n += 1; ids["#\(n)"] = e
                lines.append("  #\(n) all day · \(e.title)")
            }
            for e in timed(on: day) {
                n += 1; ids["#\(n)"] = e
                lines.append("  #\(n) \(Fmt.time.string(from: e.start))–\(Fmt.time.string(from: e.end)) · \(e.title) [\(e.category.rawValue)]")
            }
            let free = freeSlots(on: day).map { Fmt.time.string(from: $0.0) + "–" + Fmt.time.string(from: $0.1) }
            lines.append("  free: " + (free.isEmpty ? "none" : free.joined(separator: ", ")))
        }
        return (lines.joined(separator: "\n"), ids)
    }
}
