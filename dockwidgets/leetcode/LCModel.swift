import Foundation
import Observation
import OnecastPluginKit

/// What the tile and popover read. One per widget instance; the game state itself is shared
/// through `LCStore`, re-read before every change so two tiles never overwrite each other.
@MainActor
@Observable
final class LCModel {
    enum Source: String { case pick, daily }

    struct Config: Equatable {
        var username: String?
        var session: String?
        var source: Source = .pick
        var difficulties: [Difficulty] = []
        var topics: [String] = []
        var includePaid = false
        var nudgeHour = 18
        /// The daily reminder's time, or nil when reminders are off.
        var reminder: Reminder?
    }

    struct Reminder: Equatable {
        var hour: Int
        var minute: Int
        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    private(set) var config = Config()
    private(set) var state = LCStore.load()
    private(set) var today = Day.key(Date())
    /// Advances every minute, so the nudge and the day rollover show without a click.
    private(set) var now = Date()
    private(set) var picking = false
    private(set) var pickError: String?
    private(set) var stats: LCUserStats?
    private(set) var userError: String?
    /// A message shown in the popover after a solve, a badge or a freeze.
    private(set) var celebration: Celebration?

    /// Whether the popover shows the preferences panel; kept here because the host may rebuild
    /// the popover view.
    var showPrefs = false

    struct Celebration: Equatable {
        var title: String
        var lines: [String]
    }

    private var prefs: DockWidgetPreferences?
    private var services: OnecastHostServices?
    private var actions: DockWidgetActions?
    /// The reminder last registered with Onecast; re-registered only when it changes.
    private var registeredReminder: Reminder??
    private var reminderCard: String?
    private var loop: Task<Void, Never>?
    private var pickTask: Task<Void, Never>?
    private var lastSolveCheck = Date.distantPast
    private var lastStatsFetch = Date.distantPast
    /// Slugs from the user's recent accepted submissions, excluded from picks.
    private var recentSolved: Set<String> = []
    private let presence = Presence()

    init() {
        presence.onChange = { [weak self] in self?.startLoop() }
    }

    // MARK: Derived

    var day: LCDay? { state.days[today] }
    var problem: LCProblem? { day?.problem }
    var done: Bool { day?.solved ?? false }
    var streak: Int { Game.streak(state, today: today) }
    var skipsLeft: Int { max(0, Game.skipsPerDay - (day?.skips ?? 0)) }
    var level: (level: Int, into: Int, span: Int) { Game.level(state.xp) }
    var hasUsername: Bool { !(config.username ?? "").isEmpty }

    /// Late in the day with nothing solved: the tile starts asking for attention.
    var nudging: Bool {
        !done && Day.calendar.component(.hour, from: now) >= config.nudgeHour
    }

    /// The streak is alive but ends tonight unless today is solved.
    var atRisk: Bool { !done && streak > 0 }

    // MARK: Settings

    func apply(_ context: DockWidgetContext) {
        prefs = context.preferences
        services = context.services
        actions = context.actions
        reloadConfig()
    }

