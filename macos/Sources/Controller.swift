import AppKit
import Combine
import CoreGraphics
import IOKit.pwr_mgt

@MainActor final class Controller: ObservableObject {
    @Published var settings = Settings()
    @Published var mode = Mode.system
    @Published var reading = Reading(percent: 0, health: 100, plugged: false, charging: false, cycles: 0)
    @Published var reason = "正在读取电池状态"
    @Published var errorMessage: String?
    @Published var warning = ""
    @Published var cpuLoad = 0.0
    @Published var gpuLoad = 0.0
    @Published var thermal = 0
    @Published var plan: Plan?
    @Published var authorized = false
    @Published var authorizing = false
    @Published var paused = false
    @Published var recommendation: Recommendation?
    @Published var events = [String]()
    @Published var graph = [Observation]()
    @Published var reserveMinutes = 120.0
    @Published var reserveReason = "充电样本不足"
    @Published var idleSeconds = 0.0
    /// With the lid closed, macOS will not light an external display again without external
    /// power, so a display that sleeps during a discharge stays dark until the adapter is back.
    @Published var preventDisplaySleep = UserDefaults.standard.object(forKey: "preventDisplaySleep") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preventDisplaySleep, forKey: "preventDisplaySleep"); tick() }
    }
    @Published var displayAwake = false
    /// PushDeer key; empty disables pushes. Stored outside Settings so older settings files load.
    @Published var pushKey = UserDefaults.standard.string(forKey: "pushDeerKey") ?? "" {
        didSet { UserDefaults.standard.set(pushKey, forKey: "pushDeerKey"); notifier.key = pushKey }
    }
    @Published var pushStatus = ""
    /// Repeated sleep notices that the system then abandons (another process waking the display
    /// every few seconds in clamshell mode). Load is kept running through them.
    @Published var sleepStorm = false
    let demo: Bool
    private let hardware = HardwareClient()
    private let load = LoadManager()
    private let systemHealth = SystemHealthMonitor()
    private var history: History?
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var runtimeSettings = Settings()
    private var charging = true
    private var appliedCharging: Bool?
    private var lastTick = Date()
    private var lastSample = Date.distantPast
    private var sampleRefresh = Date.distantPast
    private var chargeSamples = [Observation]()
    private var lastPlanEvent = ""
    private var pendingCharge: (Date, Double)?
    private var chargeStall: (Date, Double)?
    private var assertion: IOPMAssertionID = 0
    private var asserting = false
    private var displayAssertion: IOPMAssertionID = 0
    private var sleeping = false
    private var pendingSleepRestore: DispatchWorkItem?
    private var recentSleepNotices = [Date]()
    let notifier: Notifier
    private var lastSleepEvent = Date.distantPast
    private var sleepEventsSuppressed = 0
    private var startGrace = Date.distantPast
    private var thermalHoldUntil = Date.distantPast
    private var controllerLock: Int32 = -1
    private let settingsURL: URL

    init(demo: Bool, storageDirectory: URL? = nil, startTimer: Bool = true, transport: Notifier.Transport? = nil) {
        self.demo = demo
        notifier = Notifier(key: UserDefaults.standard.string(forKey: "pushDeerKey") ?? "", transport: transport)
        let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(demo ? "BatteryTool-Demo" : "BatteryTool")
        settingsURL = base.appendingPathComponent("settings.json")
        do {
            history = try History(directory: base)
            controllerLock = open(base.appendingPathComponent("controller.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard controllerLock >= 0, flock(controllerLock, LOCK_EX | LOCK_NB) == 0 else {
                if controllerLock >= 0 { close(controllerLock); controllerLock = -1 }
                throw AppError.message("已有一个管理窗口进程正在运行")
            }
            if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
                try saved.validate(); settings = saved
            }
        } catch { errorMessage = error.localizedDescription }
        runtimeSettings = settings
        if demo { authorized = true; settings.pauseOnActivity = false }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        })
        tick()
        refreshHistory()
        recommend()
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }
    func saveSettings() -> Bool {
        guard controllerLock >= 0 else { return false }
        do {
            try settings.validate()
            try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func authorize() {
        guard !demo, !authorizing, controllerLock >= 0 else { return }
        authorizing = true
        hardware.authorize { [weak self] message in
            guard let self else { return }
            self.authorizing = false
            self.authorized = message == nil
            if let message { self.errorMessage = message }
            self.tick()
        }
    }
    func switchMode(_ selected: Mode) {
        // Stopping must work even while the settings form contains invalid edits.
        if selected == .daily {
            guard saveSettings() else { return }
            runtimeSettings = settings
        }
        guard selected == .system || (authorized && controllerLock >= 0) else {
            errorMessage = "请先点击「授权电池控制」，完成一次管理员授权。"; return
        }
        load.stop(); cpuLoad = 0; gpuLoad = 0
        mode = selected; plan = nil; paused = false
        appliedCharging = nil
        event("切换模式：\(selected.title)")
        tick()
    }
    @discardableResult func start(plan: Plan) -> Bool {
        guard saveSettings() else { return false }
        guard authorized && controllerLock >= 0 else { errorMessage = "请先授权电池控制"; return false }
        guard plan.deadline > Date(), plan.start < plan.deadline,
              plan.deadline.timeIntervalSince(Date()) <= 24*3600 else {
            errorMessage = "任务截止必须晚于开始时间，目标时间必须在未来 24 小时内。"; return false
        }
        guard settings.cpu > 0 || settings.gpu > 0 else { errorMessage = "请至少启用一种负载"; return false }
        runtimeSettings = settings
        load.stop(); self.plan = plan; mode = .timed; paused = false
        appliedCharging = nil
        // Require a full idle interval after starting before launching load.
        startGrace = Date().addingTimeInterval(settings.idleSeconds)
        event("确认定时压测：\(plan.goal.title)，截止 \(plan.deadline.formatted())")
        tick()
        let started = mode == .timed || mode == .ready
        if !started && errorMessage == nil { errorMessage = "无法启动任务：\(reason)" }
        return started
    }
    func togglePause() { paused.toggle(); event(paused ? "手动暂停负载" : "恢复负载"); tick() }
    func recommend() {
        // Recommendation reads the form as edited; saving stays an explicit user action.
        do { try settings.validate() } catch { errorMessage = error.localizedDescription; return }
        recommendation = Predictor.recommend(now: Date(), settings: settings,
                                             samples: history?.samples(since: Date().addingTimeInterval(-28*86400)) ?? [])
    }
    func event(_ text: String) {
        // Task/control events are stored regardless of activity-learning consent.
        do { try history?.event(text) } catch { errorMessage = error.localizedDescription }
        events = history?.events() ?? []
    }
    func reserveEstimate(for settings: Settings) -> (Double, String) {
        Predictor.chargeReserve(samples: chargeSamples, percent: reading.percent,
                                target: settings.departureCharge, fallback: settings.chargeReserveMinutes)
    }
    func refreshHistory() {
        events = history?.events() ?? []
        graph = history?.samples(since: Date().addingTimeInterval(-24*3600)) ?? []
        chargeSamples = history?.samples(since: Date().addingTimeInterval(-7*86400)) ?? []
        sampleRefresh = Date()
    }
    func clearHistory() {
        do { try history?.clear(); refreshHistory(); recommend() }
        catch { errorMessage = error.localizedDescription }
    }
    private func setAssertion(_ active: Bool) {
        if active && !asserting {
            asserting = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   "Battery Tool Plus approved timed session" as CFString, &assertion) == kIOReturnSuccess
        } else if !active && asserting {
            IOPMAssertionRelease(assertion); asserting = false
        }
    }
    private func setDisplayAssertion(_ active: Bool) {
        if active && !displayAwake {
            displayAwake = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "Battery Tool Plus cycling: clamshell display cannot wake without external power" as CFString,
                                                       &displayAssertion) == kIOReturnSuccess
        } else if !active && displayAwake {
            IOPMAssertionRelease(displayAssertion); displayAwake = false
        }
    }
    /// A sleep notice is not always a sleep: another process tickling the display every few
    /// seconds in clamshell mode produces a willSleep/didWake pair each time. Charging is restored
    /// only if the Mac has not woken again within a short grace, and the helper keeps being
    /// pinged while asleep so a dark-wake maintenance window cannot expire its lease.
    static let sleepRestoreGrace: TimeInterval = 3
    static let sleepStormThreshold = 4
    private func sleep() {
        sleeping = true
        let now = Date()
        recentSleepNotices = recentSleepNotices.filter { now.timeIntervalSince($0) < 60 } + [now]
        if !sleepStorm && recentSleepNotices.count >= Controller.sleepStormThreshold {
            sleepStorm = true
            let text = "一分钟内收到 \(recentSleepNotices.count) 次系统睡眠通知且随即唤醒。可能有程序在频繁点亮显示器；负载将不再因这些通知停止。排查：pmset -g log | grep UserIsActive"
            event("检测到睡眠通知风暴：" + text)
            notify("睡眠通知风暴", text)
        }
        // In a storm the Mac does not actually sleep; stopping load on every notice would starve
        // the session, so load is stopped together with the deferred charge restore instead.
        // Workers exit on their own 15 s heartbeat lease if the Mac does sleep after all.
        if !sleepStorm { load.stop(); cpuLoad = 0; gpuLoad = 0 }
        setAssertion(false); setDisplayAssertion(false)
        pendingSleepRestore?.cancel()
        let restore = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sleeping else { return }
                self.load.stop(); self.cpuLoad = 0; self.gpuLoad = 0
                guard self.authorized, !self.demo else { return }
                do { try self.hardware.request("charge"); self.appliedCharging = true }
                catch {
                    self.errorMessage = "睡眠前恢复失败：\(error.localizedDescription)"
                    self.notify("睡眠前恢复充电失败", error.localizedDescription)
                }
            }
        }
        pendingSleepRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Controller.sleepRestoreGrace, execute: restore)
        if now.timeIntervalSince(lastSleepEvent) >= 60 {
            let suffix = sleepEventsSuppressed > 0 ? "（期间另有 \(sleepEventsSuppressed) 次睡眠通知）" : ""
            event("系统睡眠：停止负载，唤醒后重新检查任务截止时间" + suffix)
            lastSleepEvent = now; sleepEventsSuppressed = 0
        } else { sleepEventsSuppressed += 1 }
    }
    private func wake() {
        pendingSleepRestore?.cancel(); pendingSleepRestore = nil
        sleeping = false
        startGrace = Date().addingTimeInterval(30)
        appliedCharging = nil
        tick()
    }
    func tick() {
        guard controllerLock >= 0 else { return }
        if sleeping {
            // Heartbeat only: the lease must survive dark wakes, and nothing else may change.
            if authorized && !demo { try? hardware.request("ping") }
            return
        }
        let now = Date()
        let observationGap = now.timeIntervalSince(lastTick)
        lastTick = now
        if observationGap > 10 {
            // Never infer user idleness across a sleep, clock jump, or controller stall.
            startGrace = now.addingTimeInterval(settings.idleSeconds)
            load.stop()
        }
        if sleepStorm, let last = recentSleepNotices.last, now.timeIntervalSince(last) > 300 {
            sleepStorm = false; recentSleepNotices.removeAll()
            event("睡眠通知风暴已结束")
        }
        // kCGAnyInputEventType is the documented all-input sentinel.
        idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~UInt32(0))!)
        if demo { idleSeconds = 600 }
        thermal = demo ? 0 : ProcessInfo.processInfo.thermalState.rawValue
        if thermal >= 2 { thermalHoldUntil = now.addingTimeInterval(60) }
        if !demo { systemHealth.refreshIfStale() }
        reading = demo ? Reading(percent: 64, health: 91, plugged: true, charging: charging, cycles: 182,
                                   batteryWatts: charging ? 38.2 : -41.5, adapterWatts: charging ? 72.4 : 0, systemWatts: 34.1)
            : batteryReading(systemHealth: systemHealth.value)
        do {
            let settings = runtimeSettings
            try settings.validate()
            if authorized && !demo { try hardware.request("ping") }
            if now.timeIntervalSince(sampleRefresh) >= 60 { refreshHistory() }
            let reserve = reserveEstimate(for: settings)
            reserveMinutes = reserve.0 / 60; reserveReason = reserve.1
            let effectiveIdle = now < startGrace ? 0 : idleSeconds
            // Charging is permitted but the system is not charging and the level is flat:
            // ten such minutes mean the system holds its own limit below `maximum`.
            if (mode == .daily || mode == .timed) && charging && reading.plugged && !reading.charging
                && reading.percent < settings.maximum {
                if chargeStall.map({ reading.percent > $0.1 + 0.5 }) ?? true { chargeStall = (now, reading.percent) }
            } else { chargeStall = nil }
            let stalled = chargeStall.map { now.timeIntervalSince($0.0) >= 600 } ?? false
            let decision = Policy.decide(mode: mode, plan: plan, settings: settings, reading: reading, now: now,
                                         charging: charging, idle: effectiveIdle, thermal: now < thermalHoldUntil ? max(2, thermal) : thermal,
                                         reserve: reserve.0, paused: paused, stalled: stalled)
            if decision.mode != mode {
                event("任务转换：\(decision.reason)")
                // The departure reserve phase is part of the plan; everything else ending a task is not.
                let healthReached = reading.health <= settings.targetHealth
                if (mode == .daily || mode == .timed) && (decision.mode == .system || healthReached
                    || reading.percent <= max(3, settings.minimum / 2)) {
                    notify(healthReached ? "已达到目标健康度" : "任务结束",
                           "\(decision.reason)。电量 \(Int(reading.percent.rounded()))%，健康度 \(String(format: "%.1f", reading.health))%。")
                }
                mode = decision.mode
                if mode != .timed { plan = nil }
            }
            if stalled && charging && !decision.charging {
                event("系统已停止充电并停留在 \(Int(reading.percent.rounded()))%，以此作为本轮上限，开始放电")
            }
            reason = decision.reason
            charging = decision.charging
            if authorized && appliedCharging != charging {
                if !demo { try hardware.request(charging ? "charge" : "discharge") }
                appliedCharging = charging
            }
            let scale = authorized ? decision.load : 0
            if !demo { try load.update(cpu: settings.cpu * scale, gpu: settings.gpu * scale, threads: settings.threads) }
            cpuLoad = settings.cpu * scale; gpuLoad = settings.gpu * scale
            setAssertion(mode == .timed && plan.map { now < $0.deadline } == true && !demo)
            setDisplayAssertion(preventDisplaySleep && (mode == .daily || mode == .timed) && !demo)
            warning = ""
            if mode == .timed && charging && reading.percent < settings.maximum {
                if pendingCharge == nil { pendingCharge = (now, reading.percent) }
                if let began = pendingCharge, now.timeIntervalSince(began.0) >= 600 {
                    if reading.percent <= began.1 + 0.5 { warning = "已允许充电，但十分钟内电量未明显上升。负载可能超过充电余量。" }
                    else { pendingCharge = (now, reading.percent) }
                }
            } else { pendingCharge = nil }
            if mode == .ready && reading.percent < settings.departureCharge {
                warning = "正在允许正常充电，实际完成时间由系统与适配器决定。"
            }
            if self.settings.recordHistory && reading.valid && observationGap <= 10 && now.timeIntervalSince(lastSample) >= 30 {
                // Genuine idle input is recorded; heat pauses and load state are not labels for user activity.
                // A history write failure must never end power control, so it is reported without leaving the task.
                lastSample = now
                do {
                    try history?.add(Observation(time: now, idle: idleSeconds >= settings.idleSeconds,
                                                 percent: reading.percent, charging: reading.charging, load: scale > 0))
                    refreshHistory()
                } catch { warning = "历史记录写入失败：\(error.localizedDescription)" }
            }
            if reason != lastPlanEvent {
                event(reason); lastPlanEvent = reason
            }
        } catch {
            load.stop(); cpuLoad = 0; gpuLoad = 0; setAssertion(false); setDisplayAssertion(false)
            mode = .system; plan = nil
            var message = error.localizedDescription
            if authorized && !demo {
                do { try hardware.request("charge"); appliedCharging = true }
                catch { message += "；恢复充电失败：\(error.localizedDescription)" }
            }
            if !demo && hardware.authorized {
                try? hardware.request("quit")
                hardware.authorized = false
            }
            authorized = demo
            reason = "任务已停止"
            if errorMessage != message { event(message); errorMessage = message }
            notify("任务因错误停止", message)
        }
    }
    /// Pushed: task endings the user did not trigger, failed charging restoration, sleep storms.
    /// Not pushed: phase flips, thermal pauses, user activity pauses, user-initiated mode changes.
    func notify(_ title: String, _ body: String) {
        guard !demo || notifier.key.hasPrefix("test-") else { return }
        notifier.send(title, body) { [weak self] error in
            if let error { self?.pushStatus = "推送失败：\(error.localizedDescription)" }
        }
    }
    func testPush() {
        pushStatus = "发送中…"
        guard notifier.send("测试推送", "来自 \(Host.current().localizedName ?? "Mac") 的测试消息。", force: true, completion: { [weak self] error in
            self?.pushStatus = error.map { "推送失败：\($0.localizedDescription)" } ?? "已发送 \(Date().formatted(date: .omitted, time: .shortened))"
        }) else { pushStatus = "请先填写 PushDeer Key"; return }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        load.stop(); setAssertion(false); setDisplayAssertion(false)
        if authorized && !demo {
            do { try hardware.request("quit") }
            catch { event("退出时恢复失败：\(error.localizedDescription)") }
        }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if controllerLock >= 0 { close(controllerLock); controllerLock = -1 }
    }
}
