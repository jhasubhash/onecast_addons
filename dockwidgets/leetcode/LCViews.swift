import OnecastPluginKit
import SwiftUI

// MARK: - Style

extension Difficulty {
    /// LeetCode's own difficulty colours.
    var color: Color {
        switch self {
        case .easy: return Color(red: 0.0, green: 0.72, blue: 0.64)
        case .medium: return Color(red: 1.0, green: 0.72, blue: 0.0)
        case .hard: return Color(red: 1.0, green: 0.22, blue: 0.37)
        }
    }
}

private let flameColor = Color.orange
private let freezeColor = Color(red: 0.35, green: 0.7, blue: 1.0)

struct DifficultyPill: View {
    let difficulty: Difficulty
    var size: CGFloat = 10

    var body: some View {
        Text(difficulty.rawValue)
            .font(.system(size: size, weight: .semibold))
            .padding(.horizontal, size * 0.5).padding(.vertical, size * 0.15)
            .foregroundStyle(difficulty.color)
            .background(Capsule().fill(difficulty.color.opacity(0.16)))
            .lineLimit(1).fixedSize()
    }
}

/// The streak flame, lit while a streak is alive, with the count beside or under it.
struct StreakFlame: View {
    let streak: Int
    let done: Bool
    let nudging: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: streak > 0 || done ? "flame.fill" : "flame")
            .font(.system(size: size))
            .foregroundStyle(done ? flameColor : (streak > 0 ? flameColor.opacity(0.75) : Color.secondary))
            .symbolEffect(.pulse, options: .repeating, isActive: nudging)
    }
}

// MARK: - Tile

struct LCTile: View {
    let model: LCModel
    let context: DockWidgetContext

    private var L: CGFloat { context.tileLength }

