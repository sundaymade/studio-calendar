import AppKit
import SwiftUI

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var chat: ChatModel
    @EnvironmentObject var ritual: Ritual
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let th = Theme(dark: scheme == .dark)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                th.bg
                HStack(spacing: 0) {
                    LeftPanel().frame(width: 430)
                    Rectangle().fill(th.hair).frame(width: 1)
                    RightPanel()
                }
                .padding(ui.insets)

                if ui.popover != nil || ui.showQuickAdd {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { ui.popover = nil; ui.showQuickAdd = false }
                }
                if let info = ui.popover {
                    let x = info.point.x + 16 + 300 > geo.size.width - 20 ? info.point.x - 16 - 150 : info.point.x + 16 + 150
                    let y = min(max(info.point.y, ui.insets.top + 120), geo.size.height - 130)
                    EventCard(info: info).position(x: x, y: y)
                }
                if ui.showQuickAdd {
                    QuickAddCard()
                        .frame(maxWidth: .infinity)
                        .padding(.top, ui.insets.top + 150)
                }
                if ui.showHelp {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { ui.showHelp = false }
                    ShortcutsCard()
                        .frame(maxWidth: .infinity)
                        .padding(.top, ui.insets.top + 120)
                }
                if ritual.isOpen {
                    RitualView().transition(.opacity)
                }
                if let t = ui.toast {
                    Text(t)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(th.bg)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(th.fg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.leading, ui.insets.leading + 430)
                        .padding(.bottom, ui.insets.bottom + 28)
                        .allowsHitTesting(false)
                }
                if ui.dropTargeted {
                    ZStack {
                        th.bg.opacity(0.85)
                        Text("Drop it. Claude puts it in your calendar.")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(th.fg)
                            .padding(.horizontal, 22).padding(.vertical, 14)
                            .overlay(Rectangle().stroke(th.fg, lineWidth: 2))
                    }
                    .allowsHitTesting(false)
                }
                if let problem = store.problem {
                    ProblemBanner(text: problem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.bottom, ui.insets.bottom + 24).padding(.trailing, ui.insets.trailing + 40)
                }
            }
            .coordinateSpace(name: "root")
            .onDrop(of: [.fileURL, .image], isTargeted: $ui.dropTargeted) { providers in
                Drop.load(providers) { img in
                    chat.attach(image: img)
                    ui.focusPromptTick += 1
                }
                return true
            }
        }
        .environment(\.theme, th)
        .tint(th.fg)
    }
}

struct ProblemBanner: View {
    @Environment(\.theme) var th
    @EnvironmentObject var store: CalendarStore
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Text(text).font(Theme.mono(12)).foregroundStyle(th.fg).frame(maxWidth: 420, alignment: .leading)
            StudioButton(title: "Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
            }
            StudioButton(title: "Retry") { store.problem = nil; Task { await store.requestAccess() } }
        }
        .padding(14)
        .background(th.card)
        .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
    }
}

// MARK: - Left: today

struct LeftPanel: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var chat: ChatModel
    @Environment(\.theme) var th

    var body: some View {
        let cal = Calendar.current
        let now = store.now
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        VStack(alignment: .leading, spacing: 0) {
            BigDay(text: Fmt.dayNum.string(from: now))
                .foregroundStyle(th.fg)
                .padding(.leading, -12)
                .frame(height: 176)
            Rectangle().fill(th.fg).frame(height: 2).padding(.top, 22)
            HStack {
                Label11(text: Fmt.weekday.string(from: now), color: th.fg)
                Spacer()
                Label11(text: Fmt.monthYear.string(from: now), color: th.fg)
            }
            .padding(.top, 10)

            if !chat.isOpen, let ev = store.current ?? store.nextEvent {
                UpNext(ev: ev).padding(.top, 30)
            }
            if chat.isOpen {
                ChatPanel().padding(.top, 24)
            } else {
                EventList(title: "Today", events: store.timed(on: today)).padding(.top, 26)
                EventList(title: "Tomorrow · " + Fmt.weekday.string(from: tomorrow), events: store.timed(on: tomorrow)).padding(.top, 22)
                Spacer(minLength: 12)
            }
            PromptField().padding(.top, 12)
        }
        .padding(EdgeInsets(top: 38, leading: 48, bottom: 30, trailing: 40))
    }
}

