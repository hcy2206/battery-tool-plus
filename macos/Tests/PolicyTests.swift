import Foundation

@main struct Tests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            count += 1
            if !condition() { fatalError("FAIL: \(name)") }
        }
        var settings = Settings()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var reading = Reading(percent: 60, health: 95, plugged: true, charging: true, cycles: 10)
        var plan = Plan(start: now.addingTimeInterval(-3600), deadline: now.addingTimeInterval(3600), goal: .desk)
        func decide(_ mode: Mode = .timed, at: Date? = nil, charging: Bool = true,
                    idle: Double = 600, thermal: Int = 0, paused: Bool = false, reserve: Double = 7200,
                    stalled: Bool = false) -> Decision {
            Policy.decide(mode: mode, plan: plan, settings: settings, reading: reading,
                          now: at ?? now, charging: charging, idle: idle, thermal: thermal, reserve: reserve,
                          paused: paused, stalled: stalled)
        }
        check(decide().load == 1, "load while charging")
        check(!decide(.daily, stalled: true).charging && !decide(stalled: true).charging, "stalled charge becomes the top of the cycle")
        check(decide(.ready, stalled: true).charging, "ready mode ignores stall")
        check(decide(charging: false).load == 1, "load while discharging")
        check(decide(.daily).load == 0, "daily no load")
        check(decide(.ready).charging && decide(.ready).load == 0, "ready restores charge")
        check(decide(idle: 1).load == 0, "user returns")
        check(decide(idle: 400).load == 1, "idle resumes")
        check(decide(thermal: 1).load == 0.5, "fair thermal halves load")
        check(decide(thermal: 2).load == 0 && decide(thermal: 2).charging, "serious thermal pause")
        check(decide(thermal: 3).load == 0, "critical thermal pause")
        check(decide(paused: true).load == 0, "manual pause")
        check(decide(at: plan.deadline).mode == .daily && decide(at: plan.deadline).load == 0, "desk deadline")
        check(decide(at: now.addingTimeInterval(-7200)).load == 0, "future start")
        plan.goal = .departure
        check(decide().mode == .ready, "departure reserves charge time")
        check(decide(reserve: 1800).mode == .timed, "departure before reserve")
        check(decide(at: plan.deadline).mode == .ready, "departure deadline")
        plan.goal = .desk
        reading.percent = settings.minimum
        check(decide(charging: false).charging, "inclusive lower threshold")
        check(decide(charging: true, stalled: true).charging, "stall never discharges below the minimum")
        reading.percent = settings.maximum
        check(!decide().charging, "inclusive upper threshold")
        reading.percent = 3
        check(decide().mode == .ready, "low battery ends task")
        reading.percent = 60; reading.plugged = false
        check(decide().mode == .system && decide().load == 0, "unplug ends task")
        reading.plugged = true; reading.health = 79
        check(decide().mode == .ready, "health target")
        reading.health = 95; reading.percent = -1
        check(decide().mode == .system, "invalid data")
        settings.pauseOnActivity = false; reading.percent = 60
        check(decide(idle: 0).load == 1, "explicit keep loading")
        settings.minimum = settings.maximum
        do { try settings.validate(); fatalError("invalid thresholds accepted") } catch { count += 1 }
        settings = Settings()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 2))!
        let fallback = Predictor.recommend(now: morning, settings: settings, samples: [], calendar: calendar)
        check(fallback.start == morning, "overnight fallback starts now")
        check(calendar.component(.hour, from: fallback.end) == 8, "overnight end")
        let windowEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
        let wrapped = Predictor.recommend(now: windowEnd, settings: settings, samples: [], calendar: calendar)
        check(wrapped.end.timeIntervalSince(windowEnd) <= Predictor.maximumWindow && wrapped.start < wrapped.end,
              "recommendation stays inside the 24 h plan limit")
        var samples = [Observation]()
        for day in [12, 13, 14, 15, 16] {
            for minute in stride(from: 0, to: 120, by: 15) {
                let time = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 20, minute: minute))!
                samples.append(Observation(time: time, idle: true, percent: 50, charging: false, load: false))
            }
        }
        let predicted = Predictor.recommend(now: morning, settings: settings, samples: samples, calendar: calendar)
        check(calendar.component(.hour, from: predicted.start) == 20, "learned evening window")
        check(calendar.component(.hour, from: predicted.end) == 21 && calendar.component(.minute, from: predicted.end) == 45, "early finish buffer")
        let oneDay = samples.filter { calendar.component(.day, from: $0.time) == 12 }
        check(Predictor.recommend(now: morning, settings: settings, samples: oneDay, calendar: calendar).reason.contains("不足"), "one day insufficient")
        let reserve = Predictor.chargeReserve(samples: [], percent: 50, target: 100, fallback: 120)
        check(reserve.0 == 7200, "manual fallback reserve")
        var chargingSamples = [Observation]()
        for i in 0..<30 {
            chargingSamples.append(Observation(time: now.addingTimeInterval(Double(i) * 30), idle: true,
                                                percent: 50 + Double(i) * 0.3, charging: true, load: false))
        }
        check(Predictor.chargeReserve(samples: chargingSamples, percent: 60, target: 100, fallback: 120).0 != 7200, "learn charge estimate")
        let loaded = chargingSamples.map { Observation(time: $0.time, idle: $0.idle, percent: $0.percent, charging: true, load: true) }
        check(Predictor.chargeReserve(samples: loaded, percent: 60, target: 100, fallback: 120).0 == 7200, "exclude charging under load")
        let plateau = (0..<41).map { index in
            Observation(time: now.addingTimeInterval(Double(index) * 30), idle: true,
                        percent: index < 30 ? 50 : 51, charging: true, load: false)
        }
        let slowEstimate = Predictor.chargeReserve(samples: plateau, percent: 90, target: 100, fallback: 120)
        check(slowEstimate.0 > 7200, "plateau time included in charge estimate")
        let gaps = chargingSamples.enumerated().map { index, sample in
            Observation(time: sample.time.addingTimeInterval(Double(index) * 120), idle: true,
                        percent: sample.percent, charging: true, load: false)
        }
        check(Predictor.chargeReserve(samples: gaps, percent: 60, target: 100, fallback: 120).0 == 7200, "unknown gaps excluded")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let history = try History(directory: temporary)
        try history.add(chargingSamples[0]); try history.event("user's event", at: now)
        check(history.samples(since: now.addingTimeInterval(-1)).count == 1, "SQLite sample roundtrip")
        check(history.events().first?.contains("user's event") == true, "SQLite event escaping")
        try history.clear()
        check(history.events().isEmpty && history.samples(since: .distantPast).isEmpty, "clear history")
        print("\(count) native policy/history checks passed")
    }
}
