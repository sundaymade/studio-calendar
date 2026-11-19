import AppKit
import SwiftUI

// MARK: - Claude, once

/// One question to Claude Code on this Mac: no tools, no session. Gives up after 90 seconds.
enum ClaudeOnce {
    @MainActor
    /// `tools`: the only connector tools Claude may call (e.g. Google Calendar). Empty = no tools at all.
    static func ask(system: String, prompt: String, tools: [String] = []) async -> String? {
        guard let claude = ChatModel.claudePath() else { return nil }
        let dir = ChatModel.workDir()
        let model = UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet"
        var args = ["-p", "--output-format", "json", "--tools", "", "--model", model, "--append-system-prompt", system,
                    "--settings", #"{"autoMemoryEnabled":false}"#]
        if tools.isEmpty { args.append("--strict-mcp-config") } else { args += ["--allowedTools", tools.joined(separator: ",")] }
        return await withCheckedContinuation { cont in
            run(claude: claude, dir: dir, args: args, prompt: prompt) { cont.resume(returning: $0) }
        }
    }

    nonisolated private static func run(claude: String, dir: URL, args: [String], prompt: String,
                                        done: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
            p.environment = env
            let input = Pipe(), out = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { done(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if p.isRunning { p.terminate() } }
            try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["is_error"] as? Bool != true, let result = obj["result"] as? String else { done(nil); return }
            done(result)
        }
    }
}

// MARK: - Morning plan and evening check

/// Morning: tick off what is already done, Claude fits the rest into the day, one click puts it in.
/// Evening: tick off what got done, the rest moves to tomorrow or back onto the Measure list.
@MainActor
final class Ritual: ObservableObject {
    enum Mode: Equatable { case morning, evening }
    enum Stage: Equatable { case check, planning, plan }
    enum Fate: Equatable { case done, tomorrow, list }

    struct Todo: Identifiable, Equatable {
        let id: String
        let title: String
        let project: String
        var done = false
    }

    struct Block: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let start: Date
        let end: Date
        let todo: String?
    }

    struct Row: Identifiable, Equatable {
        let event: CalEvent
        var fate: Fate
        var id: String { event.id }
    }

    @Published private(set) var mode: Mode?
    @Published var stage: Stage = .check
    @Published var todos: [Todo] = []
    @Published var blocks: [Block] = []
    @Published var note = ""
    @Published var rows: [Row] = []
    /// Action items from today's Claude Meetings recaps. Only the ticked ones go on the list.
    @Published var meetingActions: [MeetingNotes.Action] = []

    weak var store: CalendarStore?
    weak var notes: MeetingNotes?
    weak var ui: UIState?
    var onClose: (() -> Void)?
    private var planTask: Task<Void, Never>?

    var isOpen: Bool { mode != nil }

    func open(_ m: Mode) {
        guard let store else { return }
        planTask?.cancel()
        todos = Measure.openTodos().map { Todo(id: $0.id, title: $0.title, project: $0.project) }
        blocks = []
        note = ""
        stage = .check
        rows = []
        meetingActions = []
        if m == .evening {
            meetingActions = Array((notes?.actions ?? []).prefix(6))
            let work = store.timed(on: store.now).filter { $0.isTask && $0.editable }
            rows = work.map { Row(event: $0, fate: .tomorrow) }
            let linked = Set(work.compactMap(\.todoID))
            todos.removeAll { linked.contains($0.id) }
        }
        mode = m
    }

    func close() {
        planTask?.cancel()
        mode = nil
        onClose?()
    }

    /// Enter.
    func primary() {
        switch (mode, stage) {
        case (.morning, .check): plan()
        case (.morning, .plan): applyPlan()
        case (.evening, _): closeDay()
        default: break
        }
    }

    func toggle(_ id: String) {
        if let i = todos.firstIndex(where: { $0.id == id }) { todos[i].done.toggle() }
    }

