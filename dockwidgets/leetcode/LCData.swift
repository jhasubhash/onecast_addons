import Foundation

// MARK: - Problems

enum Difficulty: String, Codable, CaseIterable, Sendable {
    case easy = "Easy", medium = "Medium", hard = "Hard"

    /// The value LeetCode's `QuestionListFilterInput.difficulty` takes.
    var api: String { rawValue.uppercased() }

    /// XP for solving one, before the streak bonus.
    var xp: Int {
        switch self {
        case .easy: return 10
        case .medium: return 25
        case .hard: return 50
        }
    }
}

struct LCProblem: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var slug: String
    var difficulty: Difficulty
    var acRate: Double?
    var paid: Bool
    var tags: [String]

    var url: URL { URL(string: "https://leetcode.com/problems/\(slug)/")! }
}

struct LCSolve: Sendable {
    var slug: String
    var title: String
    var at: Date
}

struct LCUserStats: Sendable, Equatable {
    var username: String
    var easy: Int
    var medium: Int
    var hard: Int
    var total: Int { easy + medium + hard }
}

/// What the picker draws from. Empty sets mean "any".
struct PickRequest: Sendable {
    var difficulties: [Difficulty]
    var topics: [String]
    var includePaid: Bool
    var exclude: Set<String>
    var session: String?
}

enum LCError: LocalizedError {
    case http(Int)
    case graphQL(String)
    case noMatch

    var errorDescription: String? {
        switch self {
        case .http(let code): return "LeetCode answered HTTP \(code)."
        case .graphQL(let message): return message
        case .noMatch: return "No unsolved problem matches your preferences. Loosen the difficulty or topics."
        }
    }
}

// MARK: - Client

/// LeetCode's public GraphQL endpoint. Every query here works without signing in; a session cookie
/// only adds each question's `status`, so problems solved before the widget existed are skipped.
enum LCClient {
    private static let endpoint = URL(string: "https://leetcode.com/graphql")!

    private struct Envelope<D: Decodable>: Decodable {
        struct GQLError: Decodable { let message: String }
        let data: D?
        let errors: [GQLError]?
    }

