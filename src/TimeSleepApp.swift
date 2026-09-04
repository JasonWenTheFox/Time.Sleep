// Time.Sleep — macOS 菜单栏定时 睡眠/关机 工具
// 构建: scripts/build.sh（swiftc 直接编译，无需 Xcode 工程）
//
// 设计要点：
// - MenuBarExtra 常驻菜单栏，LSUIElement=true（无 Dock 图标）
// - 倒计时基于绝对时间 Date，系统中途睡眠也不丢失进度
// - 到点动作：睡眠 = /usr/bin/pmset sleepnow（零权限）；关机 = 后台 osascript 让 System Events 执行
//   （标准 macOS 首次触发可能弹「自动化」授权；切换到关机时会做无动作权限预检）
// - 到点前 N 秒（可配置，默认 60s）发系统通知，带「取消 / 顺延 10 分钟」按钮
// - 深浅色模式：全部使用系统语义色，自动跟随
// - i18n：跟随系统语言，简体中文/繁体中文/英文（L10n 三语表）
// - Dry-run：启动参数 --dry-run 或环境变量 TIMESLEEP_DRYRUN=1 时只记日志不执行

import SwiftUI
import UserNotifications
import AppKit
import ServiceManagement
import ApplicationServices

// MARK: - i18n（简体/繁體/English）

enum L10n {
    enum Language { case hans, hant, en }

    static let language: Language = {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else { return .en }
        guard preferred.hasPrefix("zh") else { return .en }
        // zh-Hant / zh-TW / zh-HK / zh-MO → 繁體；其余 zh* → 简体
        if preferred.contains("hant") || preferred.contains("-tw")
            || preferred.contains("-hk") || preferred.contains("-mo") {
            return .hant
        }
        return .hans
    }()

    /// t(简体, 繁體, English)
    static func t(_ hans: String, _ hant: String, _ en: String) -> String {
        switch language {
        case .hans: return hans
        case .hant: return hant
        case .en: return en
        }
    }

    static var appName: String { "Time.Sleep" }
    static var sleepText: String { t("睡眠", "睡眠", "Sleep") }
    static var shutdownText: String { t("关机", "關機", "Shut Down") }
    static func actionText(_ a: PowerAction) -> String { a == .sleep ? sleepText : shutdownText }
}

// MARK: - 基础类型

enum PowerAction: String {
    case sleep
    case shutdown

    var label: String { L10n.actionText(self) }
}

enum TimerPhase: Equatable {
    case idle
    case running
    case paused
}

enum TimerInputMode: String {
    case countdown
    case scheduledTime
}

enum ReminderStrength: String {
    case standard
    case enhanced
}

enum PermissionState: Equatable {
    case unknown
    case checking
    case allowed
    case notDetermined
    case denied
    case unavailable
}

enum DefaultsKeys {
    static let action = "action"
    static let warnLeadSeconds = "warnLeadSeconds"
    static let reminderStrength = "reminderStrength"
    static let launchAtLogin = "launchAtLogin"
    static let lastHours = "lastHours"
    static let lastMinutes = "lastMinutes"
    static let lastSeconds = "lastSeconds"
    static let timerInputMode = "timerInputMode"
    static let scheduledHour = "scheduledHour"
    static let scheduledMinute = "scheduledMinute"
}

// MARK: - 计时核心模型