    func toggleRow(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].fate = rows[i].fate == .done ? .tomorrow : .done
    }

    func setFate(_ id: String, _ fate: Fate) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].fate = fate }
    }

    func toggleAction(_ id: String) {
        if let i = meetingActions.firstIndex(where: { $0.id == id }) { meetingActions[i].take.toggle() }
    }

    func remove(_ block: Block) { blocks.removeAll { $0.id == block.id } }

    func addTodo(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let id = Measure.add(t) {
            todos.insert(Todo(id: id, title: t, project: ""), at: 0)
        } else {
            ui?.flash("Could not write to Measure")
        }
    }

    // MARK: morning

    func plan() {
        guard let store else { return }
        let open = todos.filter { !$0.done }
        guard !open.isEmpty else { applyPlan(); return }
        stage = .planning
        let system = planSystem(store)
        let prompt = "To-dos to fit into today (id · title [project]):\n" + open.map {
            "\($0.id) · \($0.title)" + ($0.project.isEmpty ? "" : " [\($0.project)]")
        }.joined(separator: "\n")
        planTask = Task {
            let answer = await ClaudeOnce.ask(system: system, prompt: prompt)
            guard !Task.isCancelled, mode == .morning, stage == .planning else { return }
            let parsed = answer.map { parse($0, known: Set(open.map(\.id))) } ?? []
            if parsed.isEmpty {
                blocks = localPlan(open, store: store)
                note = answer == nil ? "Claude did not answer, so they go in by order." : ChatModel.stripBlock(answer ?? "")
            } else {
                blocks = parsed
                note = ChatModel.stripBlock(answer ?? "")
            }
            stage = .plan
        }
    }

    private func planSystem(_ store: CalendarStore) -> String {
        let now = store.now
        let today = store.timed(on: now).map { "  " + Fmt.time.string(from: $0.start) + "–" + Fmt.time.string(from: $0.end) + " " + $0.title }
        let free = store.freeSlots(on: now, minimum: 30).map { Fmt.time.string(from: $0.0) + "–" + Fmt.time.string(from: $0.1) }
        return """
        You plan \(Profile.name)'s day. Now: \(Fmt.f("EEEE d MMMM yyyy, HH:mm").string(from: now)) (\(TimeZone.current.identifier)).
        Today's calendar, fixed:
        \(today.isEmpty ? "  (nothing)" : today.joined(separator: "\n"))
        Free today: \(free.isEmpty ? "none" : free.joined(separator: ", "))
        Deadlines from their projects, context only:
        \(Measure.context(limit: 12) ?? "  (none)")

        Put the to-dos into today's free time:
        - One block per to-do, title "Focus: <task in at most 5 words>", 30–120 min by how big the task is.
        - 15 min between blocks. Keep a lunch break around 12:30–13:30 if the day allows. Never overlap the calendar.
        - Most urgent first: deadlines, people waiting. At most 5 blocks. If something does not fit, leave it out.
        - Answer with one short line in \(Profile.language) (what goes first and why), then exactly one block:
        ```calendar
        [{"op":"add","title":"Focus: …","start":"YYYY-MM-DDTHH:MM","end":"YYYY-MM-DDTHH:MM","kind":"focus","todo":"<to-do id>"}]
        ```
        """
    }

    private func parse(_ text: String, known: Set<String>) -> [Block] {
        guard let body = ChatModel.block("calendar", in: text), let data = body.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let cal = Calendar.current
        let earliest = Date().addingTimeInterval(-10 * 60)
        return arr.compactMap { o in
            guard let t = o["title"] as? String,
                  let s = (o["start"] as? String).flatMap({ Fmt.iso.date(from: String($0.prefix(16))) }),
                  let e = (o["end"] as? String).flatMap({ Fmt.iso.date(from: String($0.prefix(16))) }),
                  e > s, s >= earliest, cal.isDateInToday(s) else { return nil }
            let todo = (o["todo"] as? String).flatMap { known.contains($0) ? $0 : nil }
            return Block(title: t, start: s, end: e, todo: todo)
        }.sorted { $0.start < $1.start }
    }

    /// Fallback without Claude: one hour per to-do, in order, into the free gaps.
    private func localPlan(_ open: [Todo], store: CalendarStore) -> [Block] {
        var out: [Block] = []
        var slots = store.freeSlots(on: store.now, minimum: 60)
        for t in open.prefix(4) {
            guard let i = slots.firstIndex(where: { $0.1.timeIntervalSince($0.0) >= 3600 }) else { break }
            let s = slots[i].0, e = s.addingTimeInterval(3600)
            out.append(Block(title: "Focus: " + t.title, start: s, end: e, todo: t.id))
            slots[i].0 = e.addingTimeInterval(15 * 60)
        }
        return out
    }

    /// Plan without Claude, for previews.
    func previewPlan() {
        guard let store else { return }
        blocks = localPlan(todos.filter { !$0.done }, store: store)
        note = "Preview: one hour each, in order."
        stage = .plan
    }

    func applyPlan() {
        guard let store else { return }
        var added = 0
        for b in blocks where store.add(title: b.title, start: b.start, end: b.end, kind: .focus, todo: b.todo) { added += 1 }
        let done = todos.filter(\.done)
        for t in done { Measure.markDone(t.id) }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) \(added == 1 ? "block" : "blocks") planned") }
        if !done.isEmpty { parts.append("\(done.count) ticked off") }
        ui?.flash(parts.isEmpty ? "Have a good day" : "Your day is set · " + parts.joined(separator: " · "))
        if added > 0 || !done.isEmpty { ui?.celebrate() }
        close()
    }

    // MARK: evening

    func closeDay() {
        guard let store else { return }
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: store.now))!
        var done = 0, moved = 0, listed = 0
        for r in rows {
            let ev = r.event
            switch r.fate {
            case .done:
                done += 1
                if let id = ev.todoID { Measure.markDone(id) }
            case .list:
                if ev.todoID != nil || Measure.add(Self.task(ev.title)) != nil { listed += 1 }
            case .tomorrow:
                let length = ev.end.timeIntervalSince(ev.start)
                if let slot = store.freeSlots(on: tomorrow, minimum: max(15, Int(length / 60))).first,
                   store.move(ev, start: slot.0, end: slot.0.addingTimeInterval(length)) {
                    moved += 1
                } else if ev.todoID != nil || Measure.add(Self.task(ev.title)) != nil {
                    listed += 1
                }
            }
        }
        for t in todos where t.done {
            Measure.markDone(t.id)
            done += 1
        }
        for a in meetingActions where a.take {
            let ok = a.project.isEmpty ? Measure.add(a.text) != nil : Measure.project(["todo", Measure.shortID(a.project), a.text])
            if ok { listed += 1 }
        }
        let seen = Set(meetingActions.map(\.id))
        notes?.actions.removeAll { seen.contains($0.id) }
        var parts: [String] = []
        if done > 0 { parts.append("\(done) done") }
        if moved > 0 { parts.append("\(moved) moved to " + Fmt.weekday.string(from: tomorrow)) }
        if listed > 0 { parts.append("\(listed) on your list") }
        ui?.flash(parts.isEmpty ? "Good night" : "Day closed · " + parts.joined(separator: " · "))
        if done > 0 { ui?.celebrate() }
        close()
    }

    /// "Focus: Pitch deck" → "Pitch deck"
    static func task(_ title: String) -> String {
        for p in ["Focus: ", "Focus · ", "Focus - "] where title.hasPrefix(p) { return String(title.dropFirst(p.count)) }
        return title
    }
}

