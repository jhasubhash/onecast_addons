import Foundation

// MARK: - State

/// One calendar day. A day exists once a problem is assigned to it, or when a streak freeze covers
/// it.
struct LCDay: Codable, Equatable {
    var problem: LCProblem?
    var solvedAt: Date?
    /// A streak freeze bridged this day: it keeps the streak alive without adding to it.
    var frozen = false
    var skips = 0
    var xp = 0
    /// Marked by the widget on seeing an accepted submission, not by hand.
    var auto = false

    var solved: Bool { solvedAt != nil }
    /// Whether this day keeps a streak going.
    var counts: Bool { solved || frozen }

    init(problem: LCProblem? = nil, frozen: Bool = false) {
        self.problem = problem
        self.frozen = frozen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        problem = try c.decodeIfPresent(LCProblem.self, forKey: .problem)
        solvedAt = try c.decodeIfPresent(Date.self, forKey: .solvedAt)
        frozen = try c.decodeIfPresent(Bool.self, forKey: .frozen) ?? false
        skips = try c.decodeIfPresent(Int.self, forKey: .skips) ?? 0
        xp = try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
    }
}

/// Everything the game remembers. Shared by every LeetCode tile, so a streak survives removing a
/// tile or adding a second one.
struct LCState: Codable, Equatable {
    /// Keyed by local `yyyy-MM-dd`.
    var days: [String: LCDay] = [:]
    /// Slugs solved through the widget, never suggested again.
    var solved: Set<String> = []
    /// Slugs skipped, newest last, never suggested again. Capped so the file stays small.
    var skipped: [String] = []
    var xp = 0
    var freezes = 0
    var bestStreak = 0
    var badges: [String: Date] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: LCDay].self, forKey: .days) ?? [:]
        solved = try c.decodeIfPresent(Set<String>.self, forKey: .solved) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        xp = try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0
        freezes = try c.decodeIfPresent(Int.self, forKey: .freezes) ?? 0
        bestStreak = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        badges = try c.decodeIfPresent([String: Date].self, forKey: .badges) ?? [:]
    }
}

/// Reads and writes `state.json` under Onecast's Application Support folder — beside, not inside,
/// `dockwidgets/`, whose watcher would rebuild the widget on every write.
enum LCStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "com.onecast.app"
        return base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("dockwidget-data/leetcode", isDirectory: true)
            .appendingPathComponent("state.json")
    }()

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> LCState {
        guard let data = try? Data(contentsOf: url) else { return LCState() }
        return (try? decoder.decode(LCState.self, from: data)) ?? LCState()
    }

    static func save(_ state: LCState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("LeetCode widget: couldn't save state: \(error)")
        }
    }
}

// MARK: - Calendar

enum Day {
    static var calendar: Calendar { .current }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(_ key: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: key)
    }

    static func shift(_ key: String, by days: Int) -> String {
        guard let d = date(key), let moved = calendar.date(byAdding: .day, value: days, to: d) else { return key }
        return Day.key(moved)
    }
}

// MARK: - Rules

enum Game {
    static let maxFreezes = 2
    static let skipsPerDay = 3
    /// A freeze is earned each time the streak reaches a multiple of this.
    static let freezeEvery = 7

    /// Solved days in the unbroken chain ending today (or yesterday, while today is still open).
    /// Frozen days bridge the chain without adding to it.
    static func streak(_ s: LCState, today: String) -> Int {
        var day = s.days[today]?.counts == true ? today : Day.shift(today, by: -1)
        var n = 0
        while let d = s.days[day], d.counts {
            if d.solved { n += 1 }
            day = Day.shift(day, by: -1)
        }
        return n
    }

    /// Spends freezes on the days missed since the last active one, if there are enough to cover
    /// every one of them; otherwise the streak is lost and the freezes are kept. Returns how many
    /// were spent.
    @discardableResult
    static func applyFreezes(_ s: inout LCState, today: String) -> Int {
        guard s.freezes > 0 else { return 0 }
        var missed: [String] = []
        var day = Day.shift(today, by: -1)
        // Look back no further than the freezes could cover.
        while missed.count <= s.freezes {
            if s.days[day]?.counts == true { break }
            missed.append(day)
            day = Day.shift(day, by: -1)
        }
        guard !missed.isEmpty, missed.count <= s.freezes, streak(s, today: day) > 0 else { return 0 }
        for m in missed {
            var d = s.days[m] ?? LCDay()
            d.frozen = true
            s.days[m] = d
        }
        s.freezes -= missed.count
        return missed.count
    }

