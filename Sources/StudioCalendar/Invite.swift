import Foundation

/// Sends a real Google Calendar invite with a Meet link, through the Google Calendar connector of your
/// Claude account. Runs only after you clicked "Send invite" on a proposal that shows every guest.
enum GoogleInvite {
    static let tools = ["mcp__claude_ai_Google_Calendar__list_events",
                        "mcp__claude_ai_Google_Calendar__create_event",
                        "mcp__claude_ai_Google_Calendar__update_event"]

    struct Outcome {
        var ok = false
        var meet: String?
        var notFound = false
    }

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    @MainActor
    static func send(title: String, start: Date, end: Date, guests: [String], meet: Bool, claude: Bool = false,
                     existing: CalEvent?, calendar: String) async -> Outcome {
        // Claude Meetings joins calls on its account's calendar, so that account goes on the invite too.
        var everyone = guests
        if claude, meet, !ClaudeMeetings.account.isEmpty, calendar.lowercased() != ClaudeMeetings.account, !everyone.contains(ClaudeMeetings.account) {
            everyone.append(ClaudeMeetings.account)
        }
        // Only your own accounts are added: nobody else needs a mail.
        let notify = guests.isEmpty ? "NONE" : "ALL"
        let attendees = everyone.map { "{\"email\":\"\($0)\"}" }.joined(separator: ",")
        let s = local.string(from: start), e = local.string(from: end)
        let json = "{\"ok\":true,\"meet\":\"<Google Meet URL or empty>\"}"
        let task: String
        if existing != nil {
            let from = local.string(from: start.addingTimeInterval(-60)), to = local.string(from: end.addingTimeInterval(60))
            task = """
            1. Call list_events with calendarId "\(calendar)", startTime "\(from)", endTime "\(to)". Find the event titled "\(title)".
            2. If you find it, call update_event once with calendarId "\(calendar)", that eventId, addedAttendees [\(attendees)],
               addGoogleMeetUrl \(meet), notificationLevel "\(notify)".
            3. If it is not there, call nothing else and reply exactly {"notfound":true}.
            """
        } else {
            task = """
            Call create_event once with calendarId "\(calendar)", summary "\(title)", startTime "\(s)", endTime "\(e)",
            attendees [\(attendees)], addGoogleMeetUrl \(meet), notificationLevel "\(notify)".
            """
        }
        let prompt = task + "\nDo nothing else. Then reply with only this JSON: \(json)"
        let system = "You carry out one confirmed calendar action for \(Profile.name) with the Google Calendar tools. Exactly as given, nothing more."
        guard let answer = await ClaudeOnce.ask(system: system, prompt: prompt, tools: tools) else { return Outcome() }
        var out = Outcome()
        if answer.contains("\"notfound\"") { out.notFound = true; return out }
        out.ok = answer.contains("\"ok\":true") || answer.contains("\"ok\": true") || answer.contains("meet.google.com")
        if let r = answer.range(of: #"https://meet\.google\.com/[a-z0-9\-]+"#, options: .regularExpression) {
            out.meet = String(answer[r])
        }
        return out
    }
}
