import EventKit
import Foundation

/// `StudioCalendar --find <words> [--days N]`: read-only search over every calendar on this Mac,
/// N days back and ahead (default 365). The planner uses it for events outside its 14-day view.
enum CalendarFind {
    static func run(_ args: [String]) {
        var words: [String] = []
        var days = 365
        var i = 0
        while i < args.count {
            if args[i] == "--days", i + 1 < args.count { days = Int(args[i + 1]) ?? days; i += 2; continue }
            words.append(args[i].lowercased())
            i += 1
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            print("No calendar access."); return
        }
        let ek = EKEventStore()
        let now = Date()
        let cal = Calendar.current
        var hits: [EKEvent] = []
        // EventKit only searches up to four years per call; go in one-year steps.
        var from = cal.date(byAdding: .day, value: -days, to: now)!
        let until = cal.date(byAdding: .day, value: days, to: now)!
        while from < until {
            let to = min(cal.date(byAdding: .year, value: 1, to: from)!, until)
            hits += ek.events(matching: ek.predicateForEvents(withStart: from, end: to, calendars: nil)).filter { e in
                let text = [e.title, e.location, e.notes, e.calendar?.title].compactMap { $0 }.joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            from = to
        }
        var seen = Set<String>()
        let day = Fmt.f("EEE dd.MM.yyyy")
        let unique = hits.sorted { $0.startDate < $1.startDate }.filter {
            seen.insert(($0.title ?? "") + "\($0.startDate.timeIntervalSince1970)").inserted
        }
        if unique.isEmpty { print("No events found."); return }
        for e in unique.prefix(40) {
            let when = e.isAllDay ? day.string(from: e.startDate) + " all day"
                : day.string(from: e.startDate) + " " + Fmt.time.string(from: e.startDate) + "–"
                    + (cal.isDate(e.endDate, inSameDayAs: e.startDate) ? "" : day.string(from: e.endDate) + " ")
                    + Fmt.time.string(from: e.endDate)
            print("\(when) · \(e.title ?? "Untitled") · [\(e.calendar?.title ?? "")]")
            if let loc = e.location, !loc.isEmpty { print("  at: \(loc)") }
            if let notes = e.notes?.replacingOccurrences(of: "\n", with: " "), !notes.isEmpty { print("  " + notes.prefix(200)) }
        }
        if unique.count > 40 { print("… \(unique.count - 40) more. Use more words.") }
    }
}