    /// XP for a solve: the difficulty's base, plus 10% per streak day up to double.
    static func xp(for difficulty: Difficulty, streak: Int) -> Int {
        let bonus = 1 + 0.1 * Double(min(max(streak - 1, 0), 10))
        return Int((Double(difficulty.xp) * bonus).rounded())
    }

    // MARK: Levels

    /// Level n starts at 50·n·(n−1) XP: 0, 100, 300, 600, 1000, …
    static func levelStart(_ n: Int) -> Int { 50 * n * (n - 1) }

    static func level(_ xp: Int) -> (level: Int, into: Int, span: Int) {
        var n = 1
        while levelStart(n + 1) <= xp { n += 1 }
        return (n, xp - levelStart(n), levelStart(n + 1) - levelStart(n))
    }

    static func title(_ level: Int) -> String {
        switch level {
        case ..<3: return "Novice"
        case 3..<5: return "Apprentice"
        case 5..<8: return "Problem Solver"
        case 8..<12: return "Algorithmist"
        case 12..<18: return "Grandmaster"
        default: return "Legend"
        }
    }
}

// MARK: - Badges

struct Badge: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let detail: String
    let earned: (_ s: LCState, _ streak: Int, _ solvedAt: Date) -> Bool

    static let all: [Badge] = [
        Badge(id: "first", name: "First Blood", symbol: "flag.checkered", detail: "Solve your first problem") { s, _, _ in
            solvedDays(s) >= 1
        },
        Badge(id: "streak3", name: "Warming Up", symbol: "flame", detail: "3-day streak") { _, n, _ in n >= 3 },
        Badge(id: "streak7", name: "On Fire", symbol: "flame.fill", detail: "7-day streak") { _, n, _ in n >= 7 },
        Badge(id: "streak30", name: "Unstoppable", symbol: "bolt.fill", detail: "30-day streak") { _, n, _ in n >= 30 },
        Badge(id: "streak100", name: "Centurion", symbol: "crown.fill", detail: "100-day streak") { _, n, _ in n >= 100 },
        Badge(id: "hard", name: "Hard Hitter", symbol: "dumbbell.fill", detail: "Solve a Hard problem") { s, _, _ in
            s.days.values.contains { $0.solved && $0.problem?.difficulty == .hard }
        },
        Badge(id: "solved10", name: "Ten Down", symbol: "10.circle.fill", detail: "Solve 10 daily problems") { s, _, _ in
            solvedDays(s) >= 10
        },
        Badge(id: "solved50", name: "Half Century", symbol: "star.fill", detail: "Solve 50 daily problems") { s, _, _ in
            solvedDays(s) >= 50
        },
        Badge(id: "solved100", name: "Triple Digits", symbol: "trophy.fill", detail: "Solve 100 daily problems") { s, _, _ in
            solvedDays(s) >= 100
        },
        Badge(id: "early", name: "Early Bird", symbol: "sunrise.fill", detail: "Solve before 8 am") { _, _, at in
            Day.calendar.component(.hour, from: at) < 8
        },
        Badge(id: "night", name: "Night Owl", symbol: "moon.stars.fill", detail: "Solve after 11 pm") { _, _, at in
            Day.calendar.component(.hour, from: at) >= 23
        },
        Badge(id: "noskip", name: "No Excuses", symbol: "hand.raised.fill", detail: "Solve 7 days in a row without skipping") { s, n, _ in
            n >= 7 && noSkipRun(s) >= 7
        },
    ]

    static func solvedDays(_ s: LCState) -> Int { s.days.values.filter(\.solved).count }

    /// Consecutive solved days, newest first, on which no problem was skipped.
    private static func noSkipRun(_ s: LCState) -> Int {
        var day = Day.key(Date())
        if s.days[day]?.solved != true { day = Day.shift(day, by: -1) }
        var n = 0
        while let d = s.days[day], d.solved, d.skips == 0 {
            n += 1
            day = Day.shift(day, by: -1)
        }
        return n
    }
}
