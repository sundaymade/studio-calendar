import EventKit
import Foundation
import SwiftUI

enum Category: String {
    case meeting, uni, work, focus

    /// Tag written into the event notes so the colour survives a reload.
    var tag: String {
        switch self {
        case .meeting: return "[studio:meeting]"
        case .uni: return "[studio:uni]"
        case .work: return "[studio:work]"
        case .focus: return "[studio:focus]"
        }
    }

    init?(kind: String?) {
        switch (kind ?? "").lowercased() {
        case "meeting", "call": self = .meeting
        case "uni", "study", "class": self = .uni
        case "work", "job", "gh": self = .work
        case "focus", "session", "deep work": self = .focus
        default: return nil
        }
    }
}

struct CalEvent: Identifiable, Equatable {
    let id: String
    let ekID: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var category: Category
    var editable: Bool
    var calendarID: String
    var calendarTitle: String
    var location: String?
    /// Video call link (Meet, Zoom, Teams …) found in the event.
    var meetingURL: URL?
    /// The Measure to-do this block is for ([todo:note.…] in the notes).
    var todoID: String?
    /// A work block (planned focus session or to-do), not an appointment. Only these show up in the evening check.
    var isTask: Bool
    /// Claude Meetings will join: a Meet call with the Claude account on the invite.
    var claudeJoins: Bool

    var isRunning: Bool { start <= Date() && end > Date() }

    /// "09:00–17:15", or "09:00–Sun 17:15" when it ends on a later day.
    var span: String {
        let to = Calendar.current.isDate(end.addingTimeInterval(-1), inSameDayAs: start)
            ? Fmt.time.string(from: end)
            : Fmt.weekdayShort.string(from: end) + " " + Fmt.time.string(from: end)
        return Fmt.time.string(from: start) + "–" + to
    }

    init(_ e: EKEvent) {
        ekID = e.eventIdentifier ?? UUID().uuidString
        id = ekID + "@" + String(Int(e.startDate.timeIntervalSince1970))
        title = (e.title?.isEmpty == false ? e.title! : "Untitled")
        start = e.startDate
        end = e.endDate
        allDay = e.isAllDay
        category = Self.categorize(e)
        editable = e.calendar?.allowsContentModifications ?? false
        calendarID = e.calendar?.calendarIdentifier ?? ""
        calendarTitle = e.calendar?.title ?? ""
        let loc = e.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        meetingURL = MeetingLink.find(in: e)
        claudeJoins = ClaudeMeetings.joins(e, meeting: meetingURL)
        let notes = e.notes ?? ""
        if let r = notes.range(of: #"\[todo:([^\]]+)\]"#, options: .regularExpression) {
            todoID = String(notes[r].dropFirst(6).dropLast())
        }
        isTask = todoID != nil || notes.contains("[studio:focus]") || title.lowercased().hasPrefix("focus")
        location = loc.isEmpty || loc.lowercased().hasPrefix("http") ? nil : loc
    }

    /// Colour by meaning: meetings, study, work (your keywords), everything else is focus time.
    static func categorize(_ e: EKEvent) -> Category {
        let title = (e.title ?? "").lowercased()
        let notes = (e.notes ?? "").lowercased()
        if notes.contains("[studio:meeting]") { return .meeting }
        if notes.contains("[studio:uni]") { return .uni }
        if notes.contains("[studio:work]") || notes.contains("[studio:gh]") { return .work }
        if notes.contains("[studio:focus]") { return .focus }
        if Profile.studyKeywords.contains(where: { title.contains($0) }) { return .uni }
        if Profile.workKeywords.contains(where: { title.contains($0) }) { return .work }
        let joined = [title, notes, (e.location ?? "").lowercased(), e.url?.absoluteString.lowercased() ?? ""].joined(separator: " ")
        if e.hasAttendees || joined.contains("meet.google") || joined.contains("zoom.us") || joined.contains("teams.microsoft") { return .meeting }
        let meetingWords = ["call", "meeting", "kennenlernen", "catch-up", "catch up", " met ", "coffee", "sync", "interview", "termin mit", "1:1"]
        if meetingWords.contains(where: { (" " + title + " ").contains($0) }) { return .meeting }
        return .focus
    }
}

