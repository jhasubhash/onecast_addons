import AppKit
import SwiftUI
import OnecastPluginKit

// MARK: - Helpers

/// Coerce a JSON value (Double/Int/String/NSNumber) to Double.
private func asDouble(_ any: Any?) -> Double? {
    switch any {
    case let x as Double: return x
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

func fmt(_ v: Double) -> String { v.isFinite ? String(format: "%.2f", v) : "—" }

func compact(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    let a = abs(v)
    switch a {
    case 1e12...: return String(format: "%.2fT", v / 1e12)
    case 1e9...: return String(format: "%.2fB", v / 1e9)
    case 1e6...: return String(format: "%.2fM", v / 1e6)
    case 1e3...: return String(format: "%.1fK", v / 1e3)
    default: return String(format: "%.0f", v)
    }
}

// MARK: - Models

struct Quote: Sendable {
    var symbol: String
    var name: String
    var currency: String
    var price: Double
    var previousClose: Double
    var change: Double
    var percentChange: Double
    var open: Double
    var dayHigh: Double
    var dayLow: Double
    var week52High: Double
    var week52Low: Double
    var volume: Double
    var isMarketOpen: Bool
    var priceString: String { "\(fmt(price)) \(currency)" }
    var isPositive: Bool { change >= 0 }
}

struct Series: Sendable {
    var prices: [Double?] = []
    var timestamps: [Date] = []
    var tradingStart: Date?
    var tradingEnd: Date?
}

struct Bundle: Sendable {
    var quote: Quote
    var series: Series
}

struct Stats: Sendable {
    var marketCap: Double?
    var pe: Double?
    var dividend: Double?
}

struct MiniQuote: Sendable, Codable {
    var name: String
    var price: Double
    var change: Double
    var percent: Double
    var currency: String
    var isPositive: Bool { change >= 0 }
}

struct Instrument: Sendable, Identifiable, Hashable {
    var symbol: String
    var name: String
    var exchange: String?
    var type: String?
    var id: String { symbol }
}

struct YahooError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Range

enum StockRange: String, CaseIterable, Sendable {
    case d1 = "1D"
    case d5 = "5D"
    case m1 = "1M"
    case m6 = "6M"
    case ytd = "YTD"
    case y1 = "1Y"
    case y5 = "5Y"
    case max = "Max"

    var rangeParam: String {
        switch self {
        case .d1: return "1d"
        case .d5: return "5d"
        case .m1: return "1mo"
        case .m6: return "6mo"
        case .ytd: return "ytd"
        case .y1: return "1y"
        case .y5: return "5y"
        case .max: return "max"
        }
    }

    var intervalParam: String {
        switch self {
        case .d1: return "5m"
        case .d5: return "1h"
        case .m1: return "1d"
        case .m6: return "1d"
        case .ytd: return "1d"
        case .y1: return "1d"
        case .y5: return "1wk"
        case .max: return "1mo"
        }
    }
}

// MARK: - Yahoo networking (keyless v8 chart, like the BTT plugin)

enum Yahoo {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 12
        return r
    }

    /// Yahoo answers a burst with a 429 that clears in well under a second, so a single attempt
    /// leaves whichever symbols lost the race blank. Retries are what fill a watchlist.
    private static func fetch(_ url: URL, attempts: Int = 3) async -> Data? {
        for attempt in 0..<attempts {
            if attempt > 0 {
                let backoff = 200 << (attempt - 1) + Int.random(in: 0...120)
                try? await Task.sleep(for: .milliseconds(backoff))
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request(url))
            else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 || status >= 500 { continue }
            return status == 200 ? data : nil
        }
        return nil
    }

    private static func encodePath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private static func marketOpen(_ meta: [String: Any]) -> Bool {
        guard let reg = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any],
              let s = asDouble(reg["start"]), let e = asDouble(reg["end"]) else { return false }
        let now = Date().timeIntervalSince1970
        return now >= s && now < e
    }

    /// Quote + chart series for one symbol/range, from a single v8 chart call.
    static func bundle(_ symbol: String, _ range: StockRange) async throws -> Bundle {
        let url = URL(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/\(encodePath(symbol))"
            + "?interval=\(range.intervalParam)&range=\(range.rangeParam)")!
        guard let data = await fetch(url) else { throw YahooError(message: "No data for \(symbol)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any] else {
            throw YahooError(message: "Bad response from Yahoo")
        }
        guard let arr = chart["result"] as? [[String: Any]], let first = arr.first,
              let meta = first["meta"] as? [String: Any] else {
            let desc = (chart["error"] as? [String: Any])?["description"] as? String
            throw YahooError(message: desc ?? "No data for \(symbol)")
        }

        let price = asDouble(meta["regularMarketPrice"]) ?? 0
        let prev = asDouble(meta["previousClose"]) ?? asDouble(meta["chartPreviousClose"]) ?? price
        let name = (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol

        let indicators = first["indicators"] as? [String: Any]
        let q0 = (indicators?["quote"] as? [[String: Any]])?.first
        var prices: [Double?] = (q0?["close"] as? [Any])?.map { asDouble($0) } ?? []
        let opens: [Double] = (q0?["open"] as? [Any])?.compactMap { asDouble($0) } ?? []
        let ts: [Double] = (first["timestamp"] as? [Any])?.compactMap { asDouble($0) } ?? []

        var tStart: Date?
        var tEnd: Date?
        if let reg = (meta["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any] {
            if let s = asDouble(reg["start"]) { tStart = Date(timeIntervalSince1970: s) }
            if let e = asDouble(reg["end"]) { tEnd = Date(timeIntervalSince1970: e) }
        }

        // 1D: pad trailing nils so the x-axis spans the full trading day.
        if range == .d1, let s = tStart, let e = tEnd, e > s,
           !prices.isEmpty, ts.count == prices.count {
            let slot: TimeInterval = 5 * 60
            let total = max(prices.count,
                            Int(((e.timeIntervalSince1970 - s.timeIntervalSince1970) / slot).rounded(.up)))
            if total > prices.count {
                prices.append(contentsOf: Array<Double?>(repeating: nil, count: total - prices.count))
            }
        }

        let quote = Quote(
            symbol: symbol,
            name: name,
            currency: (meta["currency"] as? String) ?? "USD",
            price: price,
            previousClose: prev,
            change: price - prev,
            percentChange: prev != 0 ? (price - prev) / prev * 100 : 0,
            open: opens.first ?? .nan,
            dayHigh: asDouble(meta["regularMarketDayHigh"]) ?? .nan,
            dayLow: asDouble(meta["regularMarketDayLow"]) ?? .nan,
            week52High: asDouble(meta["fiftyTwoWeekHigh"]) ?? .nan,
            week52Low: asDouble(meta["fiftyTwoWeekLow"]) ?? .nan,
            volume: asDouble(meta["regularMarketVolume"]) ?? .nan,
            isMarketOpen: marketOpen(meta))
        let series = Series(
            prices: prices,
            timestamps: ts.map { Date(timeIntervalSince1970: $0) },
            tradingStart: range == .d1 ? tStart : nil,
            tradingEnd: range == .d1 ? tEnd : nil)
        return Bundle(quote: quote, series: series)
    }

    /// Lightweight quote for a watchlist row (one point).
    static func mini(_ symbol: String) async -> MiniQuote? {
        let url = URL(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/\(encodePath(symbol))?interval=1d&range=1d")!
        guard let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = (((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first)?["meta"] as? [String: Any],
              let price = asDouble(meta["regularMarketPrice"]) else { return nil }
        let prev = asDouble(meta["previousClose"]) ?? asDouble(meta["chartPreviousClose"]) ?? price
        return MiniQuote(
            name: (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol,
            price: price,
            change: price - prev,
            percent: prev != 0 ? (price - prev) / prev * 100 : 0,
            currency: (meta["currency"] as? String) ?? "USD")
    }

    /// Every watchlist quote in one crumb-gated call. A dozen separate chart requests is exactly the
    /// burst Yahoo answers with 429s, and each symbol that loses that race renders as a dash.
    static func minis(_ symbols: [String]) async -> [String: MiniQuote] {
        guard !symbols.isEmpty, let crumb = try? await Crumb.shared.get() else { return [:] }
        let list = symbols.map { encodePath($0) }.joined(separator: ",")
        let cenc = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? crumb
        let url = URL(string:
            "https://query1.finance.yahoo.com/v7/finance/quote?symbols=\(list)&crumb=\(cenc)")!
        guard let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (json["quoteResponse"] as? [String: Any])?["result"] as? [[String: Any]]
        else {
            await Crumb.shared.reset()
            return [:]
        }
        var out: [String: MiniQuote] = [:]
        for row in rows {
            guard let symbol = row["symbol"] as? String,
                  let price = asDouble(row["regularMarketPrice"]) else { continue }
            let prev = asDouble(row["regularMarketPreviousClose"]) ?? price
            out[symbol] = MiniQuote(
                name: (row["longName"] as? String) ?? (row["shortName"] as? String) ?? symbol,
                price: price,
                change: price - prev,
                percent: prev != 0 ? (price - prev) / prev * 100 : 0,
                currency: (row["currency"] as? String) ?? "USD")
        }
        return out
    }

    /// Symbol search.
    static func search(_ query: String) async throws -> [Instrument] {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string:
            "https://query2.finance.yahoo.com/v1/finance/search?q=\(enc)&quotesCount=15&newsCount=0")!
        let (data, _) = try await URLSession.shared.data(for: request(url))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotes = json["quotes"] as? [[String: Any]] else { return [] }
        let allowed: Set<String> = ["EQUITY", "ETF", "INDEX", "MUTUALFUND", "CRYPTOCURRENCY", "CURRENCY"]
        var seen = Set<String>()
        var out: [Instrument] = []
        for x in quotes {
            guard let sym = x["symbol"] as? String, !sym.isEmpty, !seen.contains(sym) else { continue }
            let type = x["quoteType"] as? String
            if let t = type, !allowed.contains(t) { continue }
            seen.insert(sym)
            out.append(Instrument(
                symbol: sym,
                name: (x["shortname"] as? String) ?? (x["longname"] as? String) ?? sym,
                exchange: x["exchDisp"] as? String,
                type: type))
        }
        return out
    }

    /// Market cap / P-E / dividend via the crumb-gated quoteSummary. Best-effort.
    static func stats(_ symbol: String) async -> Stats {
        do {
            let crumb = try await Crumb.shared.get()
            let cenc = crumb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? crumb
            let url = URL(string:
                "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(encodePath(symbol))"
                + "?modules=price,summaryDetail&crumb=\(cenc)")!
            let (data, _) = try await URLSession.shared.data(for: request(url))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = ((json["quoteSummary"] as? [String: Any])?["result"] as? [[String: Any]])?.first
            else { return Stats() }
            let price = r["price"] as? [String: Any]
            let sd = r["summaryDetail"] as? [String: Any]
            func raw(_ o: [String: Any]?, _ k: String) -> Double? {
                asDouble((o?[k] as? [String: Any])?["raw"])
            }
            return Stats(
                marketCap: raw(price, "marketCap"),
                pe: raw(sd, "trailingPE"),
                dividend: raw(sd, "dividendRate"))
        } catch {
            await Crumb.shared.reset()
            return Stats()
        }
    }
}

/// Caches Yahoo's cookie+crumb. URLSession.shared persists the cookie in the
/// shared HTTPCookieStorage, so the getcrumb call is authenticated automatically.
actor Crumb {
    static let shared = Crumb()
    private var value: String?

    func get() async throws -> String {
        if let value { return value }
        var r0 = URLRequest(url: URL(string: "https://fc.yahoo.com")!)
        r0.setValue(Yahoo.ua, forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: r0)
        var r1 = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v1/test/getcrumb")!)
        r1.setValue(Yahoo.ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: r1)
        let c = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.count < 40, !c.lowercased().contains("too many") else {
            throw YahooError(message: "no crumb")
        }
        value = c
        return c
    }

    func reset() { value = nil }
}

// MARK: - Store (favourites + recent, persisted)

@MainActor
final class StockStore: ObservableObject {
    @Published private(set) var favourites: [String]
    @Published private(set) var recent: [String]
    @Published private(set) var quotes: [String: MiniQuote] = [:]
    @Published private(set) var loadingList = false
    /// Bumped by the ⌘K "Refresh Quotes" command so an open chart reloads with the list.
    @Published private(set) var chartRefreshToken = UUID()

    private let favKey = "com.sujha.stockquotes.favourites"
    private let recentKey = "com.sujha.stockquotes.recent"
    private let quotesKey = "com.sujha.stockquotes.quotes"

    init() {
        favourites = UserDefaults.standard.stringArray(forKey: favKey) ?? []
        recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        // Last known prices, so a throttled refresh shows yesterday's number rather than a dash.
        if let data = UserDefaults.standard.data(forKey: quotesKey),
           let cached = try? JSONDecoder().decode([String: MiniQuote].self, from: data) {
            quotes = cached
        }
    }

    func isFavourite(_ s: String) -> Bool { favourites.contains(s) }

    func toggleFavourite(_ s: String) {
        if let i = favourites.firstIndex(of: s) { favourites.remove(at: i) }
        else { favourites.insert(s, at: 0) }
        UserDefaults.standard.set(favourites, forKey: favKey)
    }

    func pushRecent(_ s: String) {
        recent.removeAll { $0 == s }
        recent.insert(s, at: 0)
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    func removeRecent(_ s: String) {
        recent.removeAll { $0 == s }
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    func refreshQuotes() async {
        // Favourites first and in order: `Set` ordering under a tight cap left whichever symbols
        // fell outside it with no quote at all — that is what a dash on a favourite card was.
        var seen = Set<String>()
        let syms = (favourites + recent).filter { seen.insert($0).inserted }.prefix(40).map { $0 }
        guard !syms.isEmpty else { return }
        loadingList = true
        for (symbol, quote) in await Yahoo.minis(syms) { quotes[symbol] = quote }
        // Whatever the batch omitted — a symbol it does not carry, or a throttled call — retried two
        // at a time, which is slow but never the burst that earned the 429 in the first place.
        let missing = syms.filter { quotes[$0] == nil }
        if !missing.isEmpty {
            await withTaskGroup(of: (String, MiniQuote?).self) { group in
                var next = 0
                while next < min(2, missing.count) {
                    let symbol = missing[next]
                    group.addTask { (symbol, await Yahoo.mini(symbol)) }
                    next += 1
                }
                for await (symbol, quote) in group {
                    if let quote { quotes[symbol] = quote }
                    guard next < missing.count else { continue }
                    let following = missing[next]
                    group.addTask { (following, await Yahoo.mini(following)) }
                    next += 1
                }
            }
        }
        if let data = try? JSONEncoder().encode(quotes) {
            UserDefaults.standard.set(data, forKey: quotesKey)
        }
        loadingList = false
    }

    /// The ⌘K "Refresh Quotes" command: refresh the watchlist and signal any open chart to reload.
    func refreshAll() async {
        chartRefreshToken = UUID()
        await refreshQuotes()
    }
}

// MARK: - Sparkline (Canvas, from the BTT plugin)

struct SparklineView: View {
    let prices: [Double?]
    /// The one colour the card is drawn in — the chart never introduces a hue of its own, so the
    /// widget reads as a single accent against the host's greys.
    let tint: Color
    @State private var hoverIndex: Int? = nil

    private var validValues: [Double] { prices.compactMap { $0 } }
    private var firstValidIndex: Int? { prices.firstIndex(where: { $0 != nil }) }
    private var lastValidIndex: Int? { prices.lastIndex(where: { $0 != nil }) }

    private func makePoint(_ i: Int, width: CGFloat, height: CGFloat) -> CGPoint? {
        guard let v = prices[i] else { return nil }
        let vals = validValues
        guard let minP = vals.min(), let maxP = vals.max() else { return nil }
        let range = (maxP - minP) == 0 ? 1.0 : (maxP - minP)
        let n = prices.count
        let pad: CGFloat = 6
        let x = pad + (width - pad * 2) * CGFloat(i) / CGFloat(Swift.max(n - 1, 1))
        let y = (height - pad) - (height - pad * 2) * CGFloat((v - minP) / range)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let vals = validValues
                    guard vals.count >= 2,
                          let firstIdx = firstValidIndex,
                          let lastIdx = lastValidIndex else { return }
                    let minP = vals.min()!
                    let maxP = vals.max()!
                    let range = (maxP - minP) == 0 ? 1.0 : (maxP - minP)
                    let n = prices.count
                    let pad: CGFloat = 6
                    func point(_ i: Int) -> CGPoint? {
                        guard let v = prices[i] else { return nil }
                        let x = pad + (size.width - pad * 2) * CGFloat(i) / CGFloat(Swift.max(n - 1, 1))
                        let y = (size.height - pad) - (size.height - pad * 2) * CGFloat((v - minP) / range)
                        return CGPoint(x: x, y: y)
                    }
                    let validPts: [CGPoint] = (firstIdx...lastIdx).compactMap { point($0) }
                    guard validPts.count >= 2,
                          let firstPt = validPts.first,
                          let lastPt = validPts.last else { return }

                    func curve(through pts: [CGPoint], into path: inout Path) {
                        path.move(to: pts[0])
                        for i in 1..<pts.count {
                            let prev = pts[i - 1]
                            let curr = pts[i]
                            let cp1 = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                            let cp2 = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                            path.addCurve(to: curr, control1: cp1, control2: cp2)
                        }
                    }
                    var linePath = Path()
                    curve(through: validPts, into: &linePath)

                    var fillPath = Path()
                    fillPath.move(to: CGPoint(x: firstPt.x, y: size.height))
                    fillPath.addLine(to: firstPt)
                    for i in 1..<validPts.count {
                        let prev = validPts[i - 1]
                        let curr = validPts[i]
                        let cp1 = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                        let cp2 = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                        fillPath.addCurve(to: curr, control1: cp1, control2: cp2)
                    }
                    fillPath.addLine(to: CGPoint(x: lastPt.x, y: size.height))
                    fillPath.closeSubpath()

                    let g = Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)])
                    ctx.fill(fillPath, with: .linearGradient(
                        g,
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))
                    ctx.stroke(linePath, with: .color(tint),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    let outer = CGRect(x: lastPt.x - 6, y: lastPt.y - 6, width: 12, height: 12)
                    let inner = CGRect(x: lastPt.x - 3.5, y: lastPt.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: outer), with: .color(tint.opacity(0.25)))
                    ctx.fill(Path(ellipseIn: inner), with: .color(tint))

                    if let idx = hoverIndex, prices.indices.contains(idx), let pt = point(idx) {
                        var cross = Path()
                        cross.move(to: CGPoint(x: pt.x, y: 0))
                        cross.addLine(to: CGPoint(x: pt.x, y: size.height))
                        ctx.stroke(cross, with: .color(tint.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        let dOuter = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
                        let dInner = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                        ctx.fill(Path(ellipseIn: dOuter), with: .color(tint.opacity(0.3)))
                        ctx.fill(Path(ellipseIn: dInner), with: .color(tint))
                    }
                }

                if let idx = hoverIndex, prices.indices.contains(idx),
                   let v = prices[idx], let pt = makePoint(idx, width: w, height: h) {
                    let labelX = Swift.min(Swift.max(pt.x, 34), w - 34)
                    let labelY = Swift.max(pt.y - 22, 14)
                    Text(String(format: "%.2f", v))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(NSColor.windowBackgroundColor))
                                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1))
                        .fixedSize()
                        .position(x: labelX, y: labelY)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard prices.count >= 2,
                          let firstIdx = firstValidIndex,
                          let lastIdx = lastValidIndex else { break }
                    let pad: CGFloat = 6
                    let raw = (loc.x - pad) / (w - pad * 2) * CGFloat(prices.count - 1)
                    let clamped = Swift.max(firstIdx, Swift.min(lastIdx, Int(raw.rounded())))
                    hoverIndex = prices[clamped] != nil ? clamped : lastIdx
                case .ended:
                    hoverIndex = nil
                }
            }
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let labelSize: CGFloat
    let valueSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
                // A narrow window shrinks the label; a wrapped one knocks the value off its row.
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: valueSize, design: .rounded).weight(.semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail view (full-window card)

/// Reports the AppKit window hosting a SwiftUI view, so a plugin can scope a local event monitor to
/// its own window instead of the whole app.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// Where the detail card is being shown. The popped-out window is a desktop widget, read at a
/// glance, so it takes the compact single-accent scale; the same card inside the launcher keeps
/// the roomier, up/down-coloured one for fast scanning.
enum DetailStyle {
    case panel
    case widget
}

/// One card, two type scales. Every size the card sets comes from here, so the widget's scale
/// never has to be chased through the view for stray 30pt headlines.
struct CardMetrics {
    let ticker, name, price, delta, pill, statLabel, statValue: CGFloat
    let padding, headerSpacing, statSpacing: CGFloat

    static let panel = CardMetrics(ticker: 30, name: 13, price: 32, delta: 12, pill: 12,
                                   statLabel: 9, statValue: 15,
                                   padding: 20, headerSpacing: 14, statSpacing: 14)
    /// Sized to sit beside a Notification Center widget: nothing louder than the price.
    static let widget = CardMetrics(ticker: 19, name: 11, price: 24, delta: 11, pill: 11,
                                    statLabel: 8.5, statValue: 12.5,
                                    padding: 16, headerSpacing: 10, statSpacing: 12)
}

struct DetailView: View {
    let symbol: String
    let displayName: String
    /// Defaults to the launcher's card; the popped-out window asks for `.widget`.
    var style: DetailStyle = .panel
    @ObservedObject var store: StockStore

    @State private var range: StockRange = .d1
    @State private var quote: Quote?
    @State private var series = Series()
    @State private var stats: Stats?
    @State private var loading = true
    @State private var errorText: String?
    @State private var rangeShortcutMonitor: Any?
    @State private var hostWindow: NSWindow?

    private var validPrices: [Double] { series.prices.compactMap { $0 } }
    private var seriesUp: Bool {
        guard let f = validPrices.first, let l = validPrices.last else { return quote?.isPositive ?? true }
        return l >= f
    }
    private var metrics: CardMetrics { style == .widget ? .widget : .panel }
    private var isWidget: Bool { style == .widget }
    /// One colour for the whole card, and it is the chart's own: green while the range climbs,
    /// red while it falls. The change chip reads the same value, so the line, the number and the
    /// selected range can never disagree about which way the stock went.
    private var accent: Color {
        seriesUp ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, metrics.headerSpacing)
            rangePills.padding(.bottom, 8)
            chartArea
            Divider().padding(.vertical, 12)
            statsGrid
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowReader { hostWindow = $0 })
        .task(id: range) { await loadChart() }
        .task { await loadStats() }
        .task { await autoRefreshLoop() }
        .onChange(of: store.chartRefreshToken) { Task { await refreshChart() } }
        .onAppear { installRangeShortcuts() }
        .onDisappear { removeRangeShortcuts() }
    }

    /// ⌘1…⌘8 jump straight to a range — but only while this widget's own window is key, so the
    /// launcher (and any other surface) still receives ⌘-number when it is focused. A local monitor
    /// is process-wide, so without the window check it would swallow the keys from every window.
    private func installRangeShortcuts() {
        guard rangeShortcutMonitor == nil else { return }
        rangeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === hostWindow,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  let chars = event.charactersIgnoringModifiers, let digit = Int(chars),
                  StockRange.allCases.indices.contains(digit - 1)
            else { return event }
            range = StockRange.allCases[digit - 1]
            return nil
        }
    }

    private func removeRangeShortcuts() {
        if let monitor = rangeShortcutMonitor { NSEvent.removeMonitor(monitor) }
        rangeShortcutMonitor = nil
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol).font(.system(size: metrics.ticker, weight: .bold, design: .rounded))
                Text(quote?.name ?? displayName)
                    .font(.system(size: metrics.name)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(quote?.priceString ?? "…")
                    .font(.system(size: metrics.price, weight: .semibold, design: .rounded))
                    // A narrow window has to shrink the price, never break it onto a second line.
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let q = quote {
                    HStack(spacing: 3) {
                        Image(systemName: q.isPositive ? "arrow.up.right" : "arrow.down.left")
                            .font(.system(size: metrics.delta - 3, weight: .bold))
                        Text(String(format: "%+.2f  (%+.2f%%)", q.change, q.percentChange))
                            .font(.system(size: metrics.delta, weight: .semibold))
                    }
                    .foregroundColor(accent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(accent.opacity(0.13))
                    .clipShape(Capsule())
                }
            }
            // A desktop widget has nowhere to put a favourite, and the star only takes width the
            // widget does not have.
            if !isWidget {
                Button(action: { store.toggleFavourite(symbol) }) {
                    Image(systemName: store.isFavourite(symbol) ? "star.fill" : "star")
                        .font(.system(size: 17))
                        .foregroundColor(store.isFavourite(symbol) ? .yellow : .secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.isFavourite(symbol) ? "Unstar" : "Star")
            }
        }
    }

    /// One row, never two: at widget width a pill allowed to wrap breaks "YTD" into "YT D". There
    /// each range takes an equal column and shrinks instead — the way the Calendar widget's weekday
    /// row divides its width — while the launcher keeps its roomy left-packed row.
    private var rangePills: some View {
        HStack(spacing: isWidget ? 0 : 2) {
            ForEach(StockRange.allCases, id: \.self) { r in
                Button(action: { range = r }) {
                    Text(r.rawValue)
                        .font(.system(size: metrics.pill, weight: range == r ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundColor(range == r ? accent : .secondary)
                        .padding(.horizontal, isWidget ? 4 : 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(range == r ? accent.opacity(0.14) : .clear))
                        .frame(maxWidth: isWidget ? .infinity : nil)
                }
                .buttonStyle(.plain)
            }
            if !isWidget { Spacer() }
        }
    }

    private var chartArea: some View {
        ZStack {
            if let err = errorText {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary)
                    Text(err).font(.system(size: 12)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if validPrices.count >= 2 {
                SparklineView(prices: series.prices, tint: accent)
                    .opacity(loading ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: loading)
            } else if loading {
                ProgressView().scaleEffect(0.9)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").foregroundColor(.secondary)
                    Text("No chart data for this range")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statsGrid: some View {
        VStack(spacing: metrics.statSpacing) {
            HStack(spacing: 0) {
                StatTile(label: "Open", value: fmt(quote?.open ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "High", value: fmt(quote?.dayHigh ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "Low", value: fmt(quote?.dayLow ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "Prev Close", value: fmt(quote?.previousClose ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
            }
            HStack(spacing: 0) {
                StatTile(label: "Mkt Cap", value: compact(stats?.marketCap),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "P/E", value: stats?.pe.map { String(format: "%.2f", $0) } ?? "—",
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "52W High", value: fmt(quote?.week52High ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
                StatTile(label: "52W Low", value: fmt(quote?.week52Low ?? .nan),
                         labelSize: metrics.statLabel, valueSize: metrics.statValue)
            }
        }
    }

    private func loadChart() async {
        loading = true
        errorText = nil
        await fetchChart(silent: false)
        loading = false
    }

    /// A background reload — the auto-refresh timer and the ⌘K Refresh command — that never flashes
    /// the spinner or replaces a good chart with a transient error.
    private func refreshChart() async {
        await fetchChart(silent: true)
    }

    private func fetchChart(silent: Bool) async {
        let requested = range
        do {
            let b = try await Yahoo.bundle(symbol, requested)
            // A range change mid-flight wins: don't let a stale fetch overwrite the newer one.
            guard requested == range else { return }
            quote = b.quote
            series = b.series
            errorText = nil
        } catch {
            if !silent, requested == range {
                errorText = (error as? YahooError)?.message ?? error.localizedDescription
            }
        }
    }

    /// While the detail is on screen, poll for fresh data — fast when the market is live, slower
    /// off-hours but still often enough to fill an empty chart on its own once it opens.
    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            let interval: Duration = quote?.isMarketOpen == true ? .seconds(30) : .seconds(120)
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await refreshChart()
        }
    }

    private func loadStats() async {
        stats = await Yahoo.stats(symbol)
    }
}

// MARK: - Root (search + watchlist)

struct WatchRow: View {
    let symbol: String
    let name: String
    let mini: MiniQuote?
    let starred: Bool
    var selected: Bool = false
    var onOpen: () -> Void
    var onStar: () -> Void
    var onRemove: (() -> Void)?

    @State private var hovered = false

    private var accent: Color {
        guard let m = mini else { return .secondary }
        return m.isPositive ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onStar) {
                Image(systemName: starred ? "star.fill" : "star")
                    .foregroundColor(starred ? .yellow : .secondary.opacity(0.6))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(mini?.name ?? name).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let m = mini {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(fmt(m.price)).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(String(format: "%+.2f%%", m.percent))
                        .font(.system(size: 11, weight: .medium)).foregroundColor(accent)
                }
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(width: 20, height: 20).opacity(hovered ? 1 : 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        // The keyboard's row has to read at a glance next to a hovered one, so it takes the accent
        // wash and a leading bar; hover stays a faint grey that cannot be mistaken for it.
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                if selected {
                    Color.accentColor.opacity(0.22)
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                } else if hovered {
                    Color.primary.opacity(0.06)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
    }
}

struct FavCard: View {
    let symbol: String
    let mini: MiniQuote?
    var selected: Bool = false
    var onOpen: () -> Void
    var onUnstar: () -> Void
    @State private var hovered = false

    private var accent: Color {
        guard let m = mini else { return .secondary }
        return m.isPositive ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(symbol).font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onUnstar) {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundColor(.yellow)
                }
                .buttonStyle(.plain).opacity(hovered ? 1 : 0.75)
            }
            Text(mini?.name ?? symbol)
                .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mini.map { fmt($0.price) } ?? "—")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                if let m = mini {
                    Text(String(format: "%+.2f%%", m.percent))
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(accent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.14 : (hovered ? 0.09 : 0.05))))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Color.accentColor : accent.opacity(0.22), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
    }
}

/// The whole plugin body: a persistent live-search bar with an inline detail
/// view and a modern watchlist (favourite cards + recent). No screen stack —
/// the search bar is the single navigation surface, so there is no duplicate
/// back chevron and switching stocks never needs a round-trip through a list.
struct StocksApp: View {
    @ObservedObject var store: StockStore
    /// A saved deep link handed in at launch, e.g. `["view":"detail","symbol":"ADBE"]`; nil normally.
    var initialRoute: [String: String]?

    @State private var nav = PluginNavigator()
    @State private var query = ""
    @State private var results: [Instrument] = []
    @State private var searching = false
    @State private var openSymbol: String?
    @State private var openName: String?
    @State private var selection = 0
    /// The favourite column to come back to when ↑ steps up out of the recent list.
    @State private var lastFav = 0
    @FocusState private var searchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// One thing a stock row can be, whichever section it sits in.
    private struct Ref: Hashable { let symbol: String; let name: String }

    private var favRefs: [Ref] { store.favourites.map { Ref(symbol: $0, name: store.quotes[$0]?.name ?? $0) } }
    private var recentRefs: [Ref] { store.recent.map { Ref(symbol: $0, name: store.quotes[$0]?.name ?? $0) } }

    /// The flat, ordered list the selection indexes — search hits while searching, else the watchlist.
    private var navItems: [Ref] {
        trimmed.isEmpty
            ? favRefs + recentRefs
            : results.map { Ref(symbol: $0.symbol, name: $0.name) }
    }

    private var selIndex: Int {
        navItems.isEmpty ? 0 : min(max(selection, 0), navItems.count - 1)
    }

    var body: some View {
        // Return opens the highlighted row, so the footer only advertises it while a
        // list is on screen. On the pushed chart there is nothing to open and Return
        // is inert (`handleListKey` bails on `nav.canPop`), so the hint is hidden.
        PluginScaffold(
            navigator: nav, primaryActionLabel: (nav.canPop || navItems.isEmpty) ? "" : "Open",
            commands: currentCommands, commandTitle: { currentSymbol }, listKey: handleListKey,
            escape: handleEscape, route: currentRoute
        ) {
            rootView
        }
    }

    private var rootView: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // A saved deep link opens straight to that stock's chart; otherwise focus the search.
            if initialRoute?["view"] == "detail", let symbol = initialRoute?["symbol"] {
                open(Ref(symbol: symbol, name: symbol))
            } else {
                // A hop so the palette panel is key before we ask for focus; setting it on bare
                // appear lands before the field is in the responder chain and silently no-ops.
                try? await Task.sleep(nanoseconds: 120_000_000)
                searchFocused = true
            }
            await store.refreshQuotes()
        }
        .task(id: query) { await runSearch() }
        .onChange(of: query) { selection = 0 }
        .onChange(of: results) { selection = 0 }
        // Back from a chart lands on the list again, so the field is ready to type at once.
        .onChange(of: nav.canPop) { _, canPop in if !canPop { searchFocused = true } }
    }

    /// Search hits are a plain vertical list; the watchlist is a horizontal favourites row above a
    /// vertical recent list, so ←/→ walk favourites, ↓ drops into recent and ↑ climbs back up.
    private func handleListKey(_ key: PluginListKey) -> Bool {
        guard !nav.canPop else { return false }

        if !trimmed.isEmpty {
            guard !results.isEmpty else { return false }
            switch key {
            case .down: selection = min(selIndex + 1, results.count - 1)
            case .up: selection = max(selIndex - 1, 0)
            case .submit: open(navItems[selIndex])
            case .left, .right: return false   // leave the caret to the search field
            }
            return true
        }

        let favs = favRefs.count
        let total = favs + recentRefs.count
        guard total > 0 else { return false }
        let inFavourites = selIndex < favs
        switch key {
        case .left:
            guard inFavourites else { return false }
            selection = max(selIndex - 1, 0)
        case .right:
            guard inFavourites else { return false }
            selection = min(selIndex + 1, favs - 1)
        case .down:
            selection = inFavourites ? (recentRefs.isEmpty ? selIndex : favs) : min(selIndex + 1, total - 1)
        case .up:
            if !inFavourites {
                selection = selIndex == favs ? min(lastFav, max(favs - 1, 0)) : selIndex - 1
            }
        case .submit:
            open(navItems[selIndex])
        }
        if selIndex < favs { lastFav = selIndex }
        return true
    }

    /// Escape unwinds the surface a step at a time: a live search clears back to the watchlist
    /// before a further press leaves the plugin, so one key never skips a whole view.
    private func handleEscape() -> Bool {
        guard !nav.canPop, !trimmed.isEmpty else { return false }
        query = ""
        selection = 0
        searchFocused = true
        return true
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundColor(.secondary)
            TextField("Search any stock — Apple, TSLA, BTC-USD…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 18))
                .focused($searchFocused)
            // Fixed slots so the spinner and clear button never change the bar's height or jog it.
            ZStack { if searching { ProgressView().controlSize(.small) } }.frame(width: 18)
            Button { query = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .opacity(trimmed.isEmpty ? 0 : 1)
            .disabled(trimmed.isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder private var content: some View {
        if !trimmed.isEmpty { searchResults } else { watchlist }
    }

    private var searchResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty && !searching {
                        hint("No matches for “\(trimmed)”.")
                    } else {
                        // Keyed by position, matching the `.id` the scroller seeks and the index the
                        // selection counts: a symbol-keyed `ForEach` fights that explicit id, and a
                        // re-search then leaves the old rows on screen while selection walks the new
                        // array — the list looks frozen and the highlight lands on nothing.
                        ForEach(Array(results.enumerated()), id: \.offset) { index, inst in
                            WatchRow(symbol: inst.symbol, name: inst.name,
                                     mini: store.quotes[inst.symbol],
                                     starred: store.isFavourite(inst.symbol),
                                     selected: index == selIndex,
                                     onOpen: { open(Ref(symbol: inst.symbol, name: inst.name)) },
                                     onStar: { store.toggleFavourite(inst.symbol) },
                                     onRemove: nil)
                                .id(index)
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            .contentMargins(.bottom, 52, for: .scrollContent)
            .onChange(of: selection) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selIndex, anchor: .center) } }
        }
    }

    private var watchlist: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !favRefs.isEmpty {
                        sectionHeader("Favourites", systemImage: "star.fill")
                        // Eager, not LazyVGrid: reused lazy cells lag the ring by a keystroke.
                        ScrollViewReader { favProxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(Array(favRefs.enumerated()), id: \.offset) { index, ref in
                                        FavCard(symbol: ref.symbol, mini: store.quotes[ref.symbol],
                                                selected: index == selIndex,
                                                onOpen: { open(ref) },
                                                onUnstar: { store.toggleFavourite(ref.symbol) })
                                            .frame(width: 160)
                                            .id(index)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .onChange(of: selection) {
                                guard selIndex < favRefs.count else { return }
                                withAnimation(.easeOut(duration: 0.12)) { favProxy.scrollTo(selIndex, anchor: .center) }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    if !recentRefs.isEmpty {
                        sectionHeader("Recent", systemImage: "clock")
                        ForEach(Array(recentRefs.enumerated()), id: \.offset) { index, ref in
                            WatchRow(symbol: ref.symbol, name: ref.name,
                                     mini: store.quotes[ref.symbol],
                                     starred: store.isFavourite(ref.symbol),
                                     selected: favRefs.count + index == selIndex,
                                     onOpen: { open(ref) },
                                     onStar: { store.toggleFavourite(ref.symbol) },
                                     onRemove: { store.removeRecent(ref.symbol) })
                                .id(favRefs.count + index)
                            Divider().opacity(0.35)
                        }
                    }
                    if favRefs.isEmpty && recentRefs.isEmpty {
                        hint("Search a company or ticker to view its chart. Tap ★ to save a favourite.")
                    }
                }
                .padding(.top, 4)
            }
            .contentMargins(.bottom, 52, for: .scrollContent)
            // Ids below `favRefs.count` sit in the horizontal strip, which its own reader centres;
            // chasing them here drags the page up to centre a card that never moved vertically.
            .onChange(of: selection) {
                guard selIndex >= favRefs.count else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selIndex, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(40)
    }

    private func open(_ ref: Ref) {
        searchFocused = false
        store.pushRecent(ref.symbol)
        openSymbol = ref.symbol
        openName = ref.name
        nav.push(title: ref.symbol) { DetailView(symbol: ref.symbol, displayName: ref.name, store: store) }
    }

    /// The stock the ⌘K palette acts on: the shown one (detail) or the highlighted row.
    private var currentSymbol: String? {
        if nav.canPop { return openSymbol }
        let items = navItems
        return items.indices.contains(selIndex) ? items[selIndex].symbol : nil
    }

    /// The route the ⌘K "Add to Main Menu" command pins: the open stock's chart, else nothing.
    private func currentRoute() -> PluginRoute? {
        guard nav.canPop, let symbol = openSymbol else { return nil }
        return PluginRoute(
            payload: ["view": "detail", "symbol": symbol],
            title: openName.map { "\(symbol) — \($0)" } ?? symbol,
            subtitle: symbol,
            icon: .symbol("chart.line.uptrend.xyaxis"))
    }

    /// The ⌘K rows for whatever view is on top; the palette heads them with `currentSymbol`.
    private func currentCommands() -> [PluginCommand] {
        var commands: [PluginCommand] = []
        if let symbol = currentSymbol {
            let favourite = store.isFavourite(symbol)
            commands.append(PluginCommand(
                title: favourite ? "Remove from Favourites" : "Add to Favourites",
                icon: .symbol(favourite ? "star.slash" : "star"),
                action: { store.toggleFavourite(symbol) }))
            // The scaffold swaps this for Add/Remove-from-Main-Menu on a detail view, drops it here.
            commands.append(.mainMenuSlot())
            if let url = URL(string: "https://finance.yahoo.com/quote/\(symbol)") {
                commands.append(PluginCommand(
                    title: "Open in Yahoo Finance", icon: .symbol("safari"),
                    action: { NSWorkspace.shared.open(url) }))
            }
        }
        commands.append(PluginCommand(
            title: "Refresh Quotes", icon: .symbol("arrow.clockwise"),
            action: { Task { await store.refreshAll() } }))
        return commands
    }

    private func runSearch() async {
        let q = trimmed
        guard !q.isEmpty else { results = []; searching = false; return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if Task.isCancelled { return }
        searching = true
        results = (try? await Yahoo.search(q)) ?? []
        searching = false
    }
}

// MARK: - Plugin entry

final class StockQuotesPlugin: NSObject, OnecastPlugin {
    static let metadata = PluginMetadata(
        name: "Stock Quotes",
        subtitle: "Live prices, charts & watchlist",
        icon: "chart.line.uptrend.xyaxis")

    private let store = StockStore()

    override init() { super.init() }

    // The whole plugin is one SwiftUI surface: a watchlist, a live search and inline charts, all
    // keyboard-driven. No root row list — the launcher row opens straight into it.
    func rootSurface(context: PluginContext) -> AnyView? {
        // Popped out into its own window: show only the chart, no scaffold or footer, in the
        // compact single-accent scale that sits beside a Notification Center widget.
        if context.presentation == .window,
            context.route?["view"] == "detail", let symbol = context.route?["symbol"] {
            let name = store.quotes[symbol]?.name ?? symbol
            return AnyView(DetailView(symbol: symbol, displayName: name, style: .widget, store: store))
        }
        return AnyView(StocksApp(store: store, initialRoute: context.route))
    }
}

@_cdecl("onecastPluginCreate")
public func onecastPluginCreate() -> UnsafeMutableRawPointer {
    OnecastPluginRuntime.export { StockQuotesPlugin() }
}
