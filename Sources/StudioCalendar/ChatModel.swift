import AppKit
import Foundation

/// The "›" shell: Claude Code running headless on this Mac (your own login, no API key),
/// set up only as your planner. Its only tools are web search and web fetch (agendas, deadlines,
/// opening hours). It answers from the calendar context we pass in plus what it finds online and
/// proposes changes in a ```calendar block; nothing changes until you click Apply.
@MainActor
final class ChatModel: ObservableObject {
    enum Op: Equatable {
        case add(title: String, start: Date, end: Date, kind: Category?, location: String?)
        case move(CalEvent, start: Date, end: Date)
        case rename(CalEvent, title: String)
        case delete(CalEvent)
        /// Real invite with guests (and a Meet link), sent through Google. `existing` = add guests to that event.
        case invite(existing: CalEvent?, title: String, start: Date, end: Date, guests: [String], meet: Bool)
        /// A person to keep, saved to Contacts.
        case contact(name: String, phone: String?, email: String?, note: String?)

        var isInvite: Bool { if case .invite = self { return true } else { return false } }
        var isContact: Bool { if case .contact = self { return true } else { return false } }
    }

    struct Proposal: Identifiable, Equatable {
        let id = UUID()
        let op: Op
    }

    enum Kind: Equatable {
        case user, assistant, status, error
        case proposals([Proposal], resolved: Bool)
        /// A message for someone else (e.g. free times for WhatsApp), already on the clipboard.
        case outgoing(String)
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        var text: String
        var image: NSImage? = nil
        var pasted: String? = nil
    }

    @Published var isOpen = false
    @Published var messages: [Message] = []
    @Published var busy = false
    /// Screenshot or long text waiting in the prompt until you send.
    @Published var image: NSImage?
    @Published var pastedText: String?
    var hasAttachment: Bool { image != nil || pastedText != nil }

    weak var store: CalendarStore?
    weak var ui: UIState?
    private var sessionID: String?
    private var process: Process?
    private var buffer = Data()
    private var replyIndex: Int?
    private var lastFullText = ""
    private var idMap: [String: CalEvent] = [:]
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var closeTask: Task<Void, Never>?

    static let planTomorrow = "Plan tomorrow: put my most important to-dos and deadlines into the free time as focus sessions."

    /// After this long without activity the chat clears itself.
    private let idleReset: TimeInterval = 10 * 60

