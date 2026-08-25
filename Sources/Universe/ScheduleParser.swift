import Foundation

/// Schedule parsing — regexes extracted verbatim from Tama's binary (SPEC.md §3).
enum ScheduleParser {
    struct Parsed {
        enum Kind { case once(Date), interval(TimeInterval), cron(String) }
        var kind: Kind
        var scheduleType: String // "once" | "interval" | "cron"
    }

    private static let patterns: [(pattern: String, handler: (NSTextCheckingResult, String) -> Parsed?)] = [
        (#"^in\s+(\d+)\s*(hour|hr|minute|min|day|d)s?$"#, { m, s in
            once(offset: unitSeconds(s, m, 1, 2), type: "once")
        }),
        (#"^(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$"#, { m, s in
            once(offset: unitSeconds(s, m, 1, 2), type: "once")
        }),
        (#"^every\s+(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$"#, { m, s in
            guard let n = seconds(s, m, 1, 2) else { return nil }
            return Parsed(kind: .interval(n), scheduleType: "interval")
        }),
        (#"^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, { m, s in
            dayTime(s, m).map { Parsed(kind: .once($0), scheduleType: "once") }
        }),
    ]

    private static func once(offset: TimeInterval?, type: String) -> Parsed? {
        offset.map { Parsed(kind: .once(Date().addingTimeInterval($0)), scheduleType: type) }
    }

    private static func seconds(_ s: String, _ m: NSTextCheckingResult, _ n: Int, _ u: Int) -> TimeInterval? {
        guard let value = Double((s as NSString).substring(with: m.range(at: n))) else { return nil }
        let unit = (s as NSString).substring(with: m.range(at: u)).lowercased()
        switch unit {
        case "m", "min", "mins", "minute", "minutes": return value * 60
        case "h", "hr", "hrs", "hour", "hours": return value * 3600
        case "d", "day", "days": return value * 86400
        default: return nil
        }
    }

    private static let unitSeconds = seconds

    private static func dayTime(_ s: String, _ m: NSTextCheckingResult) -> Date? {
        let ns = s as NSString
        let day = ns.substring(with: m.range(at: 1)).lowercased()
        guard var hour = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        let minute = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
        let ampm = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)).lowercased() : ""
        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }

        let calendar = Calendar.current
        let now = Date()
        var target: Date?
        switch day {
        case "today":
            target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            if let t = target, t <= now { target = calendar.date(byAdding: .day, value: 1, to: t) }
        case "tomorrow":
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
        default: // weekday name
            let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
            guard let wanted = weekdays[day] else { return nil }
            var delta = (wanted - calendar.component(.weekday, from: now) + 7) % 7
            let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: delta, to: now)!)!
            if delta == 0, candidate <= now { delta = 7 }
            target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: delta, to: now)!)
        }
        return target
    }

    /// Parse a schedule string. Accepts the regex forms above or a 5-field cron expression.
    static func parse(_ input: String) -> Parsed? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        for (pattern, handler) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            if let match = regex.firstMatch(in: s, range: range), match.range.location == 0 {
                if let parsed = handler(match, s) { return parsed }
            }
        }
        if CronSchedule.isValid(s) {
            return Parsed(kind: .cron(s), scheduleType: "cron")
        }
        return nil
    }

    /// Next run after a given date for a parsed schedule.
    static func nextRun(_ parsed: Parsed, after date: Date = Date()) -> Date? {
        switch parsed.kind {
        case .once(let d): return d > date ? d : nil
        case .interval(let t): return date.addingTimeInterval(t)
        case .cron(let expr): return CronSchedule.next(after: date, expression: expr)
        }
    }
}

/// Minimal 5-field cron: minute hour day-of-month month day-of-week. Supports * , lists, ranges, */n.
/// simplification: scans minute-by-minute up to 366 days ahead; upgrade path is a real cron library.
enum CronSchedule {
    static func isValid(_ expr: String) -> Bool {
        parse(expr) != nil
    }

    private static func parse(_ expr: String) -> [[Int]]? {
        let fields = expr.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }
        let ranges = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 6)]
        var parsed: [[Int]] = []
        for (i, field) in fields.enumerated() {
            guard let values = parseField(field, min: ranges[i].0, max: ranges[i].1) else { return nil }
            parsed.append(values)
        }
        return parsed
    }

    private static func parseField(_ field: String, min lo: Int, max hi: Int) -> [Int]? {
        var values = Set<Int>()
        for part in field.split(separator: ",") {
            let p = String(part)
            if let step = p.range(of: "*/") {
                guard let n = Int(p[step.upperBound...]), n > 0 else { return nil }
                for v in stride(from: lo, through: hi, by: n) { values.insert(v) }
            } else if p == "*" {
                for v in lo...hi { values.insert(v) }
            } else if let dash = p.firstIndex(of: "-") {
                guard let a = Int(p[..<dash]), let b = Int(p[p.index(after: dash)...]),
                      a >= lo, b <= hi, a <= b else { return nil }
                for v in a...b { values.insert(v) }
            } else if let v = Int(p), v >= lo, v <= hi {
                values.insert(v)
            } else {
                return nil
            }
        }
        return values.sorted()
    }

    static func next(after date: Date, expression: String) -> Date? {
        guard let fields = parse(expression) else { return nil }
        let calendar = Calendar.current
        var candidate = calendar.date(byAdding: .minute, value: 1, to: date)!
        candidate = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate))!
        for _ in 0..<(366 * 24 * 60) {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            // cron weekday: 0=Sunday; Calendar weekday: 1=Sunday
            if fields[0].contains(c.minute!), fields[1].contains(c.hour!),
               fields[2].contains(c.day!), fields[3].contains(c.month!),
               fields[4].contains(c.weekday! - 1) {
                return candidate
            }
            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate)!
        }
        return nil
    }
}