    private static func post<D: Decodable>(
        _ query: String, _ variables: [String: Any] = [:], session: String? = nil, as: D.Type
    ) async throws -> D {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://leetcode.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh) Onecast-LeetCode-Widget", forHTTPHeaderField: "User-Agent")
        if let cookie = cookieHeader(session) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LCError.http(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(Envelope<D>.self, from: data)
        if let d = envelope.data, envelope.errors?.isEmpty ?? true { return d }
        throw LCError.graphQL(envelope.errors?.first?.message ?? "LeetCode returned no data.")
    }

    /// Accepts the bare `LEETCODE_SESSION` value or a whole copied `Cookie:` string.
    private static func cookieHeader(_ session: String?) -> String? {
        guard let s = session?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.contains("LEETCODE_SESSION=") ? s : "LEETCODE_SESSION=\(s)"
    }

    // MARK: Questions

    private struct RawQuestion: Decodable {
        struct Tag: Decodable { let name: String; let slug: String }
        let questionFrontendId: String
        let title: String
        let titleSlug: String
        let difficulty: String
        let isPaidOnly: Bool
        let acRate: Double?
        let status: String?
        let topicTags: [Tag]?

        var problem: LCProblem? {
            guard let d = Difficulty(rawValue: difficulty) else { return nil }
            return LCProblem(
                id: questionFrontendId, title: title, slug: titleSlug, difficulty: d,
                acRate: acRate, paid: isPaidOnly, tags: (topicTags ?? []).map(\.name))
        }
    }

    private static let fields = "questionFrontendId title titleSlug difficulty isPaidOnly acRate status topicTags { name slug }"

    private struct ListData: Decodable {
        struct List: Decodable { let totalNum: Int; let data: [RawQuestion] }
        let questionList: List
    }

    private static func questions(
        difficulty: Difficulty?, tag: String?, skip: Int, limit: Int, session: String?
    ) async throws -> (total: Int, items: [RawQuestion]) {
        var filters: [String: Any] = [:]
        if let difficulty { filters["difficulty"] = difficulty.api }
        if let tag { filters["tags"] = [tag] }
        let query = """
        query q($categorySlug: String, $limit: Int, $skip: Int, $filters: QuestionListFilterInput) {
          questionList(categorySlug: $categorySlug, limit: $limit, skip: $skip, filters: $filters) {
            totalNum data { \(fields) }
          }
        }
        """
        let d = try await post(
            query, ["categorySlug": "", "limit": limit, "skip": skip, "filters": filters],
            session: session, as: ListData.self)
        return (d.questionList.totalNum, d.questionList.data)
    }

    /// A random problem that fits the request. Tries the chosen difficulty and topic first, then
    /// other topics, then drops the topic, then the difficulty, so a narrow mix still yields
    /// something rather than an error.
    static func pick(_ r: PickRequest) async throws -> LCProblem {
        let difficulty = r.difficulties.randomElement()
        var attempts: [(Difficulty?, String?)] = []
        for tag in r.topics.shuffled().prefix(3) { attempts.append((difficulty, tag)) }
        attempts.append((difficulty, nil))
        if difficulty != nil { attempts.append((nil, r.topics.randomElement())) }
        attempts.append((nil, nil))

        var tried = Set<String>()
        for (d, tag) in attempts where tried.insert("\(d?.api ?? "")|\(tag ?? "")").inserted {
            if let found = try await pickOne(d, tag, r) { return found }
        }
        throw LCError.noMatch
    }

    private static func pickOne(_ difficulty: Difficulty?, _ tag: String?, _ r: PickRequest) async throws -> LCProblem? {
        let total = try await questions(difficulty: difficulty, tag: tag, skip: 0, limit: 1, session: r.session).total
        guard total > 0 else { return nil }
        let page = 50
        for _ in 0..<4 {
            let skip = total > page ? Int.random(in: 0...(total - page)) : 0
            let batch = try await questions(difficulty: difficulty, tag: tag, skip: skip, limit: page, session: r.session)
            let usable = batch.items.filter { q in
                (r.includePaid || !q.isPaidOnly) && q.status != "ac" && !r.exclude.contains(q.titleSlug)
            }
            if let p = usable.compactMap(\.problem).randomElement() { return p }
            if total <= page { break }
        }
        return nil
    }

    // MARK: Daily challenge

    private struct DailyData: Decodable {
        struct Daily: Decodable { let question: RawQuestion }
        let activeDailyCodingChallengeQuestion: Daily
    }

    static func daily(session: String?) async throws -> LCProblem {
        let query = "query { activeDailyCodingChallengeQuestion { question { \(fields) } } }"
        let d = try await post(query, session: session, as: DailyData.self)
        guard let p = d.activeDailyCodingChallengeQuestion.question.problem else {
            throw LCError.graphQL("Couldn't read today's daily challenge.")
        }
        return p
    }

    // MARK: User

    private struct RecentData: Decodable {
        struct Sub: Decodable { let title: String; let titleSlug: String; let timestamp: String }
        let recentAcSubmissionList: [Sub]?
    }

    /// The user's latest accepted submissions; LeetCode returns at most 20.
    static func recentSolves(username: String) async throws -> [LCSolve] {
        let query = """
        query q($u: String!, $n: Int!) { recentAcSubmissionList(username: $u, limit: $n) { title titleSlug timestamp } }
        """
        let d = try await post(query, ["u": username, "n": 20], as: RecentData.self)
        return (d.recentAcSubmissionList ?? []).compactMap { s in
            guard let t = TimeInterval(s.timestamp) else { return nil }
            return LCSolve(slug: s.titleSlug, title: s.title, at: Date(timeIntervalSince1970: t))
        }
    }

    private struct StatsData: Decodable {
        struct User: Decodable {
            struct Global: Decodable {
                struct Count: Decodable { let difficulty: String; let count: Int }
                let acSubmissionNum: [Count]
            }
            let username: String
            let submitStatsGlobal: Global
        }
        let matchedUser: User?
    }

    static func stats(username: String) async throws -> LCUserStats {
        let query = """
        query q($u: String!) { matchedUser(username: $u) { username submitStatsGlobal { acSubmissionNum { difficulty count } } } }
        """
        let d = try await post(query, ["u": username], as: StatsData.self)
        guard let user = d.matchedUser else { throw LCError.graphQL("No LeetCode user \"\(username)\".") }
        let counts = Dictionary(user.submitStatsGlobal.acSubmissionNum.map { ($0.difficulty, $0.count) },
                                uniquingKeysWith: { a, _ in a })
        return LCUserStats(username: user.username, easy: counts["Easy"] ?? 0,
                           medium: counts["Medium"] ?? 0, hard: counts["Hard"] ?? 0)
    }
}

// MARK: - Topics

/// The topic chips the popover offers: LeetCode tag slugs and their display names. A slug typed
/// into the Topics preference that is not listed here still works.
enum Topics {
    static let all: [(slug: String, name: String)] = [
        ("array", "Array"), ("string", "String"), ("hash-table", "Hash Table"),
        ("two-pointers", "Two Pointers"), ("sliding-window", "Sliding Window"),
        ("binary-search", "Binary Search"), ("stack", "Stack"), ("linked-list", "Linked List"),
        ("tree", "Tree"), ("binary-tree", "Binary Tree"), ("depth-first-search", "DFS"),
        ("breadth-first-search", "BFS"), ("graph", "Graph"), ("heap-priority-queue", "Heap"),
        ("dynamic-programming", "DP"), ("greedy", "Greedy"), ("backtracking", "Backtracking"),
        ("bit-manipulation", "Bit Manipulation"), ("trie", "Trie"), ("union-find", "Union-Find"),
        ("math", "Math"), ("sorting", "Sorting"), ("matrix", "Matrix"), ("design", "Design"),
        ("topological-sort", "Topological Sort"), ("monotonic-stack", "Monotonic Stack"),
        ("prefix-sum", "Prefix Sum"), ("segment-tree", "Segment Tree"),
    ]

    static func name(_ slug: String) -> String {
        all.first { $0.slug == slug }?.name
            ?? slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
