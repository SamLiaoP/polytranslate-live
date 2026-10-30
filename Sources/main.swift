import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = tr("app.title")
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.095, alpha: 1)
        win.minSize = NSSize(width: 360, height: 240)   // 四分之一螢幕也放得下，介面會跟著縮
        win.contentView = NSHostingView(rootView: ContentView(settings: model.settings).environmentObject(model))
        win.center()
        window = win
        if !snapshotIfRequested() {
            win.setFrameAutosaveName("PolyTranslateLive.Main")
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 介面語言改變時重建選單與視窗標題。
        model.settings.$data.map(\.uiLanguage).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.buildMenu()
                self?.window?.title = tr("app.title")
            }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `--snapshot 640x400 /path/out.png`：開指定大小的視窗、塞幾句範例字幕、兩秒後存成 PNG 結束。
    /// 給沒有螢幕錄製權限的終端機（或 AI 助理）檢查各種視窗大小的版面用。不會動到使用者存的視窗位置。
    private func snapshotIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count, let win = window else { return false }
        let dims = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard dims.count == 2 else { return false }
        let out = URL(fileURLWithPath: args[i + 2])
        if i + 3 < args.count, ["running", "paused"].contains(args[i + 3]) {
            model.previewRunningForSnapshot(paused: args[i + 3] == "paused")
        }
        let mode = i + 3 < args.count ? args[i + 3] : ""
        // 側欄用假資料：截圖會放上 README，不能露出使用者真正的會議內容。
        model.history.replaceForSnapshot(Self.sampleSessions())
        if mode == "history" { model.selectedSession = model.history.sessions.first }
        if mode == "settings" { model.showSettings = true }
        win.setContentSize(NSSize(width: dims[0], height: dims[1]))
        win.center()
        let samples: [(String, CaptureKind)] = [
            ("Good morning everyone, today we review the quarterly results.", .system),
            ("Revenue grew twelve percent compared to last quarter, mostly from the enterprise tier.", .system),
            ("Can you share the numbers for the APAC region as well?", .microphone),
            ("Sure, the deployment practitioner course is more like a guideline than a technical manual.", .system),
        ]
        for pane in model.panes {
            pane.sessionStarted()
            for (s, k) in samples { pane.receiveFinal(s, from: k) }
            pane.receiveDraft("So what I'm going to do is share the presentation", from: .system)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // 設定頁是 sheet（另一個視窗），要截它的 contentView 而不是主視窗的。
            guard let self, let win = self.window,
                  let view = (mode == "settings" ? win.attachedSheet?.contentView : nil) ?? win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: out) }
            dlog("snapshot saved: \(out.path)")
            exit(0)
        }
        return true
    }

    /// 截圖用的假歷史紀錄：幾場不同日期、長度的英文會議。
    private static func sampleSessions() -> [SessionRecord] {
        let zh = LanguageCatalog.language("zh-Hant"), en = LanguageCatalog.language("en")
        let cal = Calendar.current
        let meetings: [(daysAgo: Int, hour: Int, minutes: Int, lines: [(String, String, CaptureKind)])] = [
            (0, 10, 52, [("Good morning everyone, today we review the quarterly results.", "大家早安，今天我們回顧季度業績。", .system),
                         ("Revenue grew twelve percent compared to last quarter.", "營收比上一季成長了 12%。", .system),
                         ("Can you share the numbers for the APAC region as well?", "可以也分享一下亞太地區的數字嗎？", .microphone),
                         ("Sure, APAC is up eight percent, mostly from new enterprise accounts.", "當然，亞太成長 8%，主要來自新的企業客戶。", .system),
                         ("Let's move on to the hiring plan for the engineering team.", "接下來談工程團隊的徵才計畫。", .system)]),
            (1, 15, 27, [("Let's go through the open issues before the release.", "發布前先把未解決的問題過一遍。", .system),
                         ("The login bug is fixed and waiting for review.", "登入的問題修好了，等審查。", .microphone),
                         ("Great, then we can ship on Thursday.", "很好，那我們週四就能出。", .system)]),
            (3, 9, 41, [("Welcome to the onboarding session for new partners.", "歡迎參加新合作夥伴的入門說明。", .system),
                        ("Today we cover the deployment guideline and the support process.", "今天會講部署指南和支援流程。", .system)]),
            (6, 16, 8, [("Do you need any help with the proposal?", "提案需要幫忙嗎？", .microphone),
                        ("I think the budget section still needs numbers.", "我覺得預算那段還缺數字。", .system)]),
        ]
        return meetings.map { m in
            let start = cal.date(bySettingHour: m.hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -m.daysAgo, to: Date())!)!
            let lines = m.lines.enumerated().map { i, l in
                SessionRecord.Line(id: i, time: start.addingTimeInterval(Double(i) * 47), original: l.0, translated: l.1, source: l.2)
            }
            return SessionRecord(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(Double(m.minutes * 60)),
                                 source: .mixed, target: zh, panes: [.init(language: en, target: zh, lines: lines)], recording: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.settings.flush()
    }

    /// 正在錄的話先停（把最後一句存進歷史），最多等 10 秒；辨識器卡住也不能讓 App 關不掉。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRunning || model.isStarting else { return .terminateNow }
        let model = self.model
        Task {
            if await withTimeout(10, { await model.stop() }) == nil {
                dlog("stop timed out on quit; terminating anyway")
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 沒有主選單的話，文字欄位的 Cmd+C/V 和 Cmd+Q 都不會動。
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("menu.edit"))
        edit.addItem(withTitle: tr("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr("menu.window"))
        windowMenu.addItem(withTitle: tr("menu.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: tr("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        model.showSettings = true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.appearance = NSAppearance(named: .darkAqua)
    app.run()
}
