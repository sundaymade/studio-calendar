import AppKit
import EventKit

/// Claude Meetings (claude.ai, Team plan, Google Meet only). Claude joins every Meet call on the calendar of the
/// account it is connected to and mails that account a recap with a link. So: that account goes on every call,
/// and after the call the recap is filed as a note in the vault and in the matching Measure project.
enum ClaudeMeetings {
    /// On once you name the account (`claudeMeetingsAccount`), unless switched off with `claudeMeetings false`.
    static var enabled: Bool { !account.isEmpty && (UserDefaults.standard.object(forKey: "claudeMeetings") as? Bool ?? true) }

    /// The Google account Claude Meetings watches. Being on the invite = Claude joins, the recap lands there.
    static var account: String {
        (UserDefaults.standard.string(forKey: "claudeMeetingsAccount") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isMeet(_ url: URL?) -> Bool { url?.host?.lowercased().contains("meet.google.com") == true }

    static func joins(_ e: EKEvent, meeting: URL?) -> Bool {
        guard enabled, isMeet(meeting) else { return false }
        let me = account
        if e.calendar?.title.lowercased() == me { return true }
        func mail(_ p: EKParticipant?) -> String? {
            guard let u = p?.url, u.scheme == "mailto" else { return nil }
            return u.absoluteString.dropFirst("mailto:".count).removingPercentEncoding?.lowercased()
        }
        if mail(e.organizer) == me { return true }
        return e.attendees?.contains { mail($0) == me } ?? false
    }

    /// "+ Claude" makes sense for a call that has not ended, that Claude can reach (Meet, or no call link yet)
    /// and that is a meeting, not a focus block or an in-person appointment.
    static func canAdd(_ ev: CalEvent, now: Date = Date()) -> Bool {
        guard enabled, ev.editable, !ev.claudeJoins, !ev.allDay, !ev.isTask, ev.end > now else { return false }
        if let url = ev.meetingURL { return isMeet(url) }
        return ev.category == .meeting && ev.location == nil
    }

    /// Puts the Claude account (and a Meet link if missing) on the event. Nobody else gets a mail.
    @MainActor
    static func add(to ev: CalEvent, store: CalendarStore, ui: UIState) {
        ui.flash("Adding Claude to “\(ev.title)” …")
        let fallback = store.calendarName.contains("@") ? store.calendarName : "primary"
        let calendar = ev.calendarTitle.contains("@") ? ev.calendarTitle : fallback
        Task { @MainActor in
            let r = await GoogleInvite.send(title: ev.title, start: ev.start, end: ev.end, guests: [], meet: true,
                                            claude: true, existing: ev, calendar: calendar)
            if r.ok {
                ui.flash("Claude joins “\(ev.title)”")
                ui.celebrate()
                store.ek.refreshSourcesIfNecessary()
                for delay in [4.0, 20.0] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    store.ek.refreshSourcesIfNecessary()
                    store.reload()
                }
            } else if r.notFound {
                ui.flash("Only works for Google Calendar events")
            } else {
                ui.flash("Could not add Claude. Check the Google Calendar connector.")
            }
        }
    }
}

// MARK: - After the call: file the recap

/// Polls Gmail (read only) for the Claude Meetings recap of calls that just ended, writes a note into the
/// vault, logs it in the matching Measure project and keeps the action items for the evening check, where
/// You tick what goes on your list. Nothing is added to your to-dos without that tick.
@MainActor
final class MeetingNotes: ObservableObject {
    struct Action: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        let text: String
        let owner: String
        let meeting: String
        let project: String
        var take = false
    }

    @Published var actions: [Action] = [] { didSet { save() } }

    weak var ui: UIState?
    private var running = false
    private var lastScan = Date.distantPast
    private let d = UserDefaults.standard

