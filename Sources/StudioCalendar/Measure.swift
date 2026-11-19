import Foundation

/// Read-only view of Measure: open to-dos and the next step of each active project,
/// so "plan my day" can put real work into the free time.
enum Measure {
    struct Item {
        let title: String
        let project: String
        let due: Date?
    }

    static var folder: URL {
        if let custom = UserDefaults.standard.string(forKey: "measureFolder") { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/worktime-local", isDirectory: true)
    }

    static var available: Bool { !Demo.on && FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.json").path) }

    private static func json(_ name: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Open to-dos plus each active project's next step and next open milestone, deadlines first.
    static func items() -> [Item] {
        if Demo.on { return [] }
        var out: [Item] = []
        for t in openTodos() {
            out.append(Item(title: t.title, project: t.project, due: nil))
        }
        for p in json("initiatives.json") {
            guard let status = p["status"] as? String, status == "active" else { continue }
            let name = [p["company"] as? String, p["title"] as? String].compactMap { $0 }.joined(separator: " · ")
            let open = (p["milestones"] as? [[String: Any]] ?? [])
                .filter { $0["done"] as? Bool != true }
                .compactMap { m -> (String, Date)? in
                    guard let t = m["title"] as? String, let d = (m["due"] as? String).flatMap(day.date(from:)) else { return nil }
                    return (t, d)
                }
                .min { $0.1 < $1.1 }
            if let next = p["next"] as? String, !next.isEmpty {
                out.append(Item(title: next, project: name, due: open?.1))
            } else if let open {
                out.append(Item(title: open.0, project: name, due: open.1))
            }
        }
        return out.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    // MARK: projects

    struct Project { let id: String; let company: String; let title: String }

    /// Projects that are running or waiting.
    static func projects() -> [Project] {
        if Demo.on { return [] }
        return json("initiatives.json").compactMap { p in
            guard let id = p["id"] as? String, p["deleted"] as? Bool != true,
                  let status = p["status"] as? String, status == "active" || status == "waiting" else { return nil }
            return Project(id: id, company: p["company"] as? String ?? "", title: p["title"] as? String ?? "")
        }
    }

    /// "project.gh-ibe" → "gh-ibe", the form projekt.py prints and takes.
    static func shortID(_ id: String) -> String { id.hasPrefix("project.") ? String(id.dropFirst(8)) : id }

    /// Measure's own tool (~/Code/measure/Config/projekt.py), so changes go through its inbox like everywhere else.
    @discardableResult
    static func project(_ args: [String]) -> Bool {
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code/measure/Config/projekt.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: to-dos (read and write notes.json the way Measure does: merge by `updated`)

    struct Todo: Identifiable, Equatable {
        let id: String
        let title: String
        let project: String
    }

    private static func isOpen(_ n: [String: Any]) -> Bool {
        guard (n["kind"] as? String) == "todo" else { return false }
        if let d = n["done"], !(d is NSNull) { return false }   // done is a timestamp
        if n["deleted"] as? Bool == true { return false }
        return !((n["title"] as? String) ?? "").isEmpty
    }

    static func openTodos() -> [Todo] {
        if Demo.on { return [] }
        return json("notes.json").filter(isOpen).compactMap { n in
            guard let id = n["id"] as? String, let t = n["title"] as? String else { return nil }
            return Todo(id: id, title: t, project: n["project"] as? String ?? "")
        }
    }

    /// Ticks a to-do off in Measure.
    @discardableResult
    static func markDone(_ id: String) -> Bool {
        change { notes in
            guard let i = notes.firstIndex(where: { $0["id"] as? String == id }) else { return false }
            let now = Date().timeIntervalSince1970
            notes[i]["done"] = now
            notes[i]["updated"] = max(now, (notes[i]["updated"] as? Double ?? 0) + 0.001)
            return true
        }
    }

    /// New to-do in Measure. Returns its id.
    static func add(_ title: String, project: String? = nil) -> String? {
        let id = "note." + UUID().uuidString
        let ok = change { notes in
            let now = Date().timeIntervalSince1970
            var n: [String: Any] = ["id": id, "kind": "todo", "title": title, "text": "", "created": now, "updated": now]
            if let project, !project.isEmpty { n["project"] = project }
            notes.insert(n, at: 0)
            return true
        }
        return ok ? id : nil
    }

    /// Read, change, write atomically. Never writes when the file cannot be read.
    private static func change(_ edit: (inout [[String: Any]]) -> Bool) -> Bool {
        let url = folder.appendingPathComponent("notes.json")
        var notes: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
            notes = arr
        }
        guard edit(&notes),
              let out = try? JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let tmp = folder.appendingPathComponent(".notes-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try out.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// Lines for Claude's planner prompt.
    static func context(limit: Int = 25) -> String? {
        let all = items()
        guard !all.isEmpty else { return nil }
        let f = Fmt.f("EEE d MMM")
        return all.prefix(limit).map { i in
            var line = "  - " + i.title
            if !i.project.isEmpty { line += " [" + i.project + "]" }
            if let d = i.due { line += " (due " + f.string(from: d) + ")" }
            return line
        }.joined(separator: "\n")
    }

    /// Next deadlines within `days`, for the day review.
    static func dueSoon(days: Int = 7, now: Date = Date()) -> [Item] {
        let limit = Calendar.current.date(byAdding: .day, value: days, to: now)!
        return items().filter { ($0.due ?? .distantFuture) <= limit && ($0.due ?? .distantPast) >= Calendar.current.startOfDay(for: now) }
    }
}