/// The big day number. Tight spacing between the digits only, so the last one keeps its full shape.
struct BigDay: View {
    let text: String
    var body: some View {
        let font = Font.system(size: 220, weight: .ultraLight)
        let head = String(text.dropLast()), tail = String(text.suffix(1))
        (Text(head).kerning(-14) + Text(tail))
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .padding(.trailing, 8)
    }
}

struct UpNext: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let ev: CalEvent
    var body: some View {
        let running = ev.start <= store.now && ev.end > store.now
        let total = max(ev.end.timeIntervalSince(ev.start), 1)
        let progress = min(max(store.now.timeIntervalSince(ev.start) / total, 0), 1)
        VStack(alignment: .leading, spacing: 6) {
            Label11(text: running ? "Now · " + Fmt.duration(ev.end.timeIntervalSince(store.now)) + " left" : "Up next · " + Fmt.until(ev.start, now: store.now),
                    color: running ? th.fg : nil)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Rectangle().fill(th.fill(ev.category)).frame(width: 14, height: 14)
                Text(ev.title)
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.7)
                    .foregroundStyle(th.fg)
                    .lineLimit(2)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end))
                    .font(Theme.mono(13, .regular))
                    .foregroundStyle(th.fg)
                if let place = ev.location {
                    Text(place).font(Theme.mono(12, .regular)).foregroundStyle(th.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                ClaudeChip(ev: ev)
                if ev.meetingURL != nil {
                    let soon = ev.start.timeIntervalSince(store.now) < 15 * 60
                    StudioButton(title: "Join", hint: "J", filled: soon) {
                        if store.join(ev) { ui.flash("Joining “\(ev.title)”") }
                    }
                    .accessibilityLabel("Join call")
                }
            }
            if running && ev.category == .focus {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    let left = max(0, Int(ev.end.timeIntervalSince(tl.date)))
                    Text(left >= 3600 ? String(format: "%d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
                                      : String(format: "%02d:%02d", left / 60, left % 60))
                        .font(.system(size: 64, weight: .light, design: .monospaced))
                        .kerning(-2)
                        .foregroundStyle(th.fg)
                        .padding(.top, 6)
                }
            }
            if running {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(th.hair)
                        Rectangle().fill(th.fill(ev.category)).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.top, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named("root")) { p in ui.popover = PopoverInfo(event: ev, point: p) }
    }
}

struct EventList: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let title: String
    let events: [CalEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label11(text: title).padding(.bottom, 6)
            if events.isEmpty {
                Text("Nothing planned")
                    .font(.system(size: 14))
                    .foregroundStyle(th.muted)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
            }
            ForEach(events.prefix(6)) { ev in
                HStack(spacing: 10) {
                    Rectangle().fill(th.fill(ev.category)).frame(width: 10, height: 10)
                    Text(Fmt.time.string(from: ev.start))
                        .font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
                        .frame(width: 46, alignment: .leading)
                    Text(ev.title)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(th.fg)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(Fmt.duration(ev.end.timeIntervalSince(ev.start)))
                        .font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
                .opacity(ev.end <= store.now ? 0.4 : 1)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("root")) { p in ui.popover = PopoverInfo(event: ev, point: p) }
            }
            if events.count > 6 {
                Text("+\(events.count - 6) more").font(Theme.mono(12, .regular)).foregroundStyle(th.muted).padding(.top, 6)
            }
        }
    }
}

