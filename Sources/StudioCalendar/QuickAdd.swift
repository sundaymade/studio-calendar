import Foundation

/// Turns "Lunch tomorrow 1pm" or "Mittag morgen 13 Uhr 30 min" into an event.
struct QuickParse: Equatable {
    var title: String
    var start: Date
    var end: Date

    static func parse(_ input: String, now: Date = Date()) -> QuickParse {
        let cal = Calendar.current
        var s = " " + input + " "
        var dayOffset = 0
        var explicitDay = false

        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            s = ns.replacingCharacters(in: m.range, with: " ")
            return groups
        }

        // Day words
        let relative: [(String, Int)] = [("day after tomorrow", 2), ("übermorgen", 2), ("tomorrow", 1), ("morgen", 1), ("today", 0), ("heute", 0), ("tonight", 0)]
        for (word, off) in relative where !explicitDay {
            if take("(?<=\\s)" + NSRegularExpression.escapedPattern(for: word) + "(?=\\s)") != nil { dayOffset = off; explicitDay = true }
        }
        if !explicitDay {
            let names: [(String, Int)] = [("monday|montag|mon", 2), ("tuesday|dienstag|tue|tues", 3), ("wednesday|mittwoch|wed", 4),
                                          ("thursday|donnerstag|thu|thurs", 5), ("friday|freitag|fri", 6), ("saturday|samstag|sat", 7), ("sunday|sonntag|sun", 1)]
            for (alts, weekday) in names {
                if take("(?<=\\s)(?:on |am )?(?:" + alts + ")(?=\\s)") != nil {
                    let todayW = cal.component(.weekday, from: now)
                    dayOffset = (weekday - todayW + 7) % 7
                    explicitDay = true
                    break
                }
            }
        }

        // Duration
        var minutes = 60
        if let g = take("(?<=\\s)(?:for )?(\\d+(?:[.,]\\d+)?)\\s*(minutes|minuten|mins|min|m|hours|hour|hrs|hr|h|stunden|stunde|std)(?=\\s)") {
            let n = Double(g[1].replacingOccurrences(of: ",", with: ".")) ?? 1
            minutes = g[2].lowercased().hasPrefix("m") ? Int(n) : Int(n * 60)
        }

        // Time
        var startMin: Int?
        if let g = take("(?<=\\s)(?:at |um |@)?(\\d{1,2})(?:[:.](\\d{2}))?\\s*(am|pm|uhr)?(?=\\s)") {
            var h = Int(g[1]) ?? 9
            let m = Int(g[2]) ?? 0
            let suffix = g[3].lowercased()
            if suffix == "pm" && h < 12 { h += 12 }
            if suffix == "am" && h == 12 { h = 0 }
            if h <= 23 && m <= 59 { startMin = h * 60 + m }
        }

        let today = cal.startOfDay(for: now)
        let day = cal.date(byAdding: .day, value: dayOffset, to: today)!
        let fallback: Int = {
            if dayOffset == 0 {
                let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
                return min((nowMin / 60 + 1) * 60, 23 * 60)
            }
            return 9 * 60
        }()
        let sm = startMin ?? fallback
        let start = cal.date(byAdding: .minute, value: sm, to: day)!
        let end = cal.date(byAdding: .minute, value: max(minutes, 5), to: start)!

        var title = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = "New event" } else { title = title.prefix(1).uppercased() + title.dropFirst() }
        return QuickParse(title: title, start: start, end: end)
    }
}