// MARK: - Views

struct RitualView: View {
    @EnvironmentObject var ritual: Ritual
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th

    var body: some View {
        ZStack(alignment: .topLeading) {
            th.bg
            HStack(alignment: .top, spacing: 0) {
                left
                    .padding(EdgeInsets(top: 38, leading: 48, bottom: 30, trailing: 40))
                    .frame(width: 430, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(th.hair).frame(width: 1)
                right
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(EdgeInsets(top: 44, leading: 64, bottom: 40, trailing: 64))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(ui.insets)
        }
    }

    // MARK: left

    @ViewBuilder private var left: some View {
        let now = store.now
        VStack(alignment: .leading, spacing: 0) {
            BigDay(text: Fmt.dayNum.string(from: now))
                .foregroundStyle(th.fg)
                .padding(.leading, -12)
                .frame(height: 176)
            Rectangle().fill(th.fg).frame(height: 2).padding(.top, 22)
            HStack {
                Label11(text: Fmt.weekday.string(from: now), color: th.fg)
                Spacer()
                Label11(text: ritual.mode == .evening ? "Evening" : "Morning", color: th.fg)
            }
            .padding(.top, 10)
            if ritual.mode == .evening { eveningLeft.padding(.top, 34) } else { morningLeft.padding(.top, 34) }
            Spacer(minLength: 0)
        }
    }

    private var morningLeft: some View {
        let fixed = store.timed(on: store.now).filter { !$0.isTask }
        return VStack(alignment: .leading, spacing: 0) {
            Label11(text: "Fixed today").padding(.bottom, 6)
            if fixed.isEmpty {
                Text("Nothing fixed. The day is yours.").font(.system(size: 14)).foregroundStyle(th.muted).padding(.vertical, 9)
            }
            ForEach(fixed.prefix(8)) { ev in
                HStack(spacing: 10) {
                    Rectangle().fill(th.fill(ev.category)).frame(width: 10, height: 10)
                    Text(Fmt.time.string(from: ev.start)).font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
                        .frame(width: 46, alignment: .leading)
                    Text(ev.title).font(.system(size: 14, weight: .medium)).foregroundStyle(th.fg).lineLimit(2)
                    Spacer(minLength: 8)
                    if ev.meetingURL != nil { Text("call").font(Theme.mono(11, .regular)).foregroundStyle(th.muted) }
                }
                .padding(.vertical, 9)
                .opacity(ev.end <= store.now ? 0.4 : 1)
                .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
            }
        }
    }

    private var eveningLeft: some View {
        let r = DayReview(store: store)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: r.day)!
        return VStack(alignment: .leading, spacing: 0) {
            if r.buckets.isEmpty {
                Text("A day without blocks.").font(.system(size: 22, weight: .semibold)).foregroundStyle(th.fg)
            }
            ForEach(r.buckets, id: \.category) { b in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.duration(TimeInterval(b.minutes * 60)))
                        .font(.system(size: 34, weight: .semibold)).kerning(-1)
                        .foregroundStyle(th.fg)
                    Rectangle().fill(th.fill(b.category)).frame(width: 10, height: 10)
                    Label11(text: name(b.category))
                }
                .padding(.bottom, 6)
            }
            Label11(text: "Tomorrow · " + Fmt.weekday.string(from: tomorrow)).padding(.top, 26).padding(.bottom, 6)
            if let first = r.tomorrowFirst {
                Text("Starts " + Fmt.time.string(from: first.start) + " · " + first.title)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(th.fg).lineLimit(2)
            } else {
                Text("Nothing planned yet").font(.system(size: 14)).foregroundStyle(th.muted)
            }
            if let free = r.tomorrowFree.first {
                Text("Free from " + Fmt.time.string(from: free.0)).font(Theme.mono(12, .regular)).foregroundStyle(th.muted).padding(.top, 4)
            }
        }
    }

    private func name(_ c: Category) -> String {
        switch c {
        case .meeting: return "Meetings"
        case .focus: return "Focus"
        case .work: return Profile.workLabel
        case .uni: return Profile.studyLabel
        }
    }

    // MARK: right

    @ViewBuilder private var right: some View {
        switch (ritual.mode, ritual.stage) {
        case (.evening, _): evening
        case (_, .planning): planning
        case (_, .plan): planView
        default: morning
        }
    }

    private func heading(_ label: String, _ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label11(text: label)
            Text(title).font(.system(size: 44, weight: .semibold)).kerning(-1.4).foregroundStyle(th.fg)
            Text(sub).font(.system(size: 15)).foregroundStyle(th.muted)
        }
        .padding(.bottom, 26)
    }

    private var morning: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Good morning · \(ritual.todos.count) open", "What’s done already?", "Tick it off. The rest goes into today.")
            ForEach(ritual.todos.prefix(9)) { t in
                CheckRow(on: t.done, title: t.title, detail: t.project) { ritual.toggle(t.id) }
            }
            if ritual.todos.count > 9 {
                Text("+\(ritual.todos.count - 9) more in Measure").font(Theme.mono(12, .regular)).foregroundStyle(th.muted).padding(.vertical, 8)
            }
            AddTodoField().padding(.top, 4)
            HStack(spacing: 8) {
                StudioButton(title: ritual.todos.contains { !$0.done } ? "Plan my day" : "Done", hint: "↩", filled: true) { ritual.primary() }
                StudioButton(title: "Not now", hint: "esc") { ritual.close() }
            }
            .padding(.top, 28)
        }
    }

    private var planning: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Planning", "Fitting it in …", "Claude puts your to-dos around the fixed things.")
            ProgressView().controlSize(.small)
            StudioButton(title: "Back") { ritual.stage = .check }
        }
    }

    private var planView: some View {
        let fixed = store.timed(on: store.now).filter { $0.end > store.now }
        let items: [(Date, AnyView)] = fixed.map { ev in
            (ev.start, AnyView(PlanLine(time: Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end), title: ev.title,
                                        color: th.fill(ev.category), fixed: true, remove: nil)))
        } + ritual.blocks.map { b in
            (b.start, AnyView(PlanLine(time: Fmt.time.string(from: b.start) + "–" + Fmt.time.string(from: b.end), title: b.title,
                                       color: th.fill(.focus), fixed: false, remove: { ritual.remove(b) })))
        }
        return VStack(alignment: .leading, spacing: 0) {
            heading("Your day", ritual.blocks.isEmpty ? "Nothing fits today." : "Here’s your day.", ritual.note)
            ForEach(Array(items.sorted { $0.0 < $1.0 }.prefix(12).enumerated()), id: \.offset) { _, item in item.1 }
            HStack(spacing: 8) {
                StudioButton(title: "Put it in", hint: "↩", filled: true) { ritual.applyPlan() }
                StudioButton(title: "Back") { ritual.stage = .check }
                StudioButton(title: "Not now", hint: "esc") { ritual.close() }
            }
            .padding(.top, 28)
        }
    }

    private var evening: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Evening check", "What got done?", "Tick what you finished. The rest moves to tomorrow or back on your list.")
            if ritual.rows.isEmpty {
                Text("No work blocks today.").font(.system(size: 15)).foregroundStyle(th.muted).padding(.bottom, 10)
            }
            ForEach(ritual.rows) { r in
                HStack(spacing: 14) {
                    CheckRow(on: r.fate == .done, title: r.event.title,
                             detail: Fmt.time.string(from: r.event.start) + "–" + Fmt.time.string(from: r.event.end)) { ritual.toggleRow(r.id) }
                    if r.fate != .done {
                        HStack(spacing: 0) {
                            StudioButton(title: "Tomorrow", filled: r.fate == .tomorrow) { ritual.setFate(r.id, .tomorrow) }
                            StudioButton(title: "List", filled: r.fate == .list) { ritual.setFate(r.id, .list) }
                        }
                    }
                }
            }
            if !ritual.meetingActions.isEmpty {
                Label11(text: "From your calls · tick what goes on your list").padding(.top, 26).padding(.bottom, 6)
                ForEach(ritual.meetingActions) { a in
                    CheckRow(on: a.take, title: a.text, detail: a.owner.isEmpty ? a.meeting : a.owner, strike: false) { ritual.toggleAction(a.id) }
                }
            }
            if !ritual.todos.isEmpty {
                Label11(text: "Also on your list").padding(.top, 26).padding(.bottom, 6)
                ForEach(ritual.todos.prefix(6)) { t in
                    CheckRow(on: t.done, title: t.title, detail: t.project) { ritual.toggle(t.id) }
                }
            }
            HStack(spacing: 8) {
                StudioButton(title: "Close the day", hint: "↩", filled: true) { ritual.primary() }
                StudioButton(title: "Later", hint: "esc") { ritual.close() }
            }
            .padding(.top, 28)
        }
    }
}

