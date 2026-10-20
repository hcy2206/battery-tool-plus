import SwiftUI
import Charts
import AppKit
import Metal

// Select the property wrapper on SDKs that also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}

struct NativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Controller(demo: CommandLine.arguments.contains("--demo"))
    var body: some Scene {
        WindowGroup("BatteryTool", id: "manager") {
            ManagerView(model: model)
                .onAppear { delegate.controller = model }
                .frame(minWidth: 900, minHeight: 650)
                .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("确定") { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
        .defaultSize(width: 1060, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("BatteryTool · \(model.mode.title)", systemImage: batterySymbol(model.reading)) {
            MenuControls(model: model)
        }
    }
    private func batterySymbol(_ reading: Reading) -> String {
        if reading.charging { return "battery.100percent.bolt" }
        guard reading.valid else { return "battery.0percent" }
        let level = [0, 25, 50, 75, 100].min { abs(Double($0) - reading.percent) < abs(Double($1) - reading.percent) }!
        return "battery.\(level)percent"
    }
}
struct MenuControls: View {
    @ObservedObject var model: Controller
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(model.reading.percent, specifier: "%.0f")% · \(model.mode.title)")
        Button("打开管理窗口") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Picker("模式", selection: Binding(get: { model.mode }, set: { selected in
            guard selected != model.mode else { return }
            if selected == .timed { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
            else { model.switchMode(selected) }
        })) {
            ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.inline)
        Divider()
        Button(model.paused ? "恢复负载" : "暂停负载") { model.togglePause() }.disabled(model.mode != .timed)
        Divider()
        Button("退出并恢复充电") { NSApp.terminate(nil) }
    }
}
struct ManagerView: View {
    @ObservedObject var model: Controller
    @ViewState<String> private var page = "控制台"
    @ViewState<Date> private var start = Date()
    @ViewState<Date> private var deadline = Date().addingTimeInterval(8*3600)
    @ViewState<DeadlineGoal> private var goal = DeadlineGoal.desk
    @ViewState<Bool> private var clearConfirmation = false
    init(model: Controller, page: String = "控制台") {
        self.model = model
        self._page = ViewState(wrappedValue: page)
    }
    private let pages = ["控制台", "任务设置", "空闲推荐", "历史记录"]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("BatteryTool", systemImage: "bolt.batteryblock.fill")
                    .font(.title2.bold()).padding(.top, 12)
                Text(model.demo ? "演示模式 · 不操作硬件" : "电池与负载管理").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(pages, id: \.self) { name in
                        Button {
                            page = name
                            if name == "任务设置" { model.recommend() }
                        } label: {
                            HStack {
                                Image(systemName: ["控制台": "gauge.with.dots.needle.50percent", "任务设置": "slider.horizontal.3", "空闲推荐": "moon.stars", "历史记录": "clock.arrow.circlepath"][name]!)
                                Text(name)
                                Spacer()
                            }
                            .foregroundStyle(page == name ? Color.white : Color.primary)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(page == name ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 12)
                Spacer()
                Text("关闭窗口后任务继续运行。\n退出应用会停止负载并恢复充电。")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom)
            }.padding(.horizontal, 12).navigationSplitViewColumnWidth(210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(page).font(.largeTitle.bold())
                            Text(model.reason).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.demo { Text("DEMO").font(.caption.bold()).padding(8).background(.blue.opacity(0.15), in: Capsule()) }
                        if !model.authorized {
                            Button(model.authorizing ? "等待授权…" : "授权电池控制") { model.authorize() }
                                .disabled(model.authorizing).buttonStyle(.borderedProminent)
                        }
                    }
                    if !model.warning.isEmpty {
                        Label(model.warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    switch page {
                    case "任务设置": taskSettings
                    case "空闲推荐": idleSettings
                    case "历史记录": history
                    default: dashboard
                    }
                }.padding(28)
            }
        }
        .onChange(of: model.settings.recordHistory) { _, _ in _ = model.saveSettings() }
        .confirmationDialog("清除全部本地历史记录？", isPresented: $clearConfirmation) {
            Button("清除历史", role: .destructive) { model.clearHistory() }
        }
    }
    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold())
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                metric("电池电量", String(format: "%.1f%%", model.reading.percent), "battery.75percent")
                metric("电池健康", String(format: "%.1f%%", model.reading.health), "heart")
                metric("循环次数", "\(model.reading.cycles)", "arrow.triangle.2.circlepath")
            }
            GroupBox("运行状态") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("当前模式", value: model.mode.title)
                    LabeledContent("电源", value: model.reading.plugged ? "适配器已连接" : "电池供电")
                    LabeledContent("实际充电", value: model.reading.charging ? "正在充电" : "未充电")
                    LabeledContent("CPU / GPU 负载档位", value: String(format: "%.0f%% / %.0f%%", model.cpuLoad, model.gpuLoad))
                    LabeledContent("系统热状态", value: ["正常", "升高 · 降载", "严重 · 暂停", "临界 · 暂停"][min(3, max(0, model.thermal))])
                    if let plan = model.plan {
                        LabeledContent(plan.goal.title, value: plan.deadline.formatted(date: .abbreviated, time: .shortened))
                        if plan.goal == .departure {
                            LabeledContent("预计提前收尾", value: "\(Int(model.reserveMinutes)) 分钟")
                            Text(model.reserveReason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("模式").font(.headline)
                HStack(spacing: 10) {
                    ForEach(Mode.allCases, id: \.self) { candidate in modeButton(candidate) }
                }
                Text("四种模式互斥，高亮为当前模式。退出应用时交还系统管理并恢复充电。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("操作").font(.headline)
                HStack {
                    Button("设置定时…") { openPlanSettings() }
                    Button(model.paused ? "恢复负载" : "暂停负载") { model.togglePause() }.disabled(model.mode != .timed)
                    Button("停止并交还系统管理", role: .destructive) { model.switchMode(.system) }.disabled(model.mode == .system)
                }
            }
            Text("负载档位控制计算任务的工作比例，不代表精确的系统占用率。充电和放电阶段均保持你设置的负载，系统温控仍优先。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func openPlanSettings() { page = "任务设置"; model.recommend() }
    private func modeSummary(_ mode: Mode) -> String {
        switch mode {
        case .system: return "由 macOS 管理电源"
        case .ready: return "保持接管，正常充电"
        case .daily: return "按上下限循环，无负载"
        case .timed: return model.plan == nil ? "需先设置计划" : "按计划充放电压测"
        }
    }
    private func modeButton(_ candidate: Mode) -> some View {
        let selected = model.mode == candidate
        return Button {
            guard !selected else { return }
            if candidate == .timed { openPlanSettings() } else { model.switchMode(candidate) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).fontWeight(.semibold)
                Text(modeSummary(candidate)).font(.caption).opacity(0.8)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var taskSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("运行时间") {
                Form {
                    DatePicker("开始时间", selection: $start)
                    Button("从现在开始") { start = Date() }
                    Picker("截止目标", selection: $goal) {
                        ForEach(DeadlineGoal.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    DatePicker("目标时间", selection: $deadline)
                    if goal == .departure {
                        number("离开时目标电量 (%)", $model.settings.departureCharge)
                        number("样本不足时预留充电 (分钟)", $model.settings.chargeReserveMinutes)
                        let estimate = model.reserveEstimate(for: model.settings)
                        Text("预计结束压测：\(deadline.addingTimeInterval(-estimate.0).formatted(date: .abbreviated, time: .shortened))")
                        Text(estimate.1).font(.caption).foregroundStyle(.secondary)
                        Text("预留时间不足时直接进入充电准备。预计时间不能保证实际充满。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("到点停止负载，并切换到日常循环。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            GroupBox("负载与电池循环") {
                Form {
                    HStack { Text("CPU \(Int(model.settings.cpu))%"); Slider(value: $model.settings.cpu, in: 0...100, step: 5) }
                    Stepper("CPU 工作线程：\(model.settings.threads)", value: $model.settings.threads, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    HStack { Text("GPU \(Int(model.settings.gpu))%"); Slider(value: $model.settings.gpu, in: 0...100, step: 5) }
                    number("充电下限 (%)", $model.settings.minimum)
                    number("放电上限 (%)", $model.settings.maximum)
                    number("目标健康度 (%)", $model.settings.targetHealth)
                    Toggle("使用电脑时自动暂停负载", isOn: $model.settings.pauseOnActivity)
                    number("持续空闲后恢复 (秒)", $model.settings.idleSeconds)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let suggestion = model.recommendation {
                GroupBox("本次启动前的空闲推荐") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(suggestion.start.formatted()) — \(suggestion.end.formatted())")
                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        Button("采用推荐时间") { start = suggestion.start; deadline = suggestion.end; model.event("接受推荐时间窗口") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            Text("参数在下次启动任务或切换到日常循环时生效；停止和暂停按钮始终立即生效。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("刷新推荐") { model.recommend() }
                Button("保存设置") { _ = model.saveSettings() }
                Spacer()
                Button("确认并启动计划") { if model.start(plan: Plan(start: start, deadline: deadline, goal: goal)) { page = "控制台" } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
    }
    private var idleSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("本地学习") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $model.settings.recordHistory) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("记录空闲状态与电量历史，用于推荐")
                            Text("只保存时间、活动/空闲、电量和负载状态，不记录按键内容；保留最近 90 天。应用未运行或睡眠期间记为未知。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack(spacing: 32) {
                        hourPicker("初始空闲开始", $model.settings.idleStartHour)
                        hourPicker("初始空闲结束", $model.settings.idleEndHour)
                        Spacer()
                        Button("保存并计算推荐") { if model.saveSettings() { model.recommend() } }
                    }
                    Text("历史记录不足时按这个时段推荐，支持跨午夜（例如 23:00 到次日 8:00）。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            GroupBox("建议窗口") {
                VStack(alignment: .leading, spacing: 14) {
                    if let recommendation = model.recommendation {
                        HStack(alignment: .center, spacing: 20) {
                            windowTile("开始", recommendation.start)
                            Image(systemName: "arrow.right").font(.title2).foregroundStyle(.tertiary)
                            windowTile("结束", recommendation.end)
                            Spacer()
                            windowTile("时长", nil, text: durationText(recommendation.end.timeIntervalSince(recommendation.start)))
                        }
                        Text(recommendation.reason).font(.callout).foregroundStyle(.secondary)
                        Button("使用此窗口设置任务") {
                            start = recommendation.start; deadline = recommendation.end; page = "任务设置"
                            model.event("接受推荐时间窗口")
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Text("点击“保存并计算推荐”生成建议窗口。").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            Text("推荐只在你确认后启动，不会自行扩大窗口。看视频、开会等没有键鼠输入的活动会被判断为空闲，需要时手动暂停负载。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func hourPicker(_ title: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Picker(title, selection: value) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }.labelsHidden().frame(width: 96)
        }
    }
    private func windowTile(_ title: String, _ date: Date?, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let date {
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.callout)
                Text(date.formatted(date: .omitted, time: .shortened)).font(.title2.monospacedDigit().bold())
            } else {
                Text(text ?? "").font(.title2.monospacedDigit().bold())
            }
        }
    }
    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
    private struct ChartSample: Identifiable {
        var id: Int
        var sample: Observation
        var segment: Int
    }
    private var chartSamples: [ChartSample] {
        var segment = 0
        return model.graph.enumerated().map { index, sample in
            if index > 0 && sample.time.timeIntervalSince(model.graph[index - 1].time) > 90 { segment += 1 }
            return ChartSample(id: index, sample: sample, segment: segment)
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("过去 24 小时电量").font(.headline)
                Spacer()
                Button("刷新") { model.refreshHistory() }
                Button("清除历史", role: .destructive) { clearConfirmation = true }
            }
            if model.graph.isEmpty {
                ContentUnavailableView("暂无电量历史", systemImage: "chart.xyaxis.line", description: Text("在空闲推荐页面开启记录，运行后会逐步积累。"))
            } else {
                Chart(chartSamples) { item in
                    LineMark(x: .value("时间", item.sample.time), y: .value("电量", item.sample.percent), series: .value("区间", item.segment))
                    PointMark(x: .value("时间", item.sample.time), y: .value("电量", item.sample.percent)).symbolSize(8)
                }.chartYScale(domain: 0...100).frame(height: 200)
            }
            Text("最近事件").font(.headline)
            ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                Text(event).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
    }
}

#if !TESTING
@main struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--helper", let uid = UInt32(args[2]) {
            exit(runHelper(uid: uid, token: args[3]))
        }
        // The UI and load workers must never run as root.
        guard geteuid() != 0 else { fputs("Launch the app as a normal user.\n", stderr); exit(1) }
        if args.contains("--check-gpu") {
            do {
                guard let device = MTLCreateSystemDefaultDevice() else { throw AppError.message("Metal GPU 不可用") }
                _ = try makeLoadPipeline(device: device)
                print("Metal pipeline compiled for \(device.name); no GPU work submitted.")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(2) }
        }
        if args.count == 5 && args[1] == "--worker", let intensity = Double(args[3]), let threads = Int(args[4]) {
            exit(runLoadWorker(kind: args[2], intensity: intensity, threads: threads))
        }
        NativeApp.main()
    }
}

#endif