struct PromptField: View {
    @EnvironmentObject var chat: ChatModel
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chat.hasAttachment {
                HStack(spacing: 8) {
                    if let img = chat.image {
                        AttachmentChip(label: "Screenshot", image: img) { chat.image = nil }
                    }
                    if let t = chat.pastedText {
                        let lines = t.split(whereSeparator: \.isNewline).count
                        AttachmentChip(label: "Text · \(lines) lines", image: nil) { chat.pastedText = nil }
                    }
                    Text("↩ to send").font(Theme.mono(11, .regular)).foregroundStyle(th.muted)
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 12) {
                Text("›").font(Theme.mono(22)).foregroundStyle(focused ? th.fg : th.muted)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(th.fg)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Text("→").font(.system(size: 24)).foregroundStyle(chat.busy ? th.muted : th.fg)
                }
                .buttonStyle(.plain)
                .disabled(chat.busy)
                .accessibilityLabel("Send to Claude")
            }
            .padding(.vertical, 10)
            Rectangle().fill(th.fg).frame(height: 2)
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { g in
                Critter(width: g.size.width, typing: focused || !text.isEmpty)
                    .offset(y: -20)
            }
            .frame(height: 0)
            .allowsHitTesting(false)
        }
        .onChange(of: ui.focusPromptTick) { _, _ in focused = true }
        .onChange(of: focused) { _, f in ui.promptFocused = f }
    }

    private func send() {
        guard !chat.busy else { return }
        if text.trimmingCharacters(in: .whitespaces).isEmpty, !chat.hasAttachment, let pending = chat.pendingProposalID {
            chat.resolve(pending, apply: true)
            return
        }
        chat.send(text)
        text = ""
        focused = true
    }
}

struct AttachmentChip: View {
    @Environment(\.theme) var th
    let label: String
    let image: NSImage?
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 26).clipped()
                    .overlay(Rectangle().stroke(th.hair, lineWidth: 1))
            }
            Text(label.uppercased()).font(Theme.mono(11)).tracking(0.5).foregroundStyle(th.fg)
            Button(action: remove) { Text("✕").font(Theme.mono(11)).foregroundStyle(th.muted) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove " + label)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
    }
}

