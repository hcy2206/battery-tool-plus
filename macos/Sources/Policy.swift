import Foundation

enum Mode: String, Codable, CaseIterable {
    case system, ready, daily, timed
    var title: String {
        switch self {
        case .system: return "系统管理"
        case .ready: return "准备外出"
        case .daily: return "日常循环"
        case .timed: return "定时压测"
        }
    }
}
enum DeadlineGoal: String, Codable, CaseIterable {
    case desk, departure
    var title: String { self == .desk ? "到点开始使用电脑" : "到点携带电脑离开" }
}
struct Settings: Codable {
    var minimum = 20.0
    var maximum = 90.0
    var targetHealth = 79.0
    var cpu = 50.0
    var gpu = 50.0
    var threads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    var pauseOnActivity = true
    var idleSeconds = 300.0
    var chargeReserveMinutes = 120.0
    var departureCharge = 100.0
    var idleStartHour = 23
    var idleEndHour = 8
    var recordHistory = false
    func validate() throws {
        guard minimum.isFinite, maximum.isFinite, 1 <= minimum, minimum < maximum, maximum <= 100,
              targetHealth.isFinite, (0...100).contains(targetHealth),
              cpu.isFinite, gpu.isFinite, (0...100).contains(cpu), (0...100).contains(gpu),
              (1...ProcessInfo.processInfo.activeProcessorCount).contains(threads),
              idleSeconds.isFinite, idleSeconds >= 30, idleSeconds <= 3600,
              chargeReserveMinutes.isFinite, (15...720).contains(chargeReserveMinutes),
              departureCharge.isFinite, (50...100).contains(departureCharge),
              (0...23).contains(idleStartHour), (0...23).contains(idleEndHour), idleStartHour != idleEndHour
        else { throw AppError.message("参数无效：请检查电量上下限、负载、线程数和时间设置。") }
    }
}
struct Plan: Codable {
    var start: Date
    var deadline: Date
    var goal: DeadlineGoal
}
struct Reading {
    var percent: Double
    var health: Double
    var plugged: Bool
    var charging: Bool
    var cycles: Int
    var valid: Bool { percent.isFinite && health.isFinite && percent >= 0 && health > 0 }
}
struct Decision {
    var mode: Mode
    var charging: Bool
    var load: Double
    var reason: String
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Pure policy: no I/O and no hardware access, shared by application and tests.
struct Policy {
    static func decide(mode: Mode, plan: Plan?, settings: Settings, reading: Reading,
                       now: Date, charging: Bool, idle: Double, thermal: Int,
                       reserve: TimeInterval, paused: Bool, stalled: Bool = false) -> Decision {
        func result(_ mode: Mode, _ charge: Bool, _ load: Double, _ why: String) -> Decision {
            Decision(mode: mode, charging: charge, load: load, reason: why)
        }
        guard reading.valid else { return result(.system, true, 0, "电池读数异常") }
        guard mode == .daily || mode == .timed else {
            return result(mode, true, 0, mode == .ready ? "允许正常充电，等待手动切换" : "由 macOS 管理电源")
        }
        guard reading.plugged else { return result(.system, true, 0, "电源已拔出，任务结束") }
        guard reading.health > settings.targetHealth else { return result(.ready, true, 0, "已达到目标健康度") }
        var activeMode = mode
        if mode == .timed {
            guard let plan else { return result(.system, true, 0, "缺少定时任务") }
            if plan.goal == .departure && now >= plan.deadline.addingTimeInterval(-reserve) {
                return result(.ready, true, 0, "进入离开前充电准备阶段")
            }
            if now >= plan.deadline { activeMode = .daily }
            else if now < plan.start { return result(.timed, true, 0, "等待计划开始") }
        }
        // macOS may hold its own charge limit below `maximum` (no firmware key overrides it);
        // a stalled charge phase then counts as the top of the cycle.
        let charge = reading.percent <= settings.minimum ? true
            : (reading.percent >= settings.maximum || stalled ? false : charging)
        guard activeMode == .timed else { return result(activeMode, charge, 0, "无额外负载，正常循环") }
        // System thermal states: nominal=0, fair=1, serious=2, critical=3.
        if thermal >= 2 { return result(.timed, true, 0, "系统温控保护，暂停负载") }
        if reading.percent <= max(3, settings.minimum / 2) {
            return result(.ready, true, 0, "低电量保护，任务结束")
        }
        if paused { return result(.timed, charge, 0, "已手动暂停负载") }
        if settings.pauseOnActivity && idle < settings.idleSeconds {
            return result(.timed, charge, 0, "检测到用户活动，等待持续空闲")
        }
        return result(.timed, charge, thermal == 1 ? 0.5 : 1, thermal == 1 ? "热状态升高，负载减半" : "充放电全程压测")
    }
}
