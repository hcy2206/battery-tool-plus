import Foundation

struct Observation {
    var time: Date
    var idle: Bool
    var percent: Double
    var charging: Bool
    var load: Bool
}
struct Recommendation {
    var start: Date
    var end: Date
    var reason: String
}

final class History {
    private var db: OpaquePointer?
    private var lastPrune = Date.distantPast
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else {
            throw AppError.message("无法打开历史数据库")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS samples (time REAL, idle INTEGER, percent REAL, charging INTEGER, load INTEGER)")
        try execute("CREATE INDEX IF NOT EXISTS sample_time ON samples(time)")
        try execute("CREATE TABLE IF NOT EXISTS events (time REAL, message TEXT)")
        try prune()
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.message("历史数据库写入失败") }
    }
    private func insert(_ sql: String, _ values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AppError.message("历史数据库写入失败") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            switch value {
            case let number as Double: sqlite3_bind_double(statement, column, number)
            case let flag as Bool: sqlite3_bind_int(statement, column, flag ? 1 : 0)
            case let text as String:
                sqlite3_bind_text(statement, column, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: throw AppError.message("历史数据库写入失败")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message("历史数据库写入失败") }
    }
    private func prune() throws {
        let now = Date()
        guard now.timeIntervalSince(lastPrune) >= 3600 else { return }
        let cutoff = now.addingTimeInterval(-90*86400).timeIntervalSince1970
        try insert("DELETE FROM samples WHERE time < ?", [cutoff])
        try insert("DELETE FROM events WHERE time < ?", [cutoff])
        lastPrune = now
    }
    func add(_ sample: Observation) throws {
        try prune()
        try insert("INSERT INTO samples VALUES (?, ?, ?, ?, ?)",
                   [sample.time.timeIntervalSince1970, sample.idle, sample.percent, sample.charging, sample.load])
    }
    func event(_ text: String, at date: Date = Date()) throws {
        try prune()
        try insert("INSERT INTO events VALUES (?, ?)", [date.timeIntervalSince1970, text])
    }
    func events() -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT time, message FROM events ORDER BY time DESC LIMIT 100", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let text = String(cString: sqlite3_column_text(statement, 1))
            result.append("\(date.formatted(date: .abbreviated, time: .shortened))  \(text)")
        }
        return result
    }
    func samples(since: Date) -> [Observation] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM samples WHERE time >= ? ORDER BY time", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var result = [Observation]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Observation(time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                      idle: sqlite3_column_int(statement, 1) != 0,
                                      percent: sqlite3_column_double(statement, 2),
                                      charging: sqlite3_column_int(statement, 3) != 0,
                                      load: sqlite3_column_int(statement, 4) != 0))
        }
        return result
    }
    func clear() throws { try execute("DELETE FROM samples; DELETE FROM events; VACUUM;") }
}