    var body: some View {
        Group {
            switch context.size {
            case .compact: compact
            case .wide, .expanded:
                if context.edge.isVertical { vertical } else { horizontal }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { badge.padding(3) }
        .help(helpText)
    }

    private var helpText: String {
        if model.done { return "Solved today — \(model.streak)-day streak" }
        if let p = model.problem {
            let n = model.config.goal > 1 ? " · \(model.solvedToday) of \(model.config.goal) solved" : ""
            return "Today: \(p.title) (\(p.difficulty.rawValue))\(n)"
        }
        return model.pickError ?? (model.solvedToday > 0 ? "Finding your next problem…" : "Finding today's problem…")
    }

    /// Top-right corner: green check when done, a nudge when late, else today's difficulty.
    @ViewBuilder
    private var badge: some View {
        let d = max(7, L * 0.16)
        if model.done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: d * 1.2, weight: .bold))
                .foregroundStyle(.white, .green)
        } else if model.nudging {
            Circle().fill(.red).frame(width: d, height: d)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
        } else if let p = model.problem, context.size == .compact {
            Circle().fill(p.difficulty.color).frame(width: d * 0.8, height: d * 0.8)
        }
    }

    private var compact: some View {
        VStack(spacing: 0) {
            StreakFlame(streak: model.streak, done: model.done, nudging: model.nudging, size: L * 0.36)
            Text("\(model.streak)")
                .font(.system(size: L * 0.22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.streak > 0 ? .primary : .secondary)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private var horizontal: some View {
        HStack(spacing: L * 0.12) {
            compact.frame(width: L * 0.62)
            VStack(alignment: .leading, spacing: 2) {
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if context.size == .expanded {
                WeekStrip(model: model, cell: max(7, L * 0.13))
            }
        }
    }

    private var vertical: some View {
        VStack(spacing: 3) {
            compact
            if let p = model.problem, !model.done {
                DifficultyPill(difficulty: p.difficulty, size: max(7, L * 0.13))
                if model.config.goal > 1 { progress(max(7, L * 0.13)) }
            } else if model.done {
                Text("Done").font(.system(size: max(8, L * 0.15), weight: .semibold)).foregroundStyle(.green)
            }
            if context.size == .expanded {
                WeekStrip(model: model, cell: max(6, L * 0.11), vertical: true)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let small = max(8, L * 0.15)
        if model.done, let p = model.problem {
            Text("Done for today")
                .font(.system(size: max(9, L * 0.18), weight: .semibold)).foregroundStyle(.green)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(model.config.goal > 1 ? "\(model.solvedToday) problems solved" : p.title)
                .font(.system(size: small)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        } else if let p = model.problem {
            Text(p.title)
                .font(.system(size: max(9, L * 0.17), weight: .semibold))
                .lineLimit(2).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                DifficultyPill(difficulty: p.difficulty, size: max(7, L * 0.13))
                if model.config.goal > 1 { progress(small * 0.9) }
                if model.nudging {
                    Text(model.atRisk ? "streak at risk" : "not solved yet")
                        .font(.system(size: small * 0.9)).foregroundStyle(.red).lineLimit(1)
                }
            }
        } else if model.picking {
            ProgressView().controlSize(.small)
        } else if model.pickError != nil {
            Label("Couldn't load", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: small)).foregroundStyle(.orange)
        }
    }

    /// "1/3": problems solved today out of the daily goal.
    private func progress(_ size: CGFloat) -> some View {
        Text("\(model.solvedToday)/\(model.config.goal)")
            .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
}

/// The last seven days, oldest first: solved, frozen, missed or still open.
struct WeekStrip: View {
    let model: LCModel
    let cell: CGFloat
    var vertical = false

    var body: some View {
        let keys = (0..<7).reversed().map { Day.shift(model.today, by: -$0) }
        let layout = vertical ? AnyLayout(HStackLayout(spacing: cell * 0.35)) : AnyLayout(VStackLayout(spacing: cell * 0.35))
        let rows = vertical ? [keys] : [Array(keys.prefix(4)), Array(keys.suffix(3))]
        layout {
            ForEach(rows.indices, id: \.self) { r in
                (vertical ? AnyLayout(VStackLayout(spacing: cell * 0.35)) : AnyLayout(HStackLayout(spacing: cell * 0.35))) {
                    ForEach(rows[r], id: \.self) { key in
                        dot(key)
                    }
                }
            }
        }
    }

    private func dot(_ key: String) -> some View {
        let d = model.state.days[key]
        let color: Color = d?.solved == true ? (d?.hardest?.color ?? .green)
            : d?.frozen == true ? freezeColor
            : Color.primary.opacity(0.12)
        return Circle().fill(color)
            .overlay(Circle().strokeBorder(Color.primary.opacity(key == model.today ? 0.6 : 0), lineWidth: 1))
            .frame(width: cell, height: cell)
    }
}

// MARK: - Popover

struct LCPopover: View {
    @Bindable var model: LCModel
    let context: DockWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            levelBar
            if let c = model.celebration { celebration(c) }
            problemCard
            Divider()
            Heatmap(model: model)
            BadgeGrid(state: model.state)
            if model.showPrefs {
                Divider()
                PrefsPanel(model: model)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
        .onAppear { model.refreshOnOpen() }
        .animation(.snappy, value: model.done)
        .animation(.snappy, value: model.showPrefs)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Daily LeetCode").font(.headline)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                stat("flame.fill", "\(model.streak)", flameColor, "Current streak · best \(model.state.bestStreak)")
                stat("snowflake", "\(model.state.freezes)", freezeColor,
                     "Streak freezes (max \(Game.maxFreezes)). One is earned every \(Game.freezeEvery) streak days and spent automatically on a missed day.")
            }
        }
    }

    private func stat(_ symbol: String, _ value: String, _ color: Color, _ help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).monospacedDigit()
        }
        .help(help)
    }

    private var levelBar: some View {
        let lv = model.level
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Level \(lv.level) · \(Game.title(lv.level))").font(.caption.weight(.semibold))
                Spacer()
                Text("\(lv.into) / \(lv.span) XP").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(lv.into), total: Double(max(lv.span, 1)))
                .progressViewStyle(.linear).tint(.purple)
        }
    }

    private func celebration(_ c: LCModel.Celebration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "party.popper.fill").font(.title2).foregroundStyle(.yellow)
                .symbolEffect(.bounce, value: c)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.subheadline.weight(.semibold))
                ForEach(c.lines, id: \.self) { Text($0).font(.caption) }
            }
            Spacer(minLength: 0)
            Button { model.dismissCelebration() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.14)))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: Problem

    @ViewBuilder
    private var problemCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = model.problem {
                problem(p)
            } else if let error = model.pickError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Button("Try again") { model.retry() }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.solvedToday > 0 ? "Finding your next problem…" : "Finding today's problem…")
                        .foregroundStyle(.secondary)
                }
                earlierSolves(except: nil)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(model.done ? Color.green.opacity(0.6) : (model.nudging ? Color.red.opacity(0.5) : .clear), lineWidth: 1.5))
    }

    @ViewBuilder
    private func problem(_ p: LCProblem) -> some View {
        HStack(spacing: 6) {
            Text("#\(p.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
            DifficultyPill(difficulty: p.difficulty)
            if let ac = p.acRate {
                Text(String(format: "%.0f%% acceptance", ac)).font(.caption).foregroundStyle(.secondary)
            }
            if p.paid { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.yellow).help("Premium") }
            Spacer()
            if model.done {
                Label("Solved", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if model.config.goal > 1 {
                Text("\(model.solvedToday + 1) of \(model.config.goal)")
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        Button {
            context.actions.openURL(p.url)
        } label: {
            Text(p.title).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
                .strikethrough(model.done, color: .secondary)
        }
        .buttonStyle(.plain)
        .help(p.url.absoluteString)
        if !p.tags.isEmpty {
            Text(p.tags.prefix(4).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        earlierSolves(except: p.slug)

        if !model.done {
            if model.atRisk {
                Label("Solve today to keep your \(model.streak)-day streak", systemImage: "flame")
                    .font(.caption).foregroundStyle(model.nudging ? .red : .orange)
            } else if model.streak == 0 {
                Label("Solve today to start a streak", systemImage: "flame").font(.caption).foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 8) {
            Button {
                context.actions.openURL(p.url)
            } label: {
                Label("Open in LeetCode", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.done ? .secondary : p.difficulty.color)

            if model.done {
                Button("Undo") { model.undoSolved() }
                    .help(model.solvedToday > 1 ? "Mark your last solve unsolved again" : "Mark today's problem unsolved again")
            } else {
                Button {
                    model.markSolved()
                } label: {
                    Label("Solved", systemImage: "checkmark")
                }
                .help(model.solvedToday + 1 < model.config.goal ? "Mark solved and move to the next problem" : "Mark today's problem solved")
            }
            Spacer(minLength: 0)
            if !model.done {
                if model.solvedToday > 0 {
                    Button {
                        model.undoSolved()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Undo your last solve and go back to it")
                }
                Button {
                    model.skip()
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(model.skipsLeft == 0 || model.picking)
                .help(model.skipsLeft == 0 ? "No skips left today"
                      : "Skip for a different problem (\(model.skipsLeft) left today)")
            }
        }
        .controlSize(.regular)

        if model.picking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Picking another…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = model.pickError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        if !model.done && !model.hasUsername {
            Text("Tip: set your LeetCode username in Settings and the widget will spot your accepted solution by itself.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Today's other solved problems, each a link back to LeetCode.
    @ViewBuilder
    private func earlierSolves(except slug: String?) -> some View {
        let solves = (model.day?.solves ?? []).filter { $0.problem.slug != slug }
        if model.config.goal > 1, !solves.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Solved today").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(solves, id: \.problem.slug) { s in
                    Button {
                        context.actions.openURL(s.problem.url)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(s.problem.difficulty.color)
                            Text(s.problem.title).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("+\(s.xp) XP").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let s = model.stats {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.username).font(.caption.weight(.semibold))
                    HStack(spacing: 6) {
                        Text("\(s.total) solved").font(.caption2).foregroundStyle(.secondary)
                        Text("\(s.easy)").foregroundStyle(Difficulty.easy.color)
                        Text("\(s.medium)").foregroundStyle(Difficulty.medium.color)
                        Text("\(s.hard)").foregroundStyle(Difficulty.hard.color)
                    }
                    .font(.caption2.monospacedDigit())
                }
                .onTapGesture {
                    if let url = URL(string: "https://leetcode.com/u/\(s.username)/") { context.actions.openURL(url) }
                }
            } else if let e = model.userError {
                Label(e, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button {
                model.showPrefs.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Problem preferences")
            Button {
                context.actions.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Widget settings (username, session cookie, nudge time)")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Heatmap

/// The last 16 weeks, a column per week, coloured by the hardest problem solved that day.
struct Heatmap: View {
    let model: LCModel
    private let weeks = 16
    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        let today = model.today
        let weekday = (Day.date(today).map { Day.calendar.component(.weekday, from: $0) } ?? 1) - 1
        let start = Day.shift(today, by: -((weeks - 1) * 7 + weekday))
        let solved = Badge.solvedProblems(model.state)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last \(weeks) weeks").font(.caption.weight(.semibold))
                Spacer()
                Text("\(solved) solved · best streak \(model.state.bestStreak)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            square(Day.shift(start, by: w * 7 + d), today: today)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                legend(Difficulty.easy.color, "Easy")
                legend(Difficulty.medium.color, "Medium")
                legend(Difficulty.hard.color, "Hard")
                legend(freezeColor, "Freeze")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func square(_ key: String, today: String) -> some View {
        let d = model.state.days[key]
        let fill: Color = key > today ? .clear
            : d?.solved == true ? (d?.hardest?.color ?? .green)
            : d?.frozen == true ? freezeColor.opacity(0.7)
            : Color.primary.opacity(0.08)
        RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(key == today ? 0.55 : 0), lineWidth: 1))
            .frame(width: cell, height: cell)
            .help(tooltip(key, d))
    }

    private func tooltip(_ key: String, _ d: LCDay?) -> String {
        let date = Day.date(key)?.formatted(date: .abbreviated, time: .omitted) ?? key
        guard let d else { return date }
        if d.solves.count == 1, let s = d.solves.first {
            return "\(date): \(s.problem.title) (\(s.problem.difficulty.rawValue), +\(s.xp) XP)"
        }
        if d.solved { return "\(date): \(d.solves.map(\.problem.title).joined(separator: ", ")) (+\(d.xp) XP)" }
        if d.frozen { return "\(date): streak freeze" }
        if let p = d.problem { return "\(date): \(p.title) — not solved" }
        return date
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

// MARK: - Badges

struct BadgeGrid: View {
    let state: LCState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Badges · \(state.badges.count)/\(Badge.all.count)").font(.caption.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(Badge.all) { b in
                    let earned = state.badges[b.id]
                    Image(systemName: b.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(earned != nil ? Color.yellow : Color.secondary.opacity(0.35))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(earned != nil ? Color.yellow.opacity(0.15) : Color.primary.opacity(0.05)))
                        .help(earned.map { "\(b.name) — \(b.detail) (earned \($0.formatted(date: .abbreviated, time: .omitted)))" }
                              ?? "\(b.name) — \(b.detail)")
                }
            }
        }
    }
}

// MARK: - Preferences

struct PrefsPanel: View {
    let model: LCModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should I suggest?").font(.caption.weight(.semibold))

            Stepper(value: Binding(get: { model.config.goal }, set: { model.setGoal($0) }), in: 1...LCModel.maxGoal) {
                Text(model.config.goal == 1 ? "1 problem a day" : "\(model.config.goal) problems a day")
                    .font(.caption)
            }

            Picker("Source", selection: Binding(get: { model.config.source }, set: { model.setSource($0) })) {
                Text("Pick for me").tag(LCModel.Source.pick)
                Text("Daily challenge").tag(LCModel.Source.daily)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.config.source == .pick {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.config.difficulties.isEmpty ? "Difficulty · any" : "Difficulty")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(Difficulty.allCases, id: \.self) { d in
                            chip(d.rawValue, on: model.config.difficulties.contains(d), color: d.color) { model.toggle(d) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.config.topics.isEmpty ? "Topics · any" : "Topics · one per day, chosen at random")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !model.config.topics.isEmpty {
                            Button("Clear") { model.clearTopics() }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    Flow(spacing: 5) {
                        ForEach(topicSlugs, id: \.self) { slug in
                            chip(Topics.name(slug), on: model.config.topics.contains(slug), color: .accentColor) {
                                model.toggleTopic(slug)
                            }
                        }
                    }
                }
                Text("Changes apply from your next problem — skip to use them today.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(model.config.goal > 1
                     ? "The first problem is LeetCode's official daily challenge; the rest are picked for you."
                     : "Everyone gets the same problem: LeetCode's official daily challenge.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The listed topics, plus any typed into Settings that the list lacks.
    private var topicSlugs: [String] {
        let listed = Topics.all.map(\.slug)
        return listed + model.config.topics.filter { !listed.contains($0) }
    }

    private func chip(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(on ? color : .secondary)
                .background(Capsule().fill(on ? color.opacity(0.18) : Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(on ? color.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
