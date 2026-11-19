import EventKit
import Foundation

/// `--demo` (or `defaults write works.sonntag.studiocalendar demo -bool true`): a made-up week instead of your
/// calendar, for screenshots. Nothing is read from or written to your calendars, and nothing runs in the background.
enum Demo {
    static let on: Bool = CommandLine.arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "demo")

    private struct Item { let day: Int; let start: Double; let end: Double; let title: String; var tag = ""; var meet = false }

    /// Monday-based template; hours as decimals.
    private static let week: [Item] = [
        Item(day: 0, start: 9, end: 9.5, title: "Team standup", meet: true),
        Item(day: 0, start: 10, end: 12, title: "Focus: Pitch deck", tag: "[studio:focus]"),
        Item(day: 0, start: 14, end: 15, title: "Call · Lena", meet: true),
        Item(day: 1, start: 8.5, end: 10, title: "Lecture · Strategy", tag: "[studio:uni]"),
        Item(day: 1, start: 11, end: 12.5, title: "Focus: Q4 numbers", tag: "[studio:focus]"),
        Item(day: 1, start: 13, end: 14, title: "Lunch · Max", tag: "[studio:meeting]"),
        Item(day: 1, start: 16, end: 17, title: "Client review", tag: "[studio:work]"),
        Item(day: 2, start: 9, end: 11, title: "Focus: Product spec", tag: "[studio:focus]"),
        Item(day: 2, start: 11.5, end: 12, title: "Sync · Design", meet: true),
        Item(day: 2, start: 15, end: 16.5, title: "Workshop", tag: "[studio:uni]"),
        Item(day: 3, start: 9.5, end: 10.5, title: "Interview · Jonas", meet: true),
        Item(day: 3, start: 12, end: 13, title: "Lunch · Anna", tag: "[studio:meeting]"),
        Item(day: 3, start: 14, end: 16, title: "Focus: Website copy", tag: "[studio:focus]"),
        Item(day: 3, start: 16.5, end: 17.5, title: "Ops review", tag: "[studio:work]"),
        Item(day: 4, start: 10, end: 11, title: "Seminar", tag: "[studio:uni]"),
        Item(day: 4, start: 11.5, end: 13, title: "Focus: Investor update", tag: "[studio:focus]"),
        Item(day: 4, start: 15, end: 15.5, title: "Coffee · Mia", tag: "[studio:meeting]"),
        Item(day: 5, start: 11, end: 12.5, title: "Brunch · Tom", tag: "[studio:meeting]"),
        Item(day: 6, start: 17, end: 18, title: "Focus: Plan the week", tag: "[studio:focus]"),
    ]

    static func events(_ ek: EKEventStore, now: Date = Date()) -> [CalEvent] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        guard let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        func at(_ day: Date, _ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }
        func make(_ title: String, _ s: Date, _ e: Date, tag: String, meet: Bool) -> CalEvent {
            let ev = EKEvent(eventStore: ek)
            ev.title = title
            ev.startDate = s
            ev.endDate = e
            ev.notes = tag
            if meet { ev.url = URL(string: "https://meet.google.com/abc-defg-hij") }
            return CalEvent(ev)
        }
        var out: [CalEvent] = []
        for week in -1...1 {
            for item in Self.week {
                guard let day = cal.date(byAdding: .day, value: week * 7 + item.day, to: monday) else { continue }
                out.append(make(item.title, at(day, item.start), at(day, item.end), tag: item.tag, meet: item.meet))
            }
        }
        // Something coming up today, so "Up next" and Join show.
        let hour = cal.component(.hour, from: now)
        if hour >= 6, hour < 21 {
            let next = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now)!.addingTimeInterval(3600)
            out.removeAll { $0.start < next.addingTimeInterval(5400) && $0.end > next && cal.isDate($0.start, inSameDayAs: now) }
            out.append(make("Call · Alex", next, next.addingTimeInterval(1800), tag: "", meet: true))
            out.append(make("Focus: Launch post", next.addingTimeInterval(2700), next.addingTimeInterval(5400), tag: "[studio:focus]", meet: false))
        }
        return out
    }
}