struct Predictor {
    /// Timed plans must end within 24 hours; keep every recommendation inside that limit
    /// with a margin for the time between showing it and the user confirming.
    static let maximumWindow: TimeInterval = 24*3600 - 15*60
    static func recommend(now: Date, settings: Settings, samples: [Observation], calendar: Calendar = .current) -> Recommendation {
        let suggestion = learnedOrFallback(now: now, settings: settings, samples: samples, calendar: calendar)
        let end = min(suggestion.end, now.addingTimeInterval(maximumWindow))
        return Recommendation(start: min(suggestion.start, end), end: end, reason: suggestion.reason)
    }
    private static func learnedOrFallback(now: Date, settings: Settings, samples: [Observation], calendar: Calendar) -> Recommendation {
        // Each slot/day is one vote, preventing long or frequently sampled sessions dominating.
        var votes: [Int: [Date: (Double, Double)]] = [:]
        let weekend = calendar.isDateInWeekend(now)
        for sample in samples where sample.time < now && sample.time > now.addingTimeInterval(-28*86400) {
            guard calendar.isDateInWeekend(sample.time) == weekend else { continue }
            let slot = calendar.component(.hour, from: sample.time) * 4 + calendar.component(.minute, from: sample.time) / 15
            let day = calendar.startOfDay(for: sample.time)
            let old = votes[slot]?[day] ?? (0, 0)
            votes[slot, default: [:]][day] = (old.0 + (sample.idle ? 1 : 0), old.1 + 1)
        }
        var good = Set<Int>()
        for (slot, days) in votes where days.count >= 3 {
            var idle = 0.0, total = 0.0
            for (day, count) in days {
                let weight = exp(-now.timeIntervalSince(day) / (14*86400))
                idle += weight * count.0 / count.1
                total += weight
            }
            if total > 0 && idle / total >= 0.8 { good.insert(slot) }
        }
        let floor = calendar.date(bySetting: .second, value: 0, of: now)!
        let first = floor.addingTimeInterval(Double(15 - calendar.component(.minute, from: floor) % 15) * 60)
        var best: (Date, Date)?
        var start: Date?
        for index in 0...96 {
            let date = first.addingTimeInterval(Double(index) * 900)
            let slot = calendar.component(.hour, from: date) * 4 + calendar.component(.minute, from: date) / 15
            if index < 96 && good.contains(slot) && calendar.isDateInWeekend(date) == weekend {
                if start == nil { start = date }
            } else if let began = start {
                if date.timeIntervalSince(began) >= 3600 && (best == nil || date.timeIntervalSince(began) > best!.1.timeIntervalSince(best!.0)) {
                    best = (began, date)
                }
                start = nil
            }
        }
        if let best {
            return Recommendation(start: best.0, end: best.1.addingTimeInterval(-900),
                                  reason: "近 28 天同类日期：各时段至少 3 天记录，空闲比例 ≥80%；提前 15 分钟收尾。")
        }
        let today = calendar.startOfDay(for: now)
        var begin = calendar.date(byAdding: .hour, value: settings.idleStartHour, to: today)!
        var end = calendar.date(byAdding: .hour, value: settings.idleEndHour, to: today)!
        if end <= begin { end = calendar.date(byAdding: .day, value: 1, to: end)! }
        // In the morning of an overnight window, use the currently active window.
        if settings.idleEndHour < settings.idleStartHour && calendar.component(.hour, from: now) < settings.idleEndHour {
            begin = calendar.date(byAdding: .day, value: -1, to: begin)!
            end = calendar.date(byAdding: .day, value: -1, to: end)!
        }
        if end <= now {
            begin = calendar.date(byAdding: .day, value: 1, to: begin)!
            end = calendar.date(byAdding: .day, value: 1, to: end)!
        }
        return Recommendation(start: max(now, begin), end: end, reason: "历史记录不足，使用你设置的初始空闲时段。")
    }
    static func chargeReserve(samples: [Observation], percent: Double, target: Double, fallback: Double) -> (Double, String) {
        var rates = [Double]()
        var beginning: Observation?
        var previous: Observation?
        func finishSegment() {
            if let beginning, let previous {
                let elapsed = previous.time.timeIntervalSince(beginning.time)
                let gain = previous.percent - beginning.percent
                // Include zero-gain samples; ignoring them overestimates charging speed.
                if elapsed >= 600, gain >= 0.5, gain / elapsed < 0.1 { rates.append(gain / elapsed) }
            }
        }
        for sample in samples {
            if !sample.charging || sample.load {
                finishSegment(); beginning = nil; previous = nil; continue
            }
            if let previous, sample.time.timeIntervalSince(previous.time) > 90 || sample.time <= previous.time {
                finishSegment(); beginning = nil
            }
            if beginning == nil { beginning = sample }
            previous = sample
        }
        finishSegment()
        guard percent < target else { return (0, "当前已达到目标电量；接近截止时将结束循环并保持充电") }
        guard !rates.isEmpty else { return (fallback * 60, "充电样本不足，使用手动预留时间") }
        rates.sort()
        let conservativeRate = rates[rates.count / 4]
        let estimate = min(12*3600, max(15*60, (target - percent) / conservativeRate * 1.3 + 900))
        return (estimate, "依据无负载充电记录估算，含余量；末段充电速度可能变化")
    }
}