final class TimerModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    // MARK: 状态（视图观察）

    @Published var phase: TimerPhase = .idle
    @Published var remaining: TimeInterval = 0          // 运行中剩余秒数
    @Published var pausedRemaining: TimeInterval = 0    // 暂停时保存的剩余秒数
    @Published private(set) var deadline: Date?
    @Published private(set) var warned = false
    /// 面板顶部展示的一次性提示（如「已跳过」「模拟执行」）
    @Published var statusMessage: String?
    @Published private(set) var notificationPermission: PermissionState = .unknown
    @Published private(set) var notificationAlertEnabled = false
    @Published private(set) var notificationSoundEnabled = false
    @Published private(set) var automationPermission: PermissionState = .unknown
    @Published private(set) var permissionCheckPerformed = false

    private var ticker: Timer?
    /// 连续时钟不受用户修改系统时间或时区影响，并且会跨系统休眠继续推进。
    private let continuousClock = ContinuousClock()
    private var continuousDeadline: ContinuousClock.Instant?
    private var fallbackSound: NSSound?
    private var fallbackReminderWorkItem: DispatchWorkItem?
    /// 让异步通知查询只能作用于发起查询时的同一轮计时，避免取消/顺延后旧回调重新发通知
    private var timerSessionID = UUID()
    private let logISO = ISO8601DateFormatter()
    /// 复用的日志串行队列，避免多线程交错写同一文件
    private let logQueue = DispatchQueue(label: "io.github.JasonWenTheFox.TimeSleep.log")

    static let warningCategoryID = "TIMER_WARNING"
    static let actionCancelID = "ACTION_CANCEL"
    static let actionSnoozeID = "ACTION_SNOOZE"
    static let enhancedFollowUpID = "timesleep-enhanced-follow-up"
    static let testReminderID = "timesleep-test-reminder"
    static let enhancedTestFollowUpID = "timesleep-enhanced-test-follow-up"
    static let systemEventsBundleID = "com.apple.systemevents"
    static let snoozeMinutes = 10
    /// 到点时刻落后超过该秒数（说明系统在休眠中穿越了计时终点）则跳过执行
    static let maxLatenessGrace: TimeInterval = 120

    // MARK: 设置（UserDefaults 实时读取，@AppStorage 在视图层写入）

    var action: PowerAction {
        PowerAction(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.action) ?? "") ?? .sleep
    }

    /// 预警提前量（秒）；0 = 关闭提醒；未设置时默认 60
    var warnLeadSeconds: Int {
        if let v = UserDefaults.standard.object(forKey: DefaultsKeys.warnLeadSeconds) as? Int { return v }
        return 60
    }

    var reminderStrength: ReminderStrength {
        ReminderStrength(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.reminderStrength) ?? "")
            ?? .enhanced
    }

    var isDryRun: Bool {
        CommandLine.arguments.contains("--dry-run")
            || ProcessInfo.processInfo.environment["TIMESLEEP_DRYRUN"] == "1"
    }

    // MARK: 初始化

    override init() {
        super.init()
        let cancel = UNNotificationAction(identifier: Self.actionCancelID,
                                          title: L10n.t("取消", "取消", "Cancel"),
                                          options: [.destructive])
        let snooze = UNNotificationAction(identifier: Self.actionSnoozeID,
                                          title: L10n.t("顺延 10 分钟", "順延 10 分鐘", "Snooze 10 min"),
                                          options: [])
        let category = UNNotificationCategory(identifier: Self.warningCategoryID,
                                              actions: [cancel, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self

        // 挂 .common mode：菜单跟踪等交互期间倒计时也不停更
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // 只读取当前通知状态；首次授权改在开始计时或用户主动点击时请求
        refreshNotificationPermission()
        log("launched (dry-run=\(isDryRun))")
    }

    // MARK: 对外操作

    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        requestNotificationAuthorizationIfNeeded { [weak self] in
            self?.beginTimer(duration: seconds, source: "countdown")
        }
    }

    func start(atLocalHour hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return }
        requestNotificationAuthorizationIfNeeded { [weak self] in
            guard let self = self else { return }
            guard let target = ScheduleResolver.nextOccurrence(hour: hour, minute: minute) else {
                self.statusMessage = L10n.t("无法计算指定时间", "無法計算指定時間", "Could not resolve the selected time")
                return
            }
            self.beginTimer(duration: target.timeIntervalSinceNow,
                            source: "scheduled-local \(String(format: "%02d:%02d", hour, minute))")
        }
    }

    private func beginTimer(duration: TimeInterval, source: String) {
        guard duration > 0 else { return }
        timerSessionID = UUID()
        let now = Date()
        deadline = now.addingTimeInterval(duration)
        continuousDeadline = continuousClock.now.advanced(by: .seconds(duration))
        remaining = duration
        warned = false
        statusMessage = nil
        phase = .running
        clearReminderArtifacts()
        log("timer started: \(action.rawValue) in \(Int(duration))s from \(source) (warn-lead \(warnLeadSeconds)s, strength \(reminderStrength.rawValue))")
    }

    func pause() {
        guard phase == .running else { return }
        timerSessionID = UUID()
        pausedRemaining = max(0, continuousRemaining() ?? remaining)
        continuousDeadline = nil
        phase = .paused
        clearReminderArtifacts()
        log("paused at \(formatInterval(pausedRemaining))")
    }

    func resume() {
        guard phase == .paused else { return }
        timerSessionID = UUID()
        deadline = Date().addingTimeInterval(pausedRemaining)
        continuousDeadline = continuousClock.now.advanced(by: .seconds(pausedRemaining))
        remaining = pausedRemaining
        // 若恢复后已进入预警窗口则不再重复提醒
        warned = warnLeadSeconds > 0 && remaining <= TimeInterval(warnLeadSeconds)
        phase = .running
        log("resumed with \(formatInterval(remaining)) left")
    }

    func cancel() {
        let wasRunning = phase != .idle
        reset()
        if wasRunning {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            log("timer cancelled")
        }
    }

    func snooze(minutes: Int = TimerModel.snoozeMinutes) {
        let extra = TimeInterval(minutes * 60)
        switch phase {
        case .running:
            guard let currentContinuousDeadline = continuousDeadline else { return }
            timerSessionID = UUID()
            continuousDeadline = currentContinuousDeadline.advanced(by: .seconds(extra))
            remaining = max(0, continuousRemaining() ?? (remaining + extra))
            deadline = Date().addingTimeInterval(remaining)
            warned = false
            clearReminderArtifacts()
            log("snoozed +\(minutes)min, deadline now \(String(describing: deadline))")
        case .paused:
            timerSessionID = UUID()
            pausedRemaining += extra
            clearReminderArtifacts()
            log("snoozed (paused) +\(minutes)min")
        case .idle:
            break
        }
    }

    /// 面板「立即执行」按钮
    func executeNow() {
        let act = action
        reset()
        log("execute-now requested: \(act.rawValue)")
        executePowerAction(act)
    }

    /// 面板展示的当前剩余时长文本（运行/暂停通用）
    var displayRemaining: String {
        switch phase {
        case .running: return formatInterval(remaining)
        case .paused: return formatInterval(pausedRemaining)
        case .idle: return formatInterval(0)
        }
    }

    /// 根据连续计时的剩余量换算为当前系统日历中的预计执行时刻。
    /// 用户中途修改系统时钟或时区后，倒计时不跳变，但这个展示时间会随之更新。
    var expectedFireDate: Date? {
        guard phase == .running else { return nil }
        return Date().addingTimeInterval(max(0, continuousRemaining() ?? remaining))
    }

    // MARK: 内部计时

    private func reset() {
        timerSessionID = UUID()
        phase = .idle
        deadline = nil
        continuousDeadline = nil
        remaining = 0
        pausedRemaining = 0
        warned = false
        // 清掉已送达和待发送的预警，其按钮在 idle 下已无意义
        clearReminderArtifacts()
    }

    private func clearReminderArtifacts() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.enhancedFollowUpID,
            Self.testReminderID,
            Self.enhancedTestFollowUpID
        ])
        fallbackReminderWorkItem?.cancel()
        fallbackReminderWorkItem = nil
        fallbackSound?.stop()
    }

    private func tick() {
        guard phase == .running, deadline != nil,
              let rem = continuousRemaining() else { return }
        if rem <= 0 {
            remaining = 0
            fire(lateness: -rem)
            return
        }
        remaining = rem
        // 语义：「提前 N 提醒」= 剩余 N 时提醒；计时总长 ≤ N 时，开始后立即提醒（尽最大提前量）
        let lead = TimeInterval(warnLeadSeconds)
        if lead > 0, !warned, rem <= lead {
            warned = true
            sendWarning(remaining: rem)
        }
    }

    private func fire(lateness: TimeInterval) {
        let act = action
        reset()
        if lateness > Self.maxLatenessGrace {
            // 计时终点在系统休眠/合盖期间已过去很久：醒来后立即关机/睡眠过于突兀，跳过并提示
            statusMessage = L10n.t("计时在系统休眠期间已过期，本次已跳过执行",
                                   "計時在系統休眠期間已過期，本次已跳過執行",
                                   "Timer expired while the Mac was asleep; action skipped")
            log("fired but late by \(Int(lateness))s (> \(Int(Self.maxLatenessGrace))s grace) — skipped")
            postNotification(
                title: "\(L10n.appName)",
                body: L10n.t("计时在系统休眠期间已过期，本次已跳过执行。",
                             "計時在系統休眠期間已過期，本次已跳過執行。",
                             "The timer expired while the Mac was asleep; the action was skipped."),
                categoryID: nil)
            return
        }
        executePowerAction(act)
    }

    private func continuousRemaining() -> TimeInterval? {
        guard let continuousDeadline = continuousDeadline else { return nil }
        let components = continuousClock.now.duration(to: continuousDeadline).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private func executePowerAction(_ act: PowerAction) {
        if isDryRun {
            statusMessage = L10n.t("[模拟执行] ", "[模擬執行] ", "[Simulated] ") + act.label
            log("DRY-RUN: would \(act.rawValue)")
            return
        }
        switch act {
        case .sleep:
            runProcess("/usr/bin/pmset", arguments: ["sleepnow"]) { [weak self] ok, detail in
                guard let self = self else { return }
                if ok {
                    self.log("sleep command completed (pmset sleepnow)")
                } else {
                    let reason = L10n.t("睡眠命令执行失败：", "睡眠指令執行失敗：", "Sleep command failed: ")
                        + detail
                    self.statusMessage = reason
                    self.log("pmset failed: \(detail)")
                    self.postNotification(title: L10n.appName, body: reason, categoryID: nil)
                }
            }
        case .shutdown:
            // 后台执行：标准 macOS 首次触发的「自动化」授权弹窗可能等很久，不能阻塞主线程/UI
            runAppleScript("tell application \"System Events\" to shut down") { [weak self] ok, detail in
                guard let self = self else { return }
                if ok {
                    self.log("shutdown command issued via System Events (osascript)")
                } else {
                    let reason = L10n.t(
                        "关机失败：可能未授权「自动化」权限，或授权弹窗超时未确认。",
                        "關機失敗：可能未授權「自動化」權限，或授權視窗逾時未確認。",
                        "Shut-down failed: Automation permission missing or the approval prompt timed out.")
                    self.statusMessage = reason
                    self.log("shutdown failed: \(detail)")
                    self.postNotification(
                        title: L10n.appName,
                        body: reason + " " + L10n.t("可点菜单栏月亮图标重试。",
                                                    "可點選單列月亮圖示重試。",
                                                    "Retry from the moon icon in the menu bar."),
                        categoryID: nil)
                }
            }
        }
    }

    /// 在后台执行短命令，捕获退出码和错误文本，回调回主线程
    private func runProcess(_ executable: String,
                            arguments: [String],
                            completion: @escaping (_ ok: Bool, _ detail: String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            let errPipe = Pipe()
            p.standardError = errPipe
            do {
                try p.run()
                p.waitUntilExit()
                let stderrText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let exitCode = p.terminationStatus
                let stderrDetail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail: String
                if exitCode == 0 {
                    detail = stderrDetail
                } else {
                    let exitDetail = L10n.t("退出码 \(exitCode)", "結束代碼 \(exitCode)", "exit code \(exitCode)")
                    detail = stderrDetail.isEmpty ? exitDetail : "\(exitDetail): \(stderrDetail)"
                }
                DispatchQueue.main.async {
                    completion(exitCode == 0, detail)
                }
            } catch {
                DispatchQueue.main.async { completion(false, "\(error)") }
            }
        }
    }

    /// 经 /usr/bin/osascript 执行真实动作；Automation 权限由预检 API 另行处理
    private func runAppleScript(_ source: String, completion: @escaping (_ ok: Bool, _ detail: String) -> Void) {
        runProcess("/usr/bin/osascript", arguments: ["-e", source], completion: completion)
    }

    // MARK: 权限

    func refreshPermissionStatuses() {
        permissionCheckPerformed = true
        refreshNotificationPermission()
        checkAutomationPermission(askUserIfNeeded: false)
    }

    func requestNotificationPermission() {
        permissionCheckPerformed = true
        requestNotificationAuthorizationIfNeeded()
    }

    /// 用户切到关机时，预检真正的 System Events「shut down」事件；不会执行关机
    func warmUpShutdownPermission() {
        guard !isDryRun else { return }
        requestAutomationPermission()
    }

    func requestAutomationPermission() {
        permissionCheckPerformed = true
        checkAutomationPermission(askUserIfNeeded: true)
    }

    private func checkAutomationPermission(askUserIfNeeded: Bool) {
        automationPermission = .checking
        ensureSystemEventsRunning { [weak self] running in
            guard let self = self else { return }
            guard running else {
                self.automationPermission = .unavailable
                self.log("automation permission check unavailable: System Events could not launch")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.determineAutomationPermission(askUserIfNeeded: askUserIfNeeded)
                DispatchQueue.main.async {
                    self.automationPermission = result.state
                    self.log("automation permission check: \(String(describing: result.state)) (status \(result.status))")
                    if askUserIfNeeded && result.state == .denied {
                        self.statusMessage = L10n.t(
                            "关机控制已被拒绝，请在“系统设置 → 隐私与安全性 → 自动化”中允许 Time.Sleep。",
                            "關機控制已被拒絕，請在「系統設定 → 隱私權與安全性 → 自動化」中允許 Time.Sleep。",
                            "Shut-down control was denied. Allow Time.Sleep in System Settings → Privacy & Security → Automation.")
                    }
                }
            }
        }
    }

    private func ensureSystemEventsRunning(completion: @escaping (Bool) -> Void) {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.systemEventsBundleID).isEmpty {
            completion(true)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.systemEventsBundleID) else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                completion(app != nil && error == nil)
            }
        }
    }

    private func determineAutomationPermission(askUserIfNeeded: Bool) -> (state: PermissionState, status: OSStatus) {
        var target = AEAddressDesc()
        let bundleIDData = Data(Self.systemEventsBundleID.utf8)
        let createError: OSErr = bundleIDData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard createError == 0 else { return (.unavailable, OSStatus(createError)) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(Self.fourCharCode("fndr")),
            AEEventID(Self.fourCharCode("shut")),
            askUserIfNeeded)
        if status == noErr {
            return (.allowed, status)
        } else if status == OSStatus(errAEEventWouldRequireUserConsent) {
            return (.notDetermined, status)
        } else if status == OSStatus(errAEEventNotPermitted) {
            return (.denied, status)
        } else {
            return (.unavailable, status)
        }
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    // MARK: 通知

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.applyNotificationSettings(settings)
            }
        }
    }

    private func applyNotificationSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            notificationPermission = .allowed
        case .denied:
            notificationPermission = .denied
        case .notDetermined:
            notificationPermission = .notDetermined
        @unknown default:
            notificationPermission = .unavailable
        }
        notificationAlertEnabled = settings.alertSetting == .enabled
        notificationSoundEnabled = settings.soundSetting == .enabled
    }

    private func requestNotificationAuthorizationIfNeeded(completion: @escaping () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .notDetermined else {
                DispatchQueue.main.async {
                    self.applyNotificationSettings(settings)
                    completion()
                }
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                center.getNotificationSettings { updated in
                    DispatchQueue.main.async {
                        self.applyNotificationSettings(updated)
                        if let error = error {
                            self.log("notification auth error: \(error)")
                        } else if !granted {
                            self.log("notification authorization denied by user")
                        } else {
                            self.log("notification authorization granted")
                        }
                        completion()
                    }
                }
            }
        }
    }

    func sendTestReminder() {
        requestNotificationAuthorizationIfNeeded { [weak self] in
            guard let self = self else { return }
            if self.notificationPermission == .allowed {
                let enhanced = self.reminderStrength == .enhanced
                let center = UNUserNotificationCenter.current()
                let testIDs = [Self.testReminderID, Self.enhancedTestFollowUpID]
                center.removePendingNotificationRequests(withIdentifiers: testIDs)
                center.removeDeliveredNotifications(withIdentifiers: testIDs)
                self.postNotification(
                    title: "\(L10n.appName) · \(L10n.t("测试提醒", "測試提醒", "Test Reminder"))",
                    body: L10n.t("这是提醒效果预览，不会执行睡眠或关机。",
                                 "這是提醒效果預覽，不會執行睡眠或關機。",
                                 "This is a reminder preview. It will not sleep or shut down your Mac."),
                    categoryID: nil,
                    identifier: Self.testReminderID,
                    enhanced: enhanced)
                if enhanced {
                    self.scheduleEnhancedTestFollowUp()
                    self.statusMessage = L10n.t(
                        "测试提醒已发送；15 秒后会再次提醒",
                        "測試提醒已傳送；15 秒後會再次提醒",
                        "Test reminder sent; another will follow in 15 seconds")
                } else {
                    self.statusMessage = L10n.t("测试提醒已发送", "測試提醒已傳送", "Test reminder sent")
                }
                self.log("test reminder sent (strength \(self.reminderStrength.rawValue))")
            } else {
                self.playFallbackReminder(enhanced: self.reminderStrength == .enhanced, repeatOnce: false)
                self.statusMessage = L10n.t("通知未允许，已播放本地提示音",
                                            "通知未允許，已播放本機提示音",
                                            "Notifications are not allowed; played the local alert sound")
                self.log("test reminder used local sound because notifications are unavailable")
            }
        }
    }

    private func sendWarning(remaining rem: TimeInterval) {
        guard let warningDeadline = deadline else { return }
        let warningSessionID = timerSessionID
        log("warning notification at \(formatInterval(rem)) before deadline")
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard self.phase == .running,
                      self.timerSessionID == warningSessionID,
                      self.deadline == warningDeadline,
                      warningDeadline.timeIntervalSinceNow > 0 else {
                    self.log("discarded stale warning callback")
                    return
                }
                self.applyNotificationSettings(settings)
                if granted {
                    let act = self.action
                    let human = self.humanRemainder(rem)
                    let bodyZhHans = "Mac 将在 \(human)后\(act.label)，如需继续使用请取消或顺延。"
                    let bodyZhHant = "Mac 將在 \(human)後\(act.label)，如需繼續使用請取消或順延。"
                    let bodyEn = "Your Mac will \(act == .sleep ? "sleep" : "shut down") in \(human). Cancel or snooze if you are still working."
                    let enhanced = self.reminderStrength == .enhanced
                    self.postNotification(title: "\(L10n.appName) · \(act.label)",
                                          body: L10n.t(bodyZhHans, bodyZhHant, bodyEn),
                                          categoryID: TimerModel.warningCategoryID,
                                          enhanced: enhanced)
                    if enhanced {
                        self.scheduleEnhancedFollowUp(for: act)
                    }
                } else {
                    // 未授权通知时至少播放本地声音；增强模式再重复一次
                    self.playFallbackReminder(enhanced: self.reminderStrength == .enhanced, repeatOnce: true)
                    self.log("warning: notifications not authorized, played local reminder instead")
                }
            }
        }
    }

    private func scheduleEnhancedFollowUp(for act: PowerAction) {
        let body = L10n.t(
            "再次提醒：计时仍在进行，Mac 即将\(act.label)，如需继续使用请取消或顺延。",
            "再次提醒：計時仍在進行，Mac 即將\(act.label)，如需繼續使用請取消或順延。",
            "Reminder: the timer is still running and your Mac will soon \(act == .sleep ? "sleep" : "shut down"). Cancel or snooze if needed.")
        postNotification(
            title: "\(L10n.appName) · \(L10n.t("再次提醒", "再次提醒", "Reminder"))",
            body: body,
            categoryID: Self.warningCategoryID,
            identifier: Self.enhancedFollowUpID,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15, repeats: false),
            enhanced: true)
    }

    private func scheduleEnhancedTestFollowUp() {
        postNotification(
            title: "\(L10n.appName) · \(L10n.t("再次测试提醒", "再次測試提醒", "Second Test Reminder"))",
            body: L10n.t(
                "这是增强模式的第二次测试提醒，仍不会执行睡眠或关机。",
                "這是增強模式的第二次測試提醒，仍不會執行睡眠或關機。",
                "This is the second enhanced test reminder. It still will not sleep or shut down your Mac."),
            categoryID: nil,
            identifier: Self.enhancedTestFollowUpID,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15, repeats: false),
            enhanced: true)
    }

    private func playFallbackReminder(enhanced: Bool, repeatOnce: Bool) {
        guard enhanced,
              let url = Bundle.main.url(forResource: "TimeSleepAlert", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep()
            return
        }
        fallbackSound?.stop()
        fallbackSound = sound
        sound.play()
        guard repeatOnce else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.phase == .running else { return }
            self.fallbackSound?.stop()
            self.fallbackSound?.play()
        }
        fallbackReminderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func postNotification(title: String,
                                  body: String,
                                  categoryID: String?,
                                  identifier: String? = nil,
                                  trigger: UNNotificationTrigger? = nil,
                                  enhanced: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if enhanced {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "TimeSleepAlert.wav"))
        } else {
            content.sound = .default
        }
        // 本地构建使用 ad-hoc 签名，不能携带受限制的 Time Sensitive entitlement。
        // 增强模式依靠自定义声音与 15 秒二次提醒；正式签名发行版再单独评估 Time Sensitive。
        content.interruptionLevel = .active
        if let categoryID = categoryID { content.categoryIdentifier = categoryID }
        let request = UNNotificationRequest(identifier: identifier ?? "timesleep-\(UUID().uuidString)",
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async { self?.log("post notification failed: \(error)") }
            }
        }
    }

    /// 人性化剩余时间（用于通知文案，三语自适应）
    private func humanRemainder(_ rem: TimeInterval) -> String {
        let s = Int(rem.rounded())
        if s < 60 { return L10n.t("不到 1 分钟", "不到 1 分鐘", "less than a minute") }
        let m = Int((s + 59) / 60)
        return L10n.t("\(m) 分钟", "\(m) 分鐘", "\(m) min")
    }

    // MARK: 格式化

    func formatInterval(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: 日志（~/Library/Logs/Time.Sleep.log）

    func log(_ message: String) {
        let line = "\(logISO.string(from: Date())) [Time.Sleep] \(message)\n"
        print(line.trimmingCharacters(in: .whitespacesAndNewlines))
        logQueue.async {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Time.Sleep.log")
            let fm = FileManager.default
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000 {
                try? fm.removeItem(at: url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                fm.createFile(atPath: url.path, contents: data)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // 应用处于前台时也弹出横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 通知按钮回调
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self = self else { return }
            switch identifier {
            case TimerModel.actionCancelID:
                self.cancel()
            case TimerModel.actionSnoozeID:
                self.snooze()
            default:
                break
            }
        }
    }
}

// MARK: - App 入口

@main
struct TimeSleepApp: App {
    @StateObject private var model = TimerModel()

    var body: some Scene {
        MenuBarExtra(content: {
            PanelView().environmentObject(model)
        }, label: {
            HStack(spacing: 5) {
                Image(systemName: model.phase == .running ? "moon.zzz.fill" : "moon.fill")
                if model.phase != .idle {
                    Text(model.displayRemaining).monospacedDigit()
                }
            }
        })
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 面板视图

struct PanelView: View {
    @EnvironmentObject var model: TimerModel
    @AppStorage(DefaultsKeys.action) private var actionRaw: String = PowerAction.sleep.rawValue
    @AppStorage(DefaultsKeys.warnLeadSeconds) private var warnLead: Int = 60
    @AppStorage(DefaultsKeys.reminderStrength) private var reminderStrengthRaw: String = ReminderStrength.enhanced.rawValue
    @AppStorage(DefaultsKeys.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(DefaultsKeys.lastHours) private var hours: Int = 0
    @AppStorage(DefaultsKeys.lastMinutes) private var minutes: Int = 30
    @AppStorage(DefaultsKeys.lastSeconds) private var seconds: Int = 0
    @AppStorage(DefaultsKeys.timerInputMode) private var timerInputModeRaw: String = TimerInputMode.countdown.rawValue
    @AppStorage(DefaultsKeys.scheduledHour) private var scheduledHour: Int = 23
    @AppStorage(DefaultsKeys.scheduledMinute) private var scheduledMinute: Int = 0
    @State private var settingsExpanded = false

    var body: some View {
        VStack(spacing: 14) {
            header

            switch model.phase {
            case .idle:
                idleSetup
            case .running:
                runningView
            case .paused:
                pausedView
            }

            settingsSection
            quitBar
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            // 同步登录项开关与系统真实状态（含「已注册待批准」；SMAppService 可能被用户在系统设置里改过）
            let status = SMAppService.mainApp.status
            launchAtLogin = (status == .enabled || status == .requiresApproval)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            Text(L10n.appName).font(.headline)
            Spacer()
            if let msg = model.statusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }

    // MARK: 空闲：设置倒计时或指定时间

    private var idleSetup: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("计时方式", "計時方式", "Timer mode"))
                Picker(L10n.t("计时方式", "計時方式", "Timer mode"), selection: $timerInputModeRaw) {
                    Text(L10n.t("倒计时", "倒數計時", "Countdown")).tag(TimerInputMode.countdown.rawValue)
                    Text(L10n.t("指定时间", "指定時間", "At Time")).tag(TimerInputMode.scheduledTime.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if timerInputMode == .countdown {
                HStack(spacing: 10) {
                    TimeColumn(value: $hours, range: 0...23, unit: L10n.t("时", "時", "hrs"))
                    TimeColumn(value: $minutes, range: 0...59, unit: L10n.t("分", "分", "min"))
                    TimeColumn(value: $seconds, range: 0...59, unit: L10n.t("秒", "秒", "sec"))
                }

                HStack(spacing: 8) {
                    presetButton(30 * 60, hans: "30 分钟", hant: "30 分鐘", en: "30 min")
                    presetButton(60 * 60, hans: "1 小时", hant: "1 小時", en: "1 hr")
                    presetButton(2 * 60 * 60, hans: "2 小时", hant: "2 小時", en: "2 hrs")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("执行时间", "執行時間", "Action time"))
                    HStack {
                        Spacer()
                        DatePicker(L10n.t("执行时间", "執行時間", "Action time"),
                                   selection: scheduledTimeBinding,
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(width: 140)
                            .clipped()
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(nextScheduleDescription(relativeTo: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker(L10n.t("到点动作", "到點動作", "Action"), selection: $actionRaw) {
                Text(L10n.sleepText).tag(PowerAction.sleep.rawValue)
                Text(L10n.shutdownText).tag(PowerAction.shutdown.rawValue)
            }
            .pickerStyle(.segmented)
            .onChange(of: actionRaw) { _, newValue in
                // 切到关机就预热「自动化」授权（若系统需要），让弹窗在用户在场时出现
                if newValue == PowerAction.shutdown.rawValue {
                    model.warmUpShutdownPermission()
                }
            }

            Button {
                switch timerInputMode {
                case .countdown:
                    let total = hours * 3600 + minutes * 60 + seconds
                    guard total > 0 else {
                        model.statusMessage = L10n.t("请先设置时长", "請先設定時長", "Set a duration first")
                        return
                    }
                    model.start(seconds: TimeInterval(total))
                case .scheduledTime:
                    model.start(atLocalHour: scheduledHour, minute: scheduledMinute)
                }
            } label: {
                Text(L10n.t("开始计时", "開始計時", "Start Timer"))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func presetButton(_ secs: Int, hans: String, hant: String, en: String) -> some View {
        Button {
            model.start(seconds: TimeInterval(secs))
        } label: {
            Text(L10n.t(hans, hant, en))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: 运行中

    private var runningView: some View {
        VStack(spacing: 12) {
            Text(model.displayRemaining)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(runningDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(L10n.t("暂停", "暫停", "Pause")) { model.pause() }
                Button(L10n.t("顺延 10 分钟", "順延 10 分鐘", "Snooze 10 min")) { model.snooze() }
                Button(L10n.t("取消", "取消", "Cancel")) { model.cancel() }
            }
            .controlSize(.large)

            Button {
                model.executeNow()
            } label: {
                Text(L10n.t("立即", "立即", "Do it now: ") + currentActionLabel)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    // MARK: 暂停

    private var pausedView: some View {
        VStack(spacing: 12) {
            Text(model.displayRemaining)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(L10n.t("已暂停", "已暫停", "Paused"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(L10n.t("继续", "繼續", "Resume")) { model.resume() }
                Button(L10n.t("顺延 10 分钟", "順延 10 分鐘", "Snooze 10 min")) { model.snooze() }
                Button(L10n.t("取消", "取消", "Cancel")) { model.cancel() }
            }
            .controlSize(.large)

            Button {
                model.executeNow()
            } label: {
                Text(L10n.t("立即", "立即", "Do it now: ") + currentActionLabel)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    // MARK: 设置区

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    settingsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(L10n.t("设置", "設定", "Settings"))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(settingsExpanded
                ? L10n.t("已展开", "已展開", "Expanded")
                : L10n.t("已折叠", "已摺疊", "Collapsed"))

            if settingsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.t("提前提醒", "提前提醒", "Warn before"), selection: $warnLead) {
                        Text(L10n.t("关闭", "關閉", "Off")).tag(0)
                        Text(L10n.t("30 秒", "30 秒", "30 sec")).tag(30)
                        Text(L10n.t("1 分钟", "1 分鐘", "1 min")).tag(60)
                        Text(L10n.t("2 分钟", "2 分鐘", "2 min")).tag(120)
                        Text(L10n.t("5 分钟", "5 分鐘", "5 min")).tag(300)
                        Text(L10n.t("10 分钟", "10 分鐘", "10 min")).tag(600)
                    }
                    Picker(L10n.t("提醒强度", "提醒強度", "Reminder strength"), selection: $reminderStrengthRaw) {
                        Text(L10n.t("标准", "標準", "Standard")).tag(ReminderStrength.standard.rawValue)
                        Text(L10n.t("增强", "增強", "Enhanced")).tag(ReminderStrength.enhanced.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        model.sendTestReminder()
                    } label: {
                        Label(L10n.t("测试提醒", "測試提醒", "Test Reminder"), systemImage: "bell.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Toggle(L10n.t("登录时启动", "登入時啟動", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            setLoginItem(enabled)
                        }
                    Divider()
                    Button {
                        model.refreshPermissionStatuses()
                    } label: {
                        Label(L10n.t("权限自检", "權限自我檢查", "Permission Check"),
                              systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if model.permissionCheckPerformed {
                        permissionReport
                    }
                    if model.isDryRun {
                        Label(L10n.t("Dry-run 模式：只记日志，不执行动作",
                                     "Dry-run 模式：只記日誌，不執行動作",
                                     "Dry-run mode: logs only, no action"),
                              systemImage: "ladybug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 18)
            }
        }
        .font(.callout)
    }

    private var quitBar: some View {
        HStack {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L10n.t("退出 Time.Sleep", "結束 Time.Sleep", "Quit Time.Sleep"))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 辅助

    private var timerInputMode: TimerInputMode {
        TimerInputMode(rawValue: timerInputModeRaw) ?? .countdown
    }

    private var scheduledTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.autoupdatingCurrent.date(bySettingHour: scheduledHour,
                                                  minute: scheduledMinute,
                                                  second: 0,
                                                  of: Date()) ?? Date()
            },
            set: { newValue in
                let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: newValue)
                scheduledHour = components.hour ?? scheduledHour
                scheduledMinute = components.minute ?? scheduledMinute
            }
        )
    }

    private var runningDescription: String {
        let target = model.expectedFireDate.map { targetTimeText($0) }
            ?? L10n.t("未知时间", "未知時間", "unknown time")
        return L10n.t("预计 \(target) · \(currentActionLabel) · \(warnLeadDesc)",
                      "預計 \(target) · \(currentActionLabel) · \(warnLeadDesc)",
                      "Expected \(target) · \(currentActionLabel) · \(warnLeadDesc)")
    }

    private func nextScheduleDescription(relativeTo now: Date) -> String {
        guard let target = ScheduleResolver.nextOccurrence(hour: scheduledHour,
                                                            minute: scheduledMinute,
                                                            after: now) else {
            return L10n.t("无法计算下一次时间", "無法計算下一次時間", "Could not resolve the next time")
        }
        return L10n.t("下一次：\(targetTimeText(target, relativeTo: now))",
                      "下一次：\(targetTimeText(target, relativeTo: now))",
                      "Next: \(targetTimeText(target, relativeTo: now))")
    }

    private func targetTimeText(_ date: Date, relativeTo now: Date = Date()) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = localizedTime(date)
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("今天 \(time)", "今日 \(time)", "today at \(time)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.t("明天 \(time)", "明日 \(time)", "tomorrow at \(time)")
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func localizedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        // `j` follows the user's 12/24-hour system preference and adds AM/PM when appropriate.
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    private var currentActionLabel: String {
        (PowerAction(rawValue: actionRaw) ?? .sleep).label
    }

    private var warnLeadDesc: String {
        if warnLead <= 0 { return L10n.t("不提醒", "不提醒", "no warning") }
        let unit = warnLead % 60 == 0
            ? L10n.t("分钟", "分鐘", "min")
            : L10n.t("秒", "秒", "sec")
        let value = warnLead % 60 == 0 ? warnLead / 60 : warnLead
        return L10n.t("提前 \(value) \(unit) 提醒", "提前 \(value) \(unit) 提醒", "warns \(value) \(unit) ahead")
    }

    private var permissionReport: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow(L10n.t("通知权限", "通知權限", "Notifications"),
                          value: permissionStateText(model.notificationPermission))
            if model.notificationPermission == .allowed {
                permissionRow(L10n.t("通知显示", "通知顯示", "Notification alerts"),
                              value: enabledText(model.notificationAlertEnabled))
                permissionRow(L10n.t("通知声音", "通知聲音", "Notification sound"),
                              value: enabledText(model.notificationSoundEnabled))
            }
            if model.notificationPermission == .notDetermined {
                Button(L10n.t("启用通知", "啟用通知", "Enable Notifications")) {
                    model.requestNotificationPermission()
                }
            } else if model.notificationPermission == .denied {
                Text(L10n.t("请在“系统设置 → 通知 → Time.Sleep”中重新允许。",
                            "請在「系統設定 → 通知 → Time.Sleep」中重新允許。",
                            "Re-enable Time.Sleep in System Settings → Notifications."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            permissionRow(L10n.t("关机控制", "關機控制", "Shut-down control"),
                          value: permissionStateText(model.automationPermission))
            if model.automationPermission == .notDetermined {
                Button(L10n.t("请求关机权限", "要求關機權限", "Request Shut-down Permission")) {
                    model.requestAutomationPermission()
                }
            } else if model.automationPermission == .denied {
                Text(L10n.t("请在“系统设置 → 隐私与安全性 → 自动化”中允许 Time.Sleep。",
                            "請在「系統設定 → 隱私權與安全性 → 自動化」中允許 Time.Sleep。",
                            "Allow Time.Sleep in System Settings → Privacy & Security → Automation."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            permissionRow(L10n.t("睡眠动作", "睡眠動作", "Sleep action"),
                          value: L10n.t("无需额外权限", "無需額外權限", "No extra permission"))
            permissionRow(L10n.t("登录启动", "登入啟動", "Launch at login"), value: loginItemStatusText)
        }
        .font(.caption)
    }

    private func permissionRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func permissionStateText(_ state: PermissionState) -> String {
        switch state {
        case .unknown: return L10n.t("未检查", "未檢查", "Not checked")
        case .checking: return L10n.t("检查中…", "檢查中…", "Checking…")
        case .allowed: return L10n.t("已允许", "已允許", "Allowed")
        case .notDetermined: return L10n.t("尚未询问", "尚未詢問", "Not requested")
        case .denied: return L10n.t("已拒绝", "已拒絕", "Denied")
        case .unavailable: return L10n.t("无法检查", "無法檢查", "Unavailable")
        }
    }

    private func enabledText(_ enabled: Bool) -> String {
        enabled ? L10n.t("开启", "開啟", "On") : L10n.t("关闭", "關閉", "Off")
    }

    private var loginItemStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return L10n.t("已启用", "已啟用", "Enabled")
        case .requiresApproval:
            return L10n.t("等待系统批准", "等待系統批准", "Needs approval")
        case .notRegistered:
            return L10n.t("未启用", "未啟用", "Off")
        case .notFound:
            return L10n.t("不可用", "無法使用", "Unavailable")
        @unknown default:
            return L10n.t("未知", "未知", "Unknown")
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        // 登录项绑定 app 当前路径：必须先装进 /Applications 再开启，否则以后移动/重建就失效
        if enabled && !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            model.statusMessage = L10n.t(
                "请先把 Time.Sleep 放入 /Applications 再开启登录启动",
                "請先把 Time.Sleep 放入 /Applications 再開啟登入啟動",
                "Copy Time.Sleep to /Applications before enabling launch at login")
            model.log("login item rejected: app not in /Applications (\(Bundle.main.bundlePath))")
            launchAtLogin = false
            return
        }
        do {
            let status = SMAppService.mainApp.status
            let isOn = (status == .enabled || status == .requiresApproval)
            if enabled && !isOn {
                try SMAppService.mainApp.register()
                model.log("login item registered")
            } else if !enabled && isOn {
                try SMAppService.mainApp.unregister()
                model.log("login item unregistered")
            }
        } catch {
            model.statusMessage = L10n.t("登录启动设置失败：", "登入項設定失敗：", "Failed to set login item: ")
                + error.localizedDescription
            model.log("SMAppService error: \(error)")
            DispatchQueue.main.async {
                let status = SMAppService.mainApp.status
                launchAtLogin = (status == .enabled || status == .requiresApproval)
            }
        }
    }
}

// MARK: - 时/分/秒 步进列（macOS 时钟 App 风格：数字 + 上下箭头）

private struct TimeColumn: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Stepper(value: $value, in: range) {
                Text(String(format: "%02d", value))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .fixedSize()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