    private func reloadConfig() {
        guard let p = prefs else { return }
        let trimmed = { (s: String?) -> String? in
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let new = Config(
            username: trimmed(p.string("username")),
            session: trimmed(p.string("session")),
            source: Source(rawValue: p.string("source") ?? "") ?? .pick,
            difficulties: Self.difficulties(p.string("difficulty")),
            topics: Self.topics(p.string("topics")),
            includePaid: p.bool("includePaid"),
            nudgeHour: min(23, max(0, p.integer("nudgeHour") ?? 18)),
            reminder: p.bool("reminder") ? Self.reminder(p.string("reminderTime")) : nil)
        let old = config
        config = new
        syncReminder()
        if new.username != old.username {
            stats = nil
            userError = nil
            recentSolved = []
            lastSolveCheck = .distantPast
            lastStatsFetch = .distantPast
        }
        if loop == nil || new != old { startLoop() }
    }

    /// Reads "20:00", "8:30" or "20"; anything else falls back to 20:00.
    static func reminder(_ raw: String?) -> Reminder {
        let parts = (raw ?? "").split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let h = parts.first ?? nil, (0...23).contains(h) else { return Reminder(hour: 20, minute: 0) }
        let m = parts.count > 1 ? (parts[1] ?? 0) : 0
        return Reminder(hour: h, minute: (0...59).contains(m) ? m : 0)
    }

    static func difficulties(_ raw: String?) -> [Difficulty] {
        let set = (raw ?? "").lowercased().split(separator: ",")
            .compactMap { Difficulty(rawValue: $0.trimmingCharacters(in: .whitespaces).capitalized) }
        return Difficulty.allCases.filter(set.contains)
    }

    static func topics(_ raw: String?) -> [String] {
        var seen = Set<String>()
        return (raw ?? "").lowercased().split(whereSeparator: { ", ;\n".contains($0) })
            .map(String.init).filter { seen.insert($0).inserted }
    }

    // MARK: Preference edits from the popover

    func toggle(_ d: Difficulty) {
        var set = Set(config.difficulties)
        if set.contains(d) { set.remove(d) } else { set.insert(d) }
        // All three is the same as none.
        let value = set.count == Difficulty.allCases.count || set.isEmpty
            ? "any" : Difficulty.allCases.filter(set.contains).map { $0.rawValue.lowercased() }.joined(separator: ",")
        prefs?.set(value, for: "difficulty")
        reloadConfig()
    }

    func toggleTopic(_ slug: String) {
        var list = config.topics
        if let i = list.firstIndex(of: slug) { list.remove(at: i) } else { list.append(slug) }
        prefs?.set(list.isEmpty ? nil : list.joined(separator: ","), for: "topics")
        reloadConfig()
    }

    func clearTopics() {
        prefs?.set(nil, for: "topics")
        reloadConfig()
    }

    func setSource(_ s: Source) {
        prefs?.set(s.rawValue, for: "source")
        reloadConfig()
    }

    // MARK: Actions

    /// Marks today's problem solved, awards XP, badges and maybe a freeze.
    func markSolved(at: Date = Date(), auto: Bool = false) {
        mutate { s in
            guard var d = s.days[today], d.problem != nil, !d.solved else { return }
            d.solvedAt = at
            d.auto = auto
            s.days[today] = d
            let n = Game.streak(s, today: today)
            let gained = Game.xp(for: d.problem!.difficulty, streak: n)
            d.xp = gained
            s.days[today] = d
            s.xp += gained
            s.solved.insert(d.problem!.slug)
            let newRecord = n > s.bestStreak
            s.bestStreak = max(s.bestStreak, n)

            var lines = ["+\(gained) XP" + (n > 1 ? " · \(n)-day streak" : "")]
            if newRecord && n > 1 { lines.append("New best streak!") }
            if n % Game.freezeEvery == 0 && s.freezes < Game.maxFreezes {
                s.freezes += 1
                lines.append("Earned a streak freeze ❄︎")
            }
            let before = Game.level(s.xp - gained).level
            let after = Game.level(s.xp).level
            if after > before { lines.append("Level \(after) — \(Game.title(after))") }
            for b in Badge.all where s.badges[b.id] == nil && b.earned(s, n, at) {
                s.badges[b.id] = at
                lines.append("Badge: \(b.name)")
            }
            celebration = Celebration(
                title: auto ? "Spotted your solve — done for today!" : "Done for today!", lines: lines)
        }
        if done { withdrawReminder() }
    }

    func undoSolved() {
        mutate { s in
            guard var d = s.days[today], d.solved else { return }
            s.xp = max(0, s.xp - d.xp)
            if let slug = d.problem?.slug,
               !s.days.contains(where: { $0.key != today && $0.value.solved && $0.value.problem?.slug == slug }) {
                s.solved.remove(slug)
            }
            d.solvedAt = nil
            d.xp = 0
            d.auto = false
            s.days[today] = d
            // Best streak and badges stay: they were earned at the time.
        }
        celebration = nil
    }

    /// Replaces today's problem with a fresh pick, up to `Game.skipsPerDay` times.
    func skip() {
        guard !done, skipsLeft > 0 else { return }
        if let slug = problem?.slug {
            mutate { s in
                s.skipped.append(slug)
                if s.skipped.count > 1000 { s.skipped.removeFirst(s.skipped.count - 1000) }
                s.days[today, default: LCDay()].skips += 1
            }
        }
        assign(force: true, source: .pick)
    }

    func dismissCelebration() { celebration = nil }

    /// The popover opened: catch up on the day, re-read shared state and look for a solve.
    func refreshOnOpen() {
        state = LCStore.load()
        lastSolveCheck = .distantPast
        if problem == nil { pickError = nil }
        startLoop()
    }

    func retry() {
        pickError = nil
        assign(force: true, source: config.source)
    }

    // MARK: Reminder

    private static let reminderID = "daily-reminder"
    private static let snoozeID = "snooze"

    /// Registers the daily reminder with Onecast's scheduler, which keeps time even while the
    /// popover is closed and catches up once after the Mac sleeps through it.
    private func syncReminder() {
        guard let services, registeredReminder != .some(config.reminder) else { return }
        registeredReminder = .some(config.reminder)
        guard let r = config.reminder else {
            services.unschedule(Self.reminderID)
            services.unschedule(Self.snoozeID)
            return
        }
        services.schedule(
            OnecastSchedule(id: Self.reminderID, title: "Daily problem at \(r.label)",
                            rule: .daily(hour: r.hour, minute: r.minute))
        ) { [weak self] fire in self?.remind(fire) }
    }

    /// Stays quiet once today is solved, and drops a fire missed on an earlier day.
    private func remind(_ fire: OnecastScheduleFire) {
        guard Day.calendar.isDate(fire.date, inSameDayAs: Date()) else { return }
        today = Day.key(Date())
        state = LCStore.load()
        guard !done, let services else { return }
        withdrawReminder()
        let title = streak > 0 ? "Keep your \(streak)-day streak alive 🔥" : "Time for today's LeetCode"
        let body = problem.map { "\($0.title) · \($0.difficulty.rawValue)" } ?? "Your daily problem is waiting."
        var buttons = [OnecastNotificationAction(id: "snooze", title: "In 1 hour")]
        if problem != nil {
            buttons.insert(OnecastNotificationAction(id: "solved", title: "Solved"), at: 0)
            buttons.insert(OnecastNotificationAction(id: "open", title: "Open"), at: 0)
        }
        reminderCard = services.notify(
            OnecastNotification(title: title, body: body, tint: .orange, actions: buttons, dwell: nil,
                                playsSound: true)
        ) { [weak self] action in self?.answer(action) }
    }

    private func answer(_ action: String) {
        withdrawReminder()
        switch action {
        case "open":
            if let url = problem?.url { actions?.openURL(url) }
        case "solved":
            markSolved()
        case "snooze":
            services?.schedule(
                OnecastSchedule(id: Self.snoozeID, title: "Snoozed problem reminder",
                                rule: .once(Date().addingTimeInterval(3600)))
            ) { [weak self] fire in self?.remind(fire) }
        default:
            break
        }
    }

    private func withdrawReminder() {
        if let card = reminderCard { services?.dismissNotification(card) }
        reminderCard = nil
    }

    // MARK: Assignment

    /// Gives today a problem if it has none. `force` replaces the current one.
    private func assign(force: Bool = false, source: Source) {
        if !force, problem != nil { return }
        if pickTask != nil && !force { return }
        pickTask?.cancel()
        picking = true
        pickError = nil
        let cfg = config
        let forDay = today
        var exclude = state.solved.union(state.skipped).union(recentSolved)
        exclude.formUnion(state.days.values.compactMap { $0.problem?.slug })
        let request = PickRequest(
            difficulties: cfg.difficulties, topics: cfg.topics, includePaid: cfg.includePaid,
            exclude: exclude, session: cfg.session)
        pickTask = Task { [weak self] in
            do {
                let p: LCProblem
                if source == .daily {
                    p = try await LCClient.daily(session: cfg.session)
                } else {
                    p = try await LCClient.pick(request)
                }
                guard !Task.isCancelled, let self else { return }
                self.mutate { s in
                    var d = s.days[forDay] ?? LCDay()
                    // Solved meanwhile, or another tile already gave the day a problem.
                    guard !d.solved, force || d.problem == nil else { return }
                    d.problem = p
                    s.days[forDay] = d
                }
                self.picking = false
                self.pickTask = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.pickError = error.localizedDescription
                self.picking = false
                self.pickTask = nil
            }
        }
    }

    // MARK: Loop

    private func startLoop() {
        loop?.cancel()
        loop = nil
        guard presence.active else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tick() async {
        now = Date()
        let key = Day.key(now)
        if key != today {
            today = key
            celebration = nil
            pickError = nil
            state = LCStore.load()
        }
        // Another tile may have already handled today; only spend freezes once per day.
        mutate { s in
            let spent = Game.applyFreezes(&s, today: today)
            if spent > 0 {
                celebration = Celebration(
                    title: "Streak saved ❄︎",
                    lines: ["Used \(spent) streak freeze\(spent == 1 ? "" : "s") for the day\(spent == 1 ? "" : "s") you missed."])
            }
        }
        if problem == nil && pickError == nil { assign(source: config.source) }
        await checkUser()
    }

    /// With a username: notices an accepted submission of today's problem, learns recent solves
    /// to exclude, and keeps the profile numbers current.
    private func checkUser() async {
        guard let username = config.username else { return }
        if Date().timeIntervalSince(lastSolveCheck) >= 5 * 60, !done || recentSolved.isEmpty {
            lastSolveCheck = Date()
            do {
                let solves = try await LCClient.recentSolves(username: username)
                recentSolved = Set(solves.map(\.slug))
                userError = nil
                let start = Day.calendar.startOfDay(for: Date())
                if !done, let slug = problem?.slug,
                   let hit = solves.first(where: { $0.slug == slug && $0.at >= start }) {
                    markSolved(at: hit.at, auto: true)
                }
            } catch {
                userError = error.localizedDescription
            }
        }
        if Date().timeIntervalSince(lastStatsFetch) >= 15 * 60 {
            lastStatsFetch = Date()
            stats = try? await LCClient.stats(username: username)
        }
    }

    // MARK: Persistence

    /// Re-reads the shared file, applies the change and writes it back, so two tiles that both
    /// change state never lose each other's edit.
    private func mutate(_ change: (inout LCState) -> Void) {
        let before = LCStore.load()
        var s = before
        change(&s)
        if s != before { LCStore.save(s) }
        state = s
    }

    func stop() {
        loop?.cancel()
        pickTask?.cancel()
        presence.stop()
        loop = nil
        pickTask = nil
    }
}