    init() {
        if let data = d.data(forKey: "meetingActions"), let a = try? JSONDecoder().decode([Action].self, from: data) {
            actions = a
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(actions) { d.set(data, forKey: "meetingActions") }
    }

    /// Called every 30 s; looks at most every 5 minutes, one call at a time.
    func tick(_ store: CalendarStore) {
        guard ClaudeMeetings.enabled, !running, Date().timeIntervalSince(lastScan) > 300 else { return }
        lastScan = Date()
        let now = Date()
        let cal = Calendar.current
        let days = [now, cal.date(byAdding: .day, value: -1, to: now)!]
        var state = d.dictionary(forKey: "meetingNotes") as? [String: [Double]] ?? [:]
        let due = days.flatMap { store.timed(on: $0) }.filter { ev in
            guard ev.claudeJoins, ev.end <= now.addingTimeInterval(-10 * 60), ev.end >= now.addingTimeInterval(-26 * 3600) else { return false }
            let s = state[ev.id] ?? [0, 0]          // [tries, last try]; tries -1 = filed
            return s[0] >= 0 && s[0] < 8 && now.timeIntervalSince1970 - s[1] > 20 * 60
        }
        guard let ev = due.first else { return }
        running = true
        let tries = (state[ev.id]?[0] ?? 0) + 1
        state[ev.id] = [tries, now.timeIntervalSince1970]
        d.set(state, forKey: "meetingNotes")
        Task { @MainActor in
            defer { self.running = false }
            guard let recap = await Self.fetch(ev) else { return }
            var state = self.d.dictionary(forKey: "meetingNotes") as? [String: [Double]] ?? [:]
            state[ev.id] = [-1, Date().timeIntervalSince1970]
            self.d.set(state.filter { $0.value[1] > Date().timeIntervalSince1970 - 14 * 86400 }, forKey: "meetingNotes")
            let file = Self.write(recap, for: ev)
            if !recap.project.isEmpty { Self.log(recap, title: ev.title, file: file) }
            let new = recap.actions.map { Action(text: $0.text, owner: $0.owner, meeting: ev.title, project: recap.project) }
            self.actions.append(contentsOf: new)
            let n = new.count
            self.ui?.flash("Notes filed · " + ev.title + (n > 0 ? " · \(n) action\(n == 1 ? "" : "s") for tonight" : ""))
        }
    }

    // MARK: Claude reads the recap mail

    struct Recap {
        var link = ""
        var summary = ""
        var topics: [String] = []
        var decisions: [String] = []
        var actions: [(text: String, owner: String)] = []
        var people: [String] = []
        var project = ""
    }

    static let tools = ["mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread"]

    private static func fetch(_ ev: CalEvent) async -> Recap? {
        let day = Fmt.f("yyyy/MM/dd").string(from: ev.start)
        let when = Fmt.f("EEEE d MMMM yyyy").string(from: ev.start) + ", " + Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end)
        let projects = Measure.projects().map { "  \($0.id) · \($0.company) · \($0.title)" }.joined(separator: "\n")
        let lang = Profile.language
        let prompt = """
        A Google Meet call has ended: "\(ev.title)", \(when) (\(TimeZone.current.identifier)).
        Claude Meetings took notes and mails a recap with a link to the meeting page.
        1. Call search_threads with query: from:(claude.com OR anthropic.com) after:\(day)
        2. Pick the recap of this call (subject or text names the meeting, its people or its time). Not there yet: reply exactly {"found":false}
        3. Call get_thread on it and read the whole recap.
        4. Reply with only this JSON:
        {"found":true,"link":"<meeting page link from the mail>","summary":"<2-3 short sentences, \(lang)>",
         "topics":["<one short line each, \(lang)>"],"decisions":["<\(lang)>"],
         "actions":[{"text":"<\(lang), starts with the verb>","owner":"<name as written, or empty>"}],
         "people":["<names as written>"],"project":"<one id from the list that this call is about, or empty>"}
        Use only what the recap says. Invent nothing. Empty lists are fine.
        Projects (id · company · title):
        \(projects.isEmpty ? "  (none)" : projects)
        """
        let system = "You file \(Profile.name)'s meeting notes. Read only: use the Gmail tools to find and read one email. Never send, draft, label or change anything."
        guard let answer = await ClaudeOnce.ask(system: system, prompt: prompt, tools: tools) else { return nil }
        guard let a = answer.firstIndex(of: "{"), let b = answer.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(answer[a...b].utf8)) as? [String: Any],
              obj["found"] as? Bool == true else { return nil }
        var r = Recap()
        r.link = obj["link"] as? String ?? ""
        r.summary = obj["summary"] as? String ?? ""
        r.topics = obj["topics"] as? [String] ?? []
        r.decisions = obj["decisions"] as? [String] ?? []
        r.people = obj["people"] as? [String] ?? []
        r.actions = (obj["actions"] as? [[String: Any]] ?? []).compactMap { x in
            guard let t = x["text"] as? String, !t.isEmpty else { return nil }
            return (t, x["owner"] as? String ?? "")
        }
        let p = obj["project"] as? String ?? ""
        r.project = Measure.projects().contains { $0.id == p } ? p : ""
        return r
    }

    // MARK: vault note and Measure log

    static var folder: URL {
        if let custom = UserDefaults.standard.string(forKey: "meetingNotesFolder") { return URL(fileURLWithPath: custom) }
        return ChatModel.workDir().deletingLastPathComponent().appendingPathComponent("Meetings", isDirectory: true)
    }

    @discardableResult
    private static func write(_ r: Recap, for ev: CalEvent) -> String {
        let en = { (f: String) -> DateFormatter in let x = Fmt.f(f); x.locale = Locale(identifier: "en_US_POSIX"); return x }
        let clean = ev.title.components(separatedBy: CharacterSet(charactersIn: "/:\\|#^[]")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = en("MM-dd-yy EEE").string(from: ev.start) + " " + clean
        let dir = folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = base + ".md", n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { name = base + " \(n).md"; n += 1 }

        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        let company = Measure.projects().first { $0.id == r.project }?.company ?? ""
        let tag = company.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        var md = "---\n"
        md += "created: " + en("yyyy-MM-dd'T'HH:mm").string(from: Date()) + "\n"
        md += "tags: [call" + (tag.isEmpty ? "" : ", " + tag) + ", \"#claude\"]\n"
        md += "date: " + en("yyyy-MM-dd").string(from: ev.start) + "\n"
        md += "start: " + q(Fmt.time.string(from: ev.start)) + "\nend: " + q(Fmt.time.string(from: ev.end)) + "\n"
        md += "people: [" + r.people.map { q("[[" + $0 + "]]") }.joined(separator: ", ") + "]\n"
        md += "summary: " + q(r.summary) + "\n"
        md += "source: Claude Meetings\n"
        if !r.link.isEmpty { md += "link: " + r.link + "\n" }
        if !r.project.isEmpty { md += "project: " + r.project + "\n" }
        md += "unread: true\n---\n\n"
        md += "> [!tldr]\n> " + (r.summary.isEmpty ? ev.title : r.summary) + "\n"
        if !r.topics.isEmpty { md += "\n## Key Topics\n\n" + r.topics.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if !r.decisions.isEmpty { md += "\n## Decisions\n\n" + r.decisions.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if !r.actions.isEmpty {
            md += "\n## Action Items\n\n" + r.actions.map { "- [ ] " + $0.text + ($0.owner.isEmpty ? "" : " (" + $0.owner + ")") }.joined(separator: "\n") + "\n"
        }
        if !r.link.isEmpty { md += "\n[Meeting in Claude](" + r.link + ")\n" }
        let url = dir.appendingPathComponent(name)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url.lastPathComponent
    }

    private static func log(_ r: Recap, title: String, file: String) {
        let first = r.summary.components(separatedBy: ". ").first ?? ""
        var text = "Meeting „\(title)“"
        if !first.isEmpty { text += ": " + first.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        text += ". Notiz: " + folder.lastPathComponent + "/" + file
        Measure.project(["log", Measure.shortID(r.project), text, "--quelle", "Claude"])
    }
}
