import AppKit
import SwiftUI

// MARK: - Free time as a message

extension CalendarStore {
    /// "Ich hätte Zeit: Do 20.11. 14–16 Uhr, Fr 21.11. 9–11 Uhr. Was passt dir?" Ready for WhatsApp.
    func freeTimeMessage(days: Int = 3, minimum: Int = 60) -> String? {
        let cal = Calendar.current
        let german = Profile.language.lowercased().hasPrefix("german") || Profile.language.lowercased().hasPrefix("deutsch")
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: german ? "de_DE" : "en_GB")
        dayFmt.dateFormat = german ? "EEEEEE d.M." : "EEE d MMM"
        func hm(_ d: Date) -> String {
            let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
            return m == 0 ? "\(h)" : String(format: "%d:%02d", h, m)
        }
        let or = german ? " oder " : " or "
        var parts: [String] = []
        var day = cal.startOfDay(for: now)
        var counted = 0
        while counted < days {
            if !cal.isDateInWeekend(day) {
                let slots = freeSlots(on: day, minimum: minimum).prefix(2)
                let label = cal.isDateInToday(day) ? (german ? "heute" : "today")
                    : cal.isDateInTomorrow(day) ? (german ? "morgen" : "tomorrow") : dayFmt.string(from: day)
                let times = slots.map { hm($0.0) + "–" + hm($0.1) + (german ? " Uhr" : "") }
                if !times.isEmpty { parts.append(label + " " + times.joined(separator: or)) }
                if !cal.isDateInToday(day) || !times.isEmpty { counted += 1 }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
            if parts.count >= 4 { break }
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + or + parts.last!
        return german ? "Ich hätte Zeit " + list + ". Was passt dir?" : "I'm free " + list + ". What works for you?"
    }
}

// MARK: - Day review

struct DayReview {
    struct Bucket { let category: Category; let minutes: Int; let count: Int }
    let day: Date
    let buckets: [Bucket]
    let tomorrowFirst: CalEvent?
    let tomorrowCount: Int
    let tomorrowFree: [(Date, Date)]
    let due: [Measure.Item]

    @MainActor
    init(store: CalendarStore) {
        let cal = Calendar.current
        day = cal.startOfDay(for: store.now)
        let today = store.timed(on: day)
        buckets = [Category.meeting, .focus, .work, .uni].compactMap { c in
            let evs = today.filter { $0.category == c }
            guard !evs.isEmpty else { return nil }
            return Bucket(category: c, minutes: evs.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }, count: evs.count)
        }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: day)!
        let t = store.timed(on: tomorrow)
        tomorrowFirst = t.first
        tomorrowCount = t.count
        tomorrowFree = store.freeSlots(on: tomorrow, minimum: 45)
        due = Measure.dueSoon(days: 7, now: store.now)
    }
}

// MARK: - Focus mode

/// While a Focus block runs: turn on Do Not Disturb through two Shortcuts the user creates once
/// ("Studio Focus On" / "Studio Focus Off"). Without them nothing happens.
@MainActor
final class FocusGuard {
    static let onName = "Studio Focus On"
    static let offName = "Studio Focus Off"
    private var activeID: String?
    private var shortcuts: Set<String> = []
    private var lastScan = Date.distantPast

    func tick(_ store: CalendarStore) {
        if Date().timeIntervalSince(lastScan) > 600 { scan() }
        guard shortcuts.contains(Self.onName) else { return }
        let running = store.events.first { !$0.allDay && $0.category == .focus && $0.start <= store.now && $0.end > store.now }
        if let running, activeID != running.id {
            activeID = running.id
            run(Self.onName)
        } else if running == nil, activeID != nil {
            activeID = nil
            if shortcuts.contains(Self.offName) { run(Self.offName) }
        }
    }

    var ready: Bool { shortcuts.contains(Self.onName) }

    private func scan() {
        lastScan = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        let reader = out.fileHandleForReading
        Self.readAll(reader) { [weak self] text in
            let names = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            self?.shortcuts = names
        }
    }

    nonisolated private static func readAll(_ h: FileHandle, done: @escaping @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in done(text) }
        }
    }

    private func run(_ name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
    }
}