    init() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, !self.messages.isEmpty else { return }
                if Date().timeIntervalSince(self.lastActivity) > self.idleReset { self.reset() }
            }
        }
    }

    func attach(image img: NSImage) {
        image = img
        lastActivity = Date()
    }

    func attach(text: String) {
        pastedText = text
        lastActivity = Date()
    }

    func clearAttachments() {
        image = nil
        pastedText = nil
    }

    func send(_ raw: String) {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let img = image, pasted = pastedText
        let text: String
        if !typed.isEmpty { text = typed } else if img != nil || pasted != nil {
            text = "Put what is agreed here into my calendar."
        } else { text = "Plan my day" }
        clearAttachments()
        closeTask?.cancel()
        if Date().timeIntervalSince(lastActivity) > idleReset { reset() }
        lastActivity = Date()
        isOpen = true
        messages.append(Message(kind: .user, text: text, image: img, pasted: pasted))
        messages.append(Message(kind: .status, text: img != nil ? "reading the screenshot …" : "thinking …"))
        replyIndex = messages.count - 1
        busy = true
        var prompt = text
        if let pasted { prompt = "Pasted text:\n<<<\n" + pasted + "\n>>>\n\n" + text }
        run(prompt, image: img.flatMap(Self.encode))
    }

    /// Screenshot as PNG (or JPEG if big), long side at most 1568 px, ready for Claude.
    private static func encode(_ img: NSImage) -> (data: Data, type: String)? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, 1568 / max(w, h))
        let tw = Int(w * scale), th = Int(h * scale)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let small = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: small)
        if let png = rep.representation(using: .png, properties: [:]), png.count < 3_500_000 { return (png, "image/png") }
        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) { return (jpg, "image/jpeg") }
        return nil
    }

    func close() { isOpen = false }

    /// The latest proposal still waiting for Apply/Skip (Enter in an empty prompt applies it).
    var pendingProposalID: UUID? {
        messages.last { if case .proposals(_, false) = $0.kind { return true } else { return false } }?.id
    }

    /// Fresh start: empty chat, new Claude session.
    func reset() {
        closeTask?.cancel()
        clearAttachments()
        process?.terminate()
        process = nil
        messages = []
        sessionID = nil
        busy = false
        replyIndex = nil
        isOpen = false
    }

    func resolve(_ id: UUID, apply: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == id }), case .proposals(let items, false) = messages[i].kind else { return }
        messages[i].kind = .proposals(items, resolved: true)
        lastActivity = Date()
        guard apply, let store else {
            messages.append(Message(kind: .status, text: "Skipped."))
            return
        }
        let local = items.filter { !$0.op.isInvite && !$0.op.isContact }
        let invites = items.filter { $0.op.isInvite }
        let contacts = items.filter { $0.op.isContact }
        var ok = 0
        for p in local {
            switch p.op {
            case .add(let t, let s, let e, let k, let l): if store.add(title: t, start: s, end: e, kind: k, location: l) { ok += 1 }
            case .move(let ev, let s, let e): if store.move(ev, start: s, end: e) { ok += 1 }
            case .rename(let ev, let t): if store.rename(ev, to: t) { ok += 1 }
            case .delete(let ev): if store.delete(ev) { ok += 1 }
            case .invite, .contact: break
            }
        }
        if !local.isEmpty {
            let word = ok == 1 ? "change" : "changes"
            messages.append(Message(kind: .status, text: ok == local.count ? "Done. \(ok) \(word) in \(store.calendarName)." : "Done \(ok) of \(local.count). Some events could not be changed."))
            if ok > 0 { ui?.celebrate() }
        }
        if !contacts.isEmpty { saveContacts(contacts.map(\.op), keepOpen: !invites.isEmpty) }
        if invites.isEmpty { if contacts.isEmpty { cleanDeskSoon() }; return }
        sendInvites(invites.map(\.op), store: store)
    }

    /// Back to a clean desk a moment later.
    private func cleanDeskSoon(after seconds: Double = 2.8) {
        closeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled && !self.busy { self.reset() }
        }
    }

    private func saveContacts(_ ops: [Op], keepOpen: Bool) {
        Task { @MainActor in
            for op in ops {
                guard case .contact(let name, let phone, let email, let note) = op else { continue }
                let line: String
                switch await ContactBook.save(name: name, phone: phone, email: email, note: note) {
                case .saved: line = "Saved \(name) to Contacts."
                case .exists: line = "\(name) is already in Contacts."
                case .denied: line = "No access to Contacts. Allow it in System Settings > Privacy & Security > Contacts."
                case .failed: line = "Could not save \(name)."
                }
                messages.append(Message(kind: .status, text: line))
            }
            lastActivity = Date()
            if !keepOpen && !busy { cleanDeskSoon(after: 4) }
        }
    }

    private func sendInvites(_ ops: [Op], store: CalendarStore) {
        busy = true
        let status = Message(kind: .status, text: "Sending the invite through Google …")
        messages.append(status)
        let fallback = store.calendarName.contains("@") ? store.calendarName : "primary"
        Task { @MainActor in
            var lines: [String] = []
            var meetLink: String?
            for op in ops {
                guard case .invite(let existing, let title, let start, let end, let guests, let meet) = op else { continue }
                let calendar = existing.map { $0.calendarTitle.contains("@") ? $0.calendarTitle : fallback } ?? fallback
                let claude = meet && ClaudeMeetings.enabled
                var result = await GoogleInvite.send(title: title, start: start, end: end, guests: guests, meet: meet,
                                                     claude: claude, existing: existing, calendar: calendar)
                if result.notFound, let old = existing {
                    // Not a Google event: make a proper one with the guests, then drop the old copy.
                    result = await GoogleInvite.send(title: title, start: start, end: end, guests: guests, meet: meet,
                                                     claude: claude, existing: nil, calendar: fallback)
                    if result.ok { store.delete(old) }
                }
                let who = guests.joined(separator: ", ")
                if result.ok {
                    lines.append(guests.isEmpty ? "Claude joins “\(title)”." : "Invite sent to \(who)." + (claude ? " Claude joins." : ""))
                    if let m = result.meet { meetLink = m }
                } else {
                    lines.append("Could not send the invite to \(who). Check the Google Calendar connector in Claude.")
                }
            }
            if let meetLink {
                Self.copy(meetLink)
                lines.append("Meet link copied: " + meetLink.replacingOccurrences(of: "https://", with: ""))
            }
            if let i = self.messages.firstIndex(where: { $0.id == status.id }) {
                self.messages[i].text = lines.joined(separator: "\n")
            } else {
                self.ui?.flash(lines.first ?? "")
            }
            self.busy = false
            self.lastActivity = Date()
            store.ek.refreshSourcesIfNecessary()
            store.reload()
            if lines.contains(where: { $0.hasPrefix("Invite sent") || $0.hasPrefix("Claude joins") }) { self.ui?.celebrate() }
            self.cleanDeskSoon(after: 8)
        }
    }

    // MARK: process

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [UserDefaults.standard.string(forKey: "claudePath") ?? "",
                          "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func workDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StudioCalendar/planner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func systemPrompt() -> String {
        let now = Date()
        let tz = TimeZone.current.identifier
        let ctx: (text: String, ids: [String: CalEvent]) = store?.context() ?? (text: "(calendar not loaded)", ids: [:])
        idMap = ctx.ids
        let day = Fmt.f("EEEE d MMMM yyyy, HH:mm").string(from: now)
        let target = store?.calendarName ?? "the default calendar"
        let hours = "\(String(format: "%02d", store?.dayStartHour ?? 8)):00–\(String(format: "%02d", store?.dayEndHour ?? 20)):00"
        let me = Profile.name
        return """
        You are \(me)'s personal planner inside Studio Calendar, a calendar that lives on their Mac desktop.
        Now: \(day) (\(tz)). Working hours: \(hours). New events go to: \(target).

        Calendar for the next 14 days. Each event has an id (#n), time, title and kind. "free" lists open time inside working hours.
        \(ctx.text)

        People \(me) met before (attendees of past meetings), for invites:
        \(store.map { $0.people().map { "  " + $0 }.joined(separator: "\n") } ?? "")

        \(me)'s open to-dos and project next steps from Measure (their to-do app), deadlines first:
        \(Measure.context() ?? "  (none)")

        How to answer:
        - Reply in the language \(me) writes in. At most 3 short lines. Plain text, no headings, no tables.
        - "When am I free?" questions: answer from the free times above, name concrete slots.
        - To change the calendar, end your reply with exactly one block like this:
        ```calendar
        [{"op":"add","title":"Focus: Pitch deck","start":"YYYY-MM-DDTHH:MM","end":"YYYY-MM-DDTHH:MM","kind":"focus","location":"optional place"},
         {"op":"move","id":"#3","start":"YYYY-MM-DDTHH:MM","end":"YYYY-MM-DDTHH:MM"},
         {"op":"rename","id":"#5","title":"New title"},
         {"op":"delete","id":"#7"}]
        ```
        - kind is one of: meeting, focus, uni (\(Profile.studyLabel)), work (\(Profile.workLabel)).
        - Meeting with someone: title "Meeting · Name", 30 min unless \(me) says otherwise.
        - Work sessions: title "Focus: topic", 60–120 min, leave 15 min between sessions, keep a lunch break.
        - Do not overlap existing events unless \(me) asks. Times are local (\(tz)).
        - \(me) confirms changes with a button. Never say they are already done.
        - "Plan my day" / "plan tomorrow": put the most urgent Measure items into free time as "Focus: short task"
          blocks, deadlines first, at most 4 a day. Name which to-do each block is for.
        - \(me) wants a message to send someone (e.g. "write Alex when I am free", "schreib Alex wann ich Zeit habe"):
          write the exact text in their voice (\(Profile.messageStyle)) in a block:
        ```message
        text here
        ```
          The app copies it to the clipboard. Offer real free slots from the calendar above.
        - Invites: when \(me) wants to meet someone with a call, or says "lade X ein" / "mit Meet", propose a real invite:
          {"op":"invite","title":"Meeting · Name","start":"…","end":"…","guests":["email"],"meet":true}
          or, for an event already in the calendar, {"op":"invite","id":"#5","guests":["email"],"meet":true}.
          Take the email from the people list above. If it is not there or unclear, ask for it. Never guess an address.
          "meet": false only if they meet in person. The app sends the invite through Google after \(me) clicks.
        - Claude Meetings: Claude joins every Google Meet call by default. The app puts its account on each Meet invite
          by itself, so never list it in "guests". After the call the app files the notes and \(me) gets a recap mail.
          To bring Claude into an event that is already in the calendar ("lade Claude ein"):
          {"op":"invite","id":"#5","guests":[],"meet":true}. Claude can only join Google Meet, not Zoom or Teams.
          Never use "add" for a meeting that should get an invite.
        - Screenshots (WhatsApp, iMessage, mail, invites) and pasted text: find the appointment that was agreed or
          proposed. Who, day, time, place. Read relative days ("morgen", "Freitag", "next week") from the message
          dates in the screenshot if visible, otherwise from now. Title "Meeting · Name" (or what it is, e.g.
          "Dinner · Anna"), put the place in "location". If the time is missing or unclear, ask one short question
          instead of guessing. If it clashes with an event, say so in one line and still propose it.
        - Contacts: when \(me) says "speicher den Kontakt" or sends a profile, card or chat with someone's number, propose
          {"op":"contact","name":"Full Name","phone":"+44 …","email":"…","note":"where you met, e.g. LinkedIn, Milan"}
          Only what is visible or said. Leave email out unless it is shown. The app saves it to Contacts after \(me) clicks.
        - You can look things up online (WebSearch, WebFetch): event agendas and schedules, deadlines, opening hours,
          travel times, the date of something. When the answer is on the web, look it up yourself instead of asking \(me),
          then propose the exact times. Name the source in one short line. If you cannot find it, say so in one line.
        - You have no files and no memory. Never write tool calls or XML as text. Everything \(me) wants kept goes into
          a calendar event (notes in the title or location) or a contact, as a proposal.
        """
    }

    /// The only tools the planner gets: read the web, nothing on this Mac.
    static let webTools = "WebSearch,WebFetch"

    private func run(_ text: String, image: (data: Data, type: String)? = nil) {
        guard let claude = Self.claudePath() else {
            finish(error: "Claude Code not found. Install it, then try again.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--tools", Self.webTools, "--allowedTools", Self.webTools, "--strict-mcp-config", "--settings", #"{"autoMemoryEnabled":false}"#,
                    "--model", UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet",
                    "--append-system-prompt", systemPrompt()]
        if let sessionID { args += ["--resume", sessionID] }
        p.arguments = args
        p.currentDirectoryURL = Self.workDir()
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let input = Pipe()
        p.standardInput = input
        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                if self.busy, self.process === proc {
                    self.finish(error: code == 0 ? nil : "Claude stopped (code \(code)).")
                }
            }
        }
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": image.type, "data": image.data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        do {
            try p.run()
            process = p
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0A)
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: line)
                try? writer.close()
            }
        } catch {
            finish(error: "Could not start Claude: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let sid = obj["session_id"] as? String { sessionID = sid }
        case "assistant":
            if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                if !text.isEmpty { setReply(text) }
                else if content.contains(where: { $0["type"] as? String == "tool_use" }) { setReply("Looking it up online …") }
            }
        case "result":
            if let sid = obj["session_id"] as? String { sessionID = sid }
            let isError = obj["is_error"] as? Bool ?? false
            let result = obj["result"] as? String ?? ""
            if isError { finish(error: result.isEmpty ? "Claude returned an error." : result) } else {
                if !result.isEmpty { setReply(result) }
                finish(error: nil)
            }
        default:
            break
        }
    }

    private func setReply(_ text: String) {
        guard let i = replyIndex, i < messages.count else { return }
        messages[i] = Message(kind: .assistant, text: Self.stripBlock(text))
        lastFullText = text
    }

    private func finish(error: String?) {
        guard busy else { return }
        busy = false
        lastActivity = Date()
        if let error {
            if let i = replyIndex, i < messages.count, messages[i].kind == .status { messages.remove(at: i) }
            messages.append(Message(kind: .error, text: error))
        } else {
            let items = parseProposals(lastFullText)
            if let i = replyIndex, i < messages.count, messages[i].kind == .assistant, messages[i].text.isEmpty {
                messages.remove(at: i)
            }
            if let outgoing = Self.block("message", in: lastFullText) {
                messages.append(Message(kind: .outgoing(outgoing), text: outgoing))
                Self.copy(outgoing)
                ui?.flash("Copied. Paste it into the chat.")
            }
            if !items.isEmpty { messages.append(Message(kind: .proposals(items, resolved: false), text: "")) }
        }
        replyIndex = nil
        lastFullText = ""
        process = nil
    }

    // MARK: parsing

    static func stripBlock(_ text: String) -> String {
        // If the planner writes a tool call as text, never show the raw markup.
        var out = text.replacingOccurrences(of: #"<invoke[\s\S]*?</invoke>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"</?(function_calls|antml:[a-z_]+)[^>]*>"#, with: "", options: .regularExpression)
        for name in ["calendar", "message"] {
            guard let r = out.range(of: "```" + name) else { continue }
            var head = String(out[..<r.lowerBound])
            let rest = out[r.upperBound...]
            if let close = rest.range(of: "```") { head += rest[close.upperBound...] }
            out = head
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func block(_ name: String, in text: String) -> String? {
        guard let r = text.range(of: "```" + name) else { return nil }
        let rest = text[r.upperBound...]
        guard let close = rest.range(of: "```") else { return nil }
        let body = rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func parseProposals(_ text: String) -> [Proposal] {
        guard let r = text.range(of: "```calendar") else { return [] }
        let rest = text[r.upperBound...]
        guard let close = rest.range(of: "```") else { return [] }
        guard let data = String(rest[..<close.lowerBound]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { Fmt.iso.date(from: String($0.prefix(16))) } }
        func event(_ v: Any?) -> CalEvent? {
            guard let raw = v as? String else { return nil }
            let key = raw.hasPrefix("#") ? raw : "#" + raw
            return idMap[key]
        }
        return arr.compactMap { o -> Proposal? in
            let op = (o["op"] as? String ?? "add").lowercased()
            switch op {
            case "add":
                guard let t = o["title"] as? String, let s = date(o["start"]), let e = date(o["end"]), e > s else { return nil }
                let place = (o["location"] as? String)?.trimmingCharacters(in: .whitespaces)
                return Proposal(op: .add(title: t, start: s, end: e, kind: Category(kind: o["kind"] as? String),
                                         location: place?.isEmpty == false && place != "optional place" ? place : nil))
            case "move":
                guard let ev = event(o["id"]), let s = date(o["start"]), let e = date(o["end"]), e > s else { return nil }
                return Proposal(op: .move(ev, start: s, end: e))
            case "rename":
                guard let ev = event(o["id"]), let t = o["title"] as? String else { return nil }
                return Proposal(op: .rename(ev, title: t))
            case "delete":
                guard let ev = event(o["id"]) else { return nil }
                return Proposal(op: .delete(ev))
            case "contact":
                guard let n = (o["name"] as? String)?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
                func val(_ k: String) -> String? {
                    guard let v = (o[k] as? String)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
                    return v
                }
                guard val("phone") != nil || val("email") != nil else { return nil }
                return Proposal(op: .contact(name: n, phone: val("phone"), email: val("email"), note: val("note")))
            case "invite":
                let guests = (o["guests"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { $0.contains("@") && $0.contains(".") && $0 != ClaudeMeetings.account }
                let meet = o["meet"] as? Bool ?? true
                if let ev = event(o["id"]) {
                    guard !guests.isEmpty || (meet && ClaudeMeetings.enabled) else { return nil }
                    return Proposal(op: .invite(existing: ev, title: ev.title, start: ev.start, end: ev.end, guests: guests, meet: meet))
                }
                guard !guests.isEmpty, let t = o["title"] as? String, let s = date(o["start"]), let e = date(o["end"]), e > s else { return nil }
                return Proposal(op: .invite(existing: nil, title: t, start: s, end: e, guests: guests, meet: meet))
            default:
                return nil
            }
        }
    }
}