/// Finds the video call link in an event and makes it open with the right account.
enum MeetingLink {
    private static let hosts = ["meet.google.com/", "zoom.us/j/", "zoom.us/my/", "zoom.us/w/", "teams.microsoft.com/l/meetup-join",
                                "teams.live.com/meet", "webex.com/", "whereby.com/", "around.co/", "app.cal.com/video",
                                "facetime.apple.com/join", "meet.jit.si/", "app.gather.town/"]
    private static let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#)

    static func find(in e: EKEvent) -> URL? {
        let fields = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for field in fields {
            let text = field.replacingOccurrences(of: "&amp;", with: "&")
            let range = NSRange(text.startIndex..., in: text)
            for m in pattern.matches(in: text, range: range) {
                guard let r = Range(m.range, in: text) else { continue }
                var s = String(text[r])
                while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
                let lower = s.lowercased()
                guard hosts.contains(where: { lower.contains($0) }), let url = URL(string: s) else { continue }
                // Meet: open with the Google account that was invited.
                if lower.contains("meet.google.com/"), let me = Self.myEmail(e), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    var q = c.queryItems ?? []
                    if !q.contains(where: { $0.name == "authuser" }) { q.append(URLQueryItem(name: "authuser", value: me)) }
                    c.queryItems = q
                    return c.url ?? url
                }
                return url
            }
        }
        return nil
    }

    private static func myEmail(_ e: EKEvent) -> String? {
        if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.url.scheme == "mailto" {
            let addr = me.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            if addr.contains("@") { return addr }
        }
        let title = e.calendar?.title ?? ""
        return title.contains("@") ? title : nil
    }
}

struct Draft: Equatable {
    var day: Date
    var startMin: Int
    var endMin: Int
    var dragging: Bool
}

struct PopoverInfo: Equatable {
    let event: CalEvent
    let point: CGPoint
}

enum Span: Int, CaseIterable {
    case day = 1, three = 3, week = 7
    var label: String {
        switch self {
        case .day: return "Day"
        case .three: return "3 Days"
        case .week: return "Week"
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    @Published var span: Span {
        didSet { UserDefaults.standard.set(span.rawValue, forKey: "span") }
    }
    @Published var offset = 0
    @Published var showQuickAdd = false
    @Published var popover: PopoverInfo?
    @Published var draft: Draft?
    @Published var toast: String?
    @Published var insets = EdgeInsets()
    @Published var peek = false
    @Published var showHelp = false
    @Published var focusPromptTick = 0
    @Published var critterJumpAt: TimeInterval = 0
    @Published var visible = true
    @Published var promptFocused = false
    @Published var dropTargeted = false

    func celebrate() { critterJumpAt = Date().timeIntervalSinceReferenceDate }

    init() {
        span = Span(rawValue: UserDefaults.standard.integer(forKey: "span")) ?? .three
    }

    func flash(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    func closeAll() {
        showHelp = false
        showQuickAdd = false
        popover = nil
        draft = nil
    }

    func closeOverlays() -> Bool {
        if showHelp { showHelp = false; return true }
        if showQuickAdd { showQuickAdd = false; return true }
        if popover != nil { popover = nil; return true }
        if draft != nil { draft = nil; return true }
        return false
    }
}

enum Fmt {
    static let en = Locale(identifier: "en_GB")
    static func f(_ pattern: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = en
        d.dateFormat = pattern
        return d
    }
    static let time = f("HH:mm")
    static let weekday = f("EEEE")
    static let weekdayShort = f("EEE")
    static let monthYear = f("MMMM yyyy")
    static let dayMonth = f("d MMMM")
    static let dayNum = f("d")
    static let month = f("MMMM")
    static let promptDay = f("EEE d MMM")
    static let iso = f("yyyy-MM-dd'T'HH:mm")

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func until(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if !cal.isDate(date, inSameDayAs: now) {
            if cal.isDateInTomorrow(date) { return "tomorrow" }
            return weekday.string(from: date).lowercased()
        }
        let m = Int(date.timeIntervalSince(now) / 60)
        if m <= 0 { return "now" }
        if m < 60 { return "in \(m) min" }
        let h = m / 60, r = m % 60
        if h >= 24 { return "in \(h / 24) d" }
        return r == 0 ? "in \(h) h" : "in \(h) h \(r) min"
    }
}
