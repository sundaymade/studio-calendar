import Foundation

/// Everything personal lives in UserDefaults, so the code is the same for everyone.
/// Set with `defaults write works.sonntag.studiocalendar <key> …` (see README).
enum Profile {
    private static var d: UserDefaults { .standard }

    /// The first name Claude uses for you. Default: from your macOS account.
    static var name: String {
        if let n = d.string(forKey: "userName"), !n.isEmpty { return n }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "the user"
    }

    /// Language for Claude's short notes and meeting summaries, e.g. "German". Default: the Mac's language.
    static var language: String {
        if let l = d.string(forKey: "replyLanguage"), !l.isEmpty { return l }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// How messages Claude drafts for you should sound.
    static var messageStyle: String {
        d.string(forKey: "messageStyle") ?? "the language they write in, 1–2 short sentences, no greeting fluff"
    }

    /// Your main job: its label and the title words that mark its events.
    static var workLabel: String { d.string(forKey: "workLabel") ?? "Work" }
    static var workKeywords: [String] { (d.stringArray(forKey: "workKeywords") ?? []).map { $0.lowercased() } }

    /// Study or classes: label and title words.
    static var studyLabel: String { d.string(forKey: "studyLabel") ?? "Study" }
    static var studyKeywords: [String] {
        (d.stringArray(forKey: "studyKeywords")
            ?? ["uni ", "lecture", "seminar", "exam", "course", "vorlesung", "klausur"]).map { $0.lowercased() }
    }
}