struct ChatPanel: View {
    @EnvironmentObject var chat: ChatModel
    @EnvironmentObject var store: CalendarStore
    @Environment(\.theme) var th

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(th.fg).frame(height: 2)
            HStack(spacing: 10) {
                Label11(text: "Claude · planner")
                Label11(text: "→ " + store.calendarName).lineLimit(1)
                Spacer()
                if chat.busy { ProgressView().controlSize(.small) }
                Button("New ⌘⇧K") { chat.reset() }
                    .buttonStyle(.plain).font(Theme.mono(11)).foregroundStyle(th.muted)
                Button { chat.close() } label: {
                    Text("✕").font(Theme.mono(12)).foregroundStyle(th.muted)
                        .frame(width: 24, height: 24)
                        .overlay(Rectangle().stroke(th.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close chat")
            }
            .padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { m in
                            MessageView(message: m).id(m.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
                .onChange(of: chat.messages) { _, msgs in
                    if let last = msgs.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct MessageView: View {
    @EnvironmentObject var chat: ChatModel
    @Environment(\.theme) var th
    let message: ChatModel.Message

    var body: some View {
        switch message.kind {
        case .user:
            VStack(alignment: .leading, spacing: 6) {
                if let img = message.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 160, alignment: .leading)
                        .overlay(Rectangle().stroke(th.hair, lineWidth: 1))
                }
                if let pasted = message.pasted {
                    Text(pasted).font(Theme.mono(11, .regular)).foregroundStyle(th.muted).lineLimit(4)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(th.hair).frame(width: 2) }
                }
                (Text("› ").foregroundColor(th.muted) + Text(message.text).foregroundColor(th.fg))
                    .font(Theme.mono(13, .regular))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(message.text)
                .font(.system(size: 14))
                .foregroundStyle(th.fg)
                .lineSpacing(3)
                .textSelection(.enabled)
        case .status:
            Text(message.text).font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
        case .error:
            Text(message.text).font(Theme.mono(12, .regular)).foregroundStyle(Color(hex: 0xE5484D))
        case .outgoing(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(th.fg)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
                HStack(spacing: 8) {
                    StudioButton(title: "Copy again") { ChatModel.copy(text); chat.ui?.flash("Copied") }
                    Text("on your clipboard").font(Theme.mono(11, .regular)).foregroundStyle(th.muted)
                }
            }
        case .proposals(let items, let resolved):
            let onlyAdds = items.allSatisfy { if case .add = $0.op { return true } else { return false } }
            let hasInvite = items.contains { $0.op.isInvite }
            let onlyContacts = items.allSatisfy { $0.op.isContact }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { p in row(p.op) }
                if !resolved {
                    HStack(spacing: 8) {
                        StudioButton(title: hasInvite ? "Send invite" : onlyContacts ? "Save contact" : onlyAdds ? "Add to calendar" : "Apply", hint: "↩", filled: true) { chat.resolve(message.id, apply: true) }
                        StudioButton(title: "Skip") { chat.resolve(message.id, apply: false) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func when(_ s: Date, _ e: Date) -> String {
        Fmt.weekdayShort.string(from: s) + " " + Fmt.time.string(from: s) + "–" + Fmt.time.string(from: e)
    }

    @ViewBuilder
    private func row(_ op: ChatModel.Op) -> some View {
        let (sign, color, time, title): (String, Color, String, String) = {
            switch op {
            case .add(let t, let s, let e, let k, let l): return ("+", th.fill(k ?? .focus), when(s, e), l.map { t + " · " + $0 } ?? t)
            case .move(let ev, let s, let e): return ("→", th.fill(ev.category), when(s, e), ev.title)
            case .rename(let ev, let t): return ("✎", th.fill(ev.category), when(ev.start, ev.end), ev.title + " → " + t)
            case .delete(let ev): return ("−", th.fill(ev.category), when(ev.start, ev.end), ev.title)
            case .contact(let n, let ph, let em, let note):
                return ("@", th.muted, ph ?? em ?? "", n + (note.map { " · " + $0 } ?? ""))
            case .invite(_, let t, let s, let e, let g, let m):
                let extra = (m ? " · Meet" : "") + (m && ClaudeMeetings.enabled ? " · Claude" : "")
                return ("✉", th.fill(.meeting), when(s, e), g.isEmpty ? t + " → Claude" + (m ? " · Meet" : "") : t + " → " + g.joined(separator: ", ") + extra)
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(sign).font(Theme.mono(13)).foregroundStyle(th.fg).frame(width: 12)
            Rectangle().fill(color).frame(width: 10, height: 10)
            Text(time).font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(th.fg)
                .strikethrough({ if case .delete = op { return true } else { return false } }())
        }
    }
}

// MARK: - Right: grid

struct RightPanel: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th

    var body: some View {
        let days = ui.visibleDays(now: store.now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(rangeTitle(days))
                        .font(.system(size: 32, weight: .semibold))
                        .kerning(-1.1)
                        .foregroundStyle(th.fg)
                    Label11(text: "Week \(weekNumber(days.first ?? store.now))")
                }
                Spacer()
                StudioButton(title: "?") { ui.showHelp.toggle() }
                StudioButton(title: "New", hint: "⌘N") { ui.popover = nil; ui.showQuickAdd = true }
                HStack(spacing: 0) {
                    StudioButton(title: "‹") { ui.offset -= 1 }
                    StudioButton(title: "Today") { ui.offset = 0 }
                    StudioButton(title: "›") { ui.offset += 1 }
                }
                SpanSwitch()
            }
            .padding(.leading, 60)
            .padding(.bottom, 18)
            TimeGrid(days: days)
        }
        .padding(EdgeInsets(top: 38, leading: 0, bottom: 0, trailing: 40))
    }

    private func rangeTitle(_ days: [Date]) -> String {
        guard let a = days.first, let b = days.last else { return "" }
        if days.count == 1 { return Fmt.dayMonth.string(from: a) }
        let cal = Calendar.current
        if cal.component(.month, from: a) == cal.component(.month, from: b) {
            return Fmt.dayNum.string(from: a) + "–" + Fmt.dayMonth.string(from: b)
        }
        return Fmt.dayMonth.string(from: a) + " – " + Fmt.dayMonth.string(from: b)
    }

    private func weekNumber(_ d: Date) -> Int {
        Calendar(identifier: .iso8601).component(.weekOfYear, from: d)
    }
}

struct SpanSwitch: View {
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    var body: some View {
        HStack(spacing: 18) {
            ForEach(Span.allCases, id: \.self) { s in
                Button { ui.span = s; ui.offset = 0 } label: {
                    VStack(spacing: 3) {
                        Text(s.label.uppercased())
                            .font(Theme.mono(12)).tracking(0.7)
                            .foregroundStyle(ui.span == s ? th.fg : th.muted)
                        Rectangle().fill(ui.span == s ? th.fg : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Claude" when Claude Meetings will join this call, "+ Claude" when it could.
struct ClaudeChip: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let ev: CalEvent

    var body: some View {
        if ev.claudeJoins {
            Text("CLAUDE")
                .font(Theme.mono(11)).tracking(0.6)
                .foregroundStyle(th.muted)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .overlay(Rectangle().stroke(th.hair, lineWidth: 1))
                .help("Claude joins this call, takes notes and mails you a recap")
                .accessibilityLabel("Claude joins this call")
        } else if ClaudeMeetings.canAdd(ev, now: store.now) {
            StudioButton(title: "+ Claude") { ClaudeMeetings.add(to: ev, store: store, ui: ui) }
                .help(ev.meetingURL == nil ? "Adds a Meet link and Claude. Nobody else gets a mail." : "Claude joins and takes notes. Nobody else gets a mail.")
                .accessibilityLabel("Add Claude to this call")
        }
    }
}

struct StudioButton: View {
    @Environment(\.theme) var th
    let title: String
    var hint: String? = nil
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(Theme.mono(12)).tracking(0.6)
                if let hint {
                    Text(hint).font(Theme.mono(11, .regular)).foregroundStyle(filled ? th.bg.opacity(0.7) : th.muted)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(filled ? th.bg : th.fg)
            .background(filled ? th.fg : Color.clear)
            .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension UIState {
    func visibleDays(now: Date) -> [Date] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        let base: Date
        switch span {
        case .day: base = cal.date(byAdding: .day, value: offset, to: today)!
        case .three: base = cal.date(byAdding: .day, value: offset * 3, to: today)!
        case .week:
            let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            base = cal.date(byAdding: .day, value: offset * 7, to: monday)!
        }
        return (0..<span.rawValue).map { cal.date(byAdding: .day, value: $0, to: base)! }
    }
}

struct TimeGrid: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(\.theme) var th
    let days: [Date]

    /// 8–20 by default, stretched to fit early or late events in view.
    private var hours: (Int, Int) {
        let cal = Calendar.current
        var lo = 8, hi = 20
        for d in days {
            for e in store.timed(on: d) {
                lo = min(lo, cal.component(.hour, from: e.start))
                let endsNextDay = !cal.isDate(e.end, inSameDayAs: e.start)
                let eh = endsNextDay ? 24 : cal.component(.hour, from: e.end) + (cal.component(.minute, from: e.end) > 0 ? 1 : 0)
                hi = max(hi, eh)
            }
        }
        return (max(0, lo), min(24, max(hi, lo + 6)))
    }

    var body: some View {
        let cal = Calendar.current
        let (h0, h1) = hours
        let showsToday = days.contains { cal.isDateInToday($0) }
        let nowMin = cal.component(.hour, from: store.now) * 60 + cal.component(.minute, from: store.now)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 60, height: 1)
                ForEach(days, id: \.self) { d in
                    DayHeader(day: d).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 60, height: 1)
                ForEach(days, id: \.self) { d in
                    HStack(spacing: 4) {
                        ForEach(store.allDay(on: d)) { e in AllDayChip(ev: e) }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(th.hair).frame(width: 1) }
                }
            }
            Rectangle().fill(th.hair).frame(height: 1)
            GeometryReader { geo in
                let hh = max(26, geo.size.height / CGFloat(h1 - h0))
                let colW = max(40, (geo.size.width - 60) / CGFloat(max(days.count, 1)))
                ZStack(alignment: .topLeading) {
                    ForEach((h0 + 1)..<h1, id: \.self) { h in
                        if !(showsToday && abs(h * 60 - nowMin) < 20) {
                            Text(String(format: "%02d:00", h))
                                .font(Theme.mono(11, .regular))
                                .foregroundStyle(th.muted)
                                .frame(width: 48, alignment: .trailing)
                                .position(x: 30, y: CGFloat(h - h0) * hh)
                        }
                    }
                    if showsToday && nowMin > h0 * 60 && nowMin < h1 * 60 {
                        Text(Fmt.time.string(from: store.now))
                            .font(Theme.mono(11, .semibold))
                            .foregroundStyle(th.bg)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(th.fg)
                            .position(x: 32, y: CGFloat(nowMin - h0 * 60) / 60 * hh)
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 60)
                        ForEach(days, id: \.self) { d in
                            DayColumn(day: d, hh: hh, width: colW, h0: h0, h1: h1)
                        }
                    }
                }
            }
        }
    }
}

struct DayHeader: View {
    @Environment(\.theme) var th
    let day: Date
    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        HStack(spacing: 8) {
            Text(Fmt.dayNum.string(from: day))
                .font(.system(size: 26, weight: .light))
                .kerning(-0.8)
                .foregroundStyle(today ? th.bg : th.fg)
                .frame(minWidth: 36, minHeight: 36)
                .background(today ? th.fg : Color.clear)
            Label11(text: Fmt.weekdayShort.string(from: day), color: today ? th.fg : th.muted)
        }
        .padding(.leading, 10)
    }
}

struct AllDayChip: View {
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let ev: CalEvent
    var body: some View {
        Text(ev.title)
            .font(Theme.mono(11.5))
            .foregroundStyle(th.fg)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(th.chipBg)
            .onTapGesture(coordinateSpace: .named("root")) { p in ui.popover = PopoverInfo(event: ev, point: p) }
    }
}

struct Placed: Identifiable {
    let ev: CalEvent
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var id: String { ev.id }
}

struct DayColumn: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let day: Date
    let hh: CGFloat
    let width: CGFloat
    let h0: Int
    let h1: Int

    var body: some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let nowMin = cal.component(.hour, from: store.now) * 60 + cal.component(.minute, from: store.now)
        let height = hh * CGFloat(h1 - h0)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                for h in 0..<(h1 - h0) {
                    ctx.fill(Path(CGRect(x: 0, y: CGFloat(h) * hh, width: size.width, height: 1)), with: .color(th.hair))
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(th.hair))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .modifiers(.command)
                    .onChanged { v in
                        let a = minute(v.startLocation.y), b = minute(v.location.y)
                        let lo = min(a, b)
                        let hi = min(max(max(a, b) + 15, lo + 30), h1 * 60)
                        ui.popover = nil
                        ui.draft = Draft(day: day, startMin: lo, endMin: hi, dragging: true)
                    }
                    .onEnded { _ in ui.draft?.dragging = false }
            )

            ForEach(layout(store.timed(on: day))) { item in
                EventBlock(ev: item.ev, short: item.h < 36)
                    .frame(width: item.w, height: item.h)
                    .offset(x: item.x, y: item.y)
            }

            if let d = ui.draft, cal.isDate(d.day, inSameDayAs: day) {
                let y = CGFloat(d.startMin - h0 * 60) / 60 * hh
                let h = max(CGFloat(d.endMin - d.startMin) / 60 * hh, 20) - 2
                DraftBlock(draft: d)
                    .frame(width: width - 8, height: h)
                    .offset(x: 3, y: y)
            }

            if isToday && nowMin > h0 * 60 && nowMin < h1 * 60 {
                let y = CGFloat(nowMin - h0 * 60) / 60 * hh
                Rectangle().fill(th.fg).frame(width: width, height: 2).offset(y: y - 1).allowsHitTesting(false)
                Rectangle().fill(th.fg).frame(width: 10, height: 10).offset(x: -4, y: y - 5).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func minute(_ y: CGFloat) -> Int {
        let m = h0 * 60 + Int((y / hh * 60).rounded(.down))
        return min(max((m / 15) * 15, h0 * 60), h1 * 60 - 15)
    }

    /// Side-by-side lanes for overlapping events.
    private func layout(_ evs: [CalEvent]) -> [Placed] {
        let cal = Calendar.current
        struct Item { let ev: CalEvent; let s: Int; let e: Int; var lane = 0 }
        var items: [Item] = evs.compactMap { ev in
            let s = cal.component(.hour, from: ev.start) * 60 + cal.component(.minute, from: ev.start)
            var e = cal.isDate(ev.end, inSameDayAs: ev.start) ? cal.component(.hour, from: ev.end) * 60 + cal.component(.minute, from: ev.end) : 24 * 60
            e = max(e, s + 15)
            let cs = max(s, h0 * 60), ce = min(e, h1 * 60)
            return ce > cs ? Item(ev: ev, s: cs, e: ce) : nil
        }.sorted { $0.s < $1.s }

        var result: [Placed] = []
        var cluster: [Item] = []
        var laneEnds: [Int] = []
        var clusterEnd = -1
        func flush() {
            let n = max(laneEnds.count, 1)
            let w = (width - 8) / CGFloat(n)
            for it in cluster {
                let y = CGFloat(it.s - h0 * 60) / 60 * hh
                let h = max(CGFloat(it.e - it.s) / 60 * hh, 20) - 2
                result.append(Placed(ev: it.ev, x: 3 + w * CGFloat(it.lane), y: y, w: w - 2, h: h))
            }
            cluster = []
            laneEnds = []
        }
        for i in items.indices {
            if items[i].s >= clusterEnd { flush(); clusterEnd = items[i].e } else { clusterEnd = max(clusterEnd, items[i].e) }
            if let lane = laneEnds.firstIndex(where: { $0 <= items[i].s }) {
                items[i].lane = lane
                laneEnds[lane] = items[i].e
            } else {
                items[i].lane = laneEnds.count
                laneEnds.append(items[i].e)
            }
            cluster.append(items[i])
        }
        flush()
        return result
    }
}

struct EventBlock: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let ev: CalEvent
    let short: Bool

    var body: some View {
        let selected = ui.popover?.event.id == ev.id
        VStack(alignment: .leading, spacing: 2) {
            Text(ev.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(short ? 1 : 3)
            if !short {
                Text(Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end))
                    .font(Theme.mono(11, .regular))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(th.onFill)
        .padding(.horizontal, 8)
        .padding(.vertical, short ? 3 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(th.fill(ev.category))
        .clipped()
        .overlay(Rectangle().stroke(th.fg, lineWidth: selected ? 2 : 0))
        .opacity(ev.end <= store.now ? 0.38 : 1)
        .contentShape(Rectangle())
        .help(ev.title + "  " + Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end))
        .onTapGesture(coordinateSpace: .named("root")) { p in ui.popover = PopoverInfo(event: ev, point: p) }
    }
}

struct DraftBlock: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let draft: Draft
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if draft.dragging {
                Text("New event").font(.system(size: 12.5, weight: .semibold))
            } else {
                TextField("New event", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(th.onFill)
                    .focused($focused)
                    .onSubmit(commit)
            }
            Text(hm(draft.startMin) + "–" + hm(draft.endMin)).font(Theme.mono(11, .regular)).opacity(0.75)
        }
        .foregroundStyle(th.onFill)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(th.fill(.focus))
        .overlay(Rectangle().stroke(th.fg, lineWidth: 2))
        .onAppear { if !draft.dragging { focused = true } }
        .onChange(of: draft.dragging) { _, dragging in if !dragging { focused = true } }
    }

    private func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    private func commit() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            let cal = Calendar.current
            let s = cal.date(byAdding: .minute, value: draft.startMin, to: cal.startOfDay(for: draft.day))!
            let e = cal.date(byAdding: .minute, value: draft.endMin, to: cal.startOfDay(for: draft.day))!
            if store.add(title: t, start: s, end: e) { ui.flash("Added “\(t)” to \(store.calendarName)"); ui.celebrate() }
        }
        ui.draft = nil
    }
}

// MARK: - Overlays

struct EventCard: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    let info: PopoverInfo
    @State private var title = ""

    var body: some View {
        let ev = info.event
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Rectangle().fill(ev.allDay ? th.chipBg : th.fill(ev.category)).frame(width: 14, height: 14)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(th.fg)
                    .disabled(!ev.editable)
                    .onSubmit(done)
            }
            Rectangle().fill(th.hair).frame(height: 1)
            Text(dateLine(ev)).font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
            if let place = ev.location {
                Text(place).font(Theme.mono(12, .regular)).foregroundStyle(th.muted).lineLimit(2)
            }
            Text("Calendar: " + ev.calendarTitle).font(Theme.mono(12, .regular)).foregroundStyle(th.muted)
            if ev.editable {
                Text("⌘⌫ delete · ↩ save · esc close").font(Theme.mono(11, .regular)).foregroundStyle(th.muted.opacity(0.8))
            }
            HStack(spacing: 8) {
                if ev.meetingURL != nil {
                    StudioButton(title: "Join", filled: true) {
                        if store.join(ev) { ui.flash("Joining “\(ev.title)”") }
                        ui.popover = nil
                    }
                }
                ClaudeChip(ev: ev)
                Spacer()
                if ev.editable {
                    StudioButton(title: "Delete") {
                        if store.delete(ev) { ui.flash("Deleted “\(ev.title)”") }
                        ui.popover = nil
                    }
                }
                StudioButton(title: "Done", filled: ev.meetingURL == nil) { done() }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
        .background(th.card)
        .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .onAppear { title = info.event.title }
        .onChange(of: info) { _, new in title = new.event.title }
    }

    private func dateLine(_ ev: CalEvent) -> String {
        let day = Fmt.f("EEEE d MMM").string(from: ev.start)
        if ev.allDay { return day + " · all day" }
        return day + " · " + Fmt.time.string(from: ev.start) + "–" + Fmt.time.string(from: ev.end)
    }

    private func done() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if info.event.editable, !t.isEmpty, t != info.event.title {
            if store.rename(info.event, to: t) { ui.flash("Renamed to “\(t)”") }
        }
        ui.popover = nil
    }
}

struct QuickAddCard: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var ui: UIState
    @Environment(\.theme) var th
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let p = QuickParse.parse(text, now: store.now)
        VStack(alignment: .leading, spacing: 8) {
            Label11(text: "New event")
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium))
                .kerning(-0.6)
                .foregroundStyle(th.fg)
                .focused($focused)
                .onSubmit(add)
            HStack(spacing: 10) {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("e.g. Lunch tomorrow 1pm 45 min").font(Theme.mono(13, .regular)).foregroundStyle(th.muted)
                } else {
                    Rectangle().fill(th.fill(.focus)).frame(width: 10, height: 10)
                    Text(p.title + " · " + Fmt.f("EEE d MMM").string(from: p.start) + " · " + Fmt.time.string(from: p.start) + "–" + Fmt.time.string(from: p.end) + "  → " + store.calendarName)
                        .font(Theme.mono(13, .regular)).foregroundStyle(th.muted)
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
        .frame(width: 660, alignment: .leading)
        .background(th.card)
        .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 40, y: 20)
        .onAppear { focused = true }
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { ui.showQuickAdd = false; return }
        let p = QuickParse.parse(text, now: store.now)
        if store.add(title: p.title, start: p.start, end: p.end) {
            ui.flash("Added “\(p.title)” · " + Fmt.f("EEE HH:mm").string(from: p.start))
            ui.celebrate()
        }
        ui.showQuickAdd = false
    }
}
