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
        win.minSize = NSSize(width: 760, height: 480)
        win.contentView = NSHostingView(rootView: ContentView(settings: model.settings).environmentObject(model))
        win.center()
        win.setFrameAutosaveName("PolyTranslateLive.Main")
        win.makeKeyAndOrderFront(nil)
        window = win
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
