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
        win.setContentSize(NSSize(width: dims[0], height: dims[1]))
        win.center()
        let samples = ["Good morning everyone, today we review the quarterly results.",
                       "The deployment practitioner course is more like a guideline than a technical manual."]
        for pane in model.panes {
            pane.sessionStarted()
            for s in samples { pane.receiveFinal(s, from: .system) }
            pane.receiveDraft("So what I'm going to do is share the presentation", from: .system)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let view = self.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: out) }
            dlog("snapshot saved: \(out.path)")
            exit(0)
        }
        return true
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