struct CheckRow: View {
    @Environment(\.theme) var th
    let on: Bool
    let title: String
    let detail: String
    /// Off for "take this", where a tick means yes, not done.
    var strike = true
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Rectangle().fill(on ? th.fg : Color.clear).frame(width: 20, height: 20)
                    Rectangle().stroke(th.fg, lineWidth: 1.5).frame(width: 20, height: 20)
                    if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(th.bg) }
                }
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(on && strike ? th.muted : th.fg)
                    .strikethrough(on && strike, color: th.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                if !detail.isEmpty {
                    Text(detail).font(Theme.mono(12, .regular)).foregroundStyle(th.muted).lineLimit(1)
                }
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel((on ? "Done: " : "Open: ") + title)
    }
}

struct PlanLine: View {
    @Environment(\.theme) var th
    let time: String
    let title: String
    let color: Color
    let fixed: Bool
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Rectangle().fill(color).frame(width: 12, height: 12)
            Text(time).font(Theme.mono(13, .regular)).foregroundStyle(th.muted).frame(width: 110, alignment: .leading)
            Text(title)
                .font(.system(size: fixed ? 15 : 18, weight: fixed ? .regular : .semibold))
                .foregroundStyle(fixed ? th.muted : th.fg)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let remove {
                Button(action: remove) { Text("✕").font(Theme.mono(12)).foregroundStyle(th.muted).frame(width: 24, height: 24) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove " + title)
            }
        }
        .padding(.vertical, fixed ? 8 : 12)
        .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
    }
}

struct AddTodoField: View {
    @EnvironmentObject var ritual: Ritual
    @Environment(\.theme) var th
    @State private var text = ""

    var body: some View {
        HStack(spacing: 14) {
            Text("+").font(Theme.mono(18)).foregroundStyle(th.muted).frame(width: 20)
            TextField("Add a to-do", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(th.fg)
                .onSubmit {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty { ritual.primary(); return }
                    ritual.addTodo(text)
                    text = ""
                }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(th.hair).frame(height: 1) }
    }
}
