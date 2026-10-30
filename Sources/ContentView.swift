import AppKit
import SwiftUI
import Translation

// MARK: - 色彩

enum Palette {
    static let window = Color(red: 0.07, green: 0.075, blue: 0.095)
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.07)
    static let pill = Color.white.opacity(0.08)
    static let pillHover = Color.white.opacity(0.12)
    static let translation = Color(red: 1.0, green: 0.78, blue: 0.42)   // 譯文：暖金黃
    static let accentA = Color(red: 0.95, green: 0.45, blue: 0.10)      // 橘
    static let accentB = Color(red: 1.0, green: 0.80, blue: 0.25)       // 金黃
    static var brand: LinearGradient {
        LinearGradient(colors: [accentA, accentB], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}


// MARK: - 版面密度：視窗縮小時整個介面跟著縮

/// 依視窗大小分三級。字幕框是主體，其他東西（標題、控制列、按鈕、字級）隨等級縮小或收進選單。
enum Density { case regular, compact, mini }

struct Layout: Equatable {
    var density: Density = .regular
    var size = CGSize(width: 1240, height: 780)

    static func classify(_ size: CGSize) -> Density {
        if size.width < 560 || size.height < 380 { return .mini }
        if size.width < 900 || size.height < 520 { return .compact }
        return .regular
    }

    private func pick<T>(_ r: T, _ c: T, _ m: T) -> T {
        switch density { case .regular: return r; case .compact: return c; case .mini: return m }
    }
    /// 字幕字級的倍率（乘上設定裡的字級）。
    var fontScale: CGFloat { pick(1, 0.85, 0.7) }
    var outerPad: CGFloat { pick(20, 12, 6) }
    var paneGap: CGFloat { pick(16, 10, 6) }
    var cardRadius: CGFloat { pick(18, 14, 10) }
    var startSize: CGFloat { pick(34, 30, 26) }
    var timerFont: CGFloat { pick(18, 16, 13) }
    var iconButton: CGFloat { pick(34, 28, 24) }
    var topPad: CGFloat { pick(30, 28, 26) }     // 紅綠燈佔的高度
    var headerFont: CGFloat { pick(14, 12, 11) }
    var panePadH: CGFloat { pick(18, 12, 8) }
    var panePadV: CGFloat { pick(16, 10, 6) }
    var lineGap: CGFloat { pick(18, 12, 8) }
    var pillHeight: CGFloat { pick(30, 26, 22) }
    /// 頂部只有一排：正常大小時目標語言、聲音來源、新增欄位直接排在這一排右側；縮小時收進選單。
    /// 標題只在夠寬時顯示，字幕才是重點，上面不佔第二排。
    var showTitle: Bool { density == .regular && size.width >= 1400 }
    var showControlRow: Bool { density == .regular }
    var isMini: Bool { density == .mini }
}

private struct LayoutKey: EnvironmentKey { static let defaultValue = Layout() }

/// 把拿到的空間原封不動交給子視圖；被問「理想大小」時答 0，不去量內容。
/// ScrollView 直接放在 VStack／HStack 裡時，Stack 會先問它的理想高度，ScrollView 只能把 LazyVStack 裡
/// 每一行字幕都量過才答得出來；外面再包幾層 Stack、各問好幾次，就變成指數級，字幕一多主執行緒就卡死
/// （2026-10-28 與 10-30 兩次「當機」都是這個，見 AGENTS.md）。所以字幕捲動區一律包在這裡面。
struct FillLayout: SwiftUI.Layout {   // 這個檔案裡的 `Layout` 是上面的版面參數，所以要寫全名
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// 讓 `.labelStyle(條件 ? A : B)` 能寫在同一行（內建的 label style 型別不同，不能直接三元運算）。
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 文字可選取在 macOS 上每一行都多一層排版成本，即時字幕只在停止後才開；歷史頁一直開。
private struct SelectableText: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
extension EnvironmentValues {
    var layout: Layout {
        get { self[LayoutKey.self] }
        set { self[LayoutKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(density: Layout.classify(geo.size), size: geo.size)
            // 縮到最小時側欄自動收起，不跟字幕框搶寬度；放大回來會再出現。
            let sidebar = settings.data.sidebarVisible && !layout.isMini
            ZStack {
                Palette.window.ignoresSafeArea()
                RadialGradient(colors: [Palette.accentA.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 520)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                HStack(spacing: 0) {
                    if sidebar {
                        HistorySidebar(settings: settings, history: model.history)
                            .frame(width: layout.density == .regular ? 260 : 200)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Rectangle().fill(Palette.cardStroke).frame(width: 1).ignoresSafeArea()
                    }
                    VStack(spacing: 0) {
                        TopBar(settings: settings)
                        if let session = model.selectedSession {
                            HistoryDetail(record: session, settings: settings)
                        } else {
                            if let err = model.globalError {
                                Banner(text: err, kind: .error, dismiss: { model.globalError = nil })
                                    .padding(.horizontal, layout.outerPad)
                                    .padding(.bottom, layout.outerPad / 2)
                            }
                            // 每欄不到 300 pt 寬就改成上下排，字幕框才夠寬。
                            let contentWidth = geo.size.width - (sidebar ? 261 : 0) - layout.outerPad * 2
                            let vertical = layout.isMini || contentWidth / CGFloat(max(1, model.panes.count)) < 300
                            let stack = vertical ? AnyLayout(VStackLayout(spacing: layout.paneGap))
                                                 : AnyLayout(HStackLayout(spacing: layout.paneGap))
                            stack {
                                ForEach(model.panes) { pane in
                                    PaneView(pane: pane, settings: settings)
                                }
                            }
                            .animation(.spring(duration: 0.3), value: model.panes.count)
                            .padding(.horizontal, layout.outerPad)
                            .padding(.bottom, layout.outerPad)
                        }
                    }
                }
                .animation(.spring(duration: 0.3), value: sidebar)
            }
            .environment(\.layout, layout)
        }
        // 最小 360×240：縮到螢幕的四分之一也放得下，其他東西會跟著縮。
        .frame(minWidth: 360, minHeight: 240)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(settings: settings).environmentObject(model)
        }
        .confirmationDialog(tr("history.delete.confirm"),
                            isPresented: Binding(get: { model.sessionPendingDelete != nil },
                                                 set: { if !$0 { model.sessionPendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(tr("history.delete"), role: .destructive) {
                if let r = model.sessionPendingDelete { model.deleteSession(r) }
                model.sessionPendingDelete = nil
            }
            Button(tr("cancel"), role: .cancel) { model.sessionPendingDelete = nil }
        } message: {
            Text(tr("history.delete.note"))
        }
    }
}

// MARK: - 歷史紀錄側欄

private struct HistorySidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("history"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(history.sessions.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 12)

            // 「即時」入口
            SidebarRow(selected: model.selectedSession == nil, action: { model.selectedSession = nil }) {
                HStack(spacing: 8) {
                    Circle().fill(model.isRunning ? Color.green : Color.white.opacity(0.25)).frame(width: 8, height: 8)
                    Text(tr("history.live")).font(.system(size: 13, weight: .medium))
                    Spacer()
                }
            }
            .padding(.horizontal, 10)

            Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.horizontal, 18).padding(.vertical, 8)

            if history.sessions.isEmpty {
                Text(tr("history.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                    .padding(.horizontal, 18)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.sessions) { s in
                            SidebarRow(selected: model.selectedSession?.id == s.id, action: { model.selectedSession = s }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        if s.interrupted == true {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 10)).foregroundStyle(.orange)
                                                .help(tr("history.interrupted.short"))
                                        }
                                    }
                                    HStack(spacing: 6) {
                                        Text(s.panes.map(\.language.name).joined(separator: "・"))
                                        Text("·")
                                        Text(s.durationText).monospacedDigit()
                                        Text("·")
                                        Text(trf("history.lines", s.lineCount))
                                        if s.recording != nil {
                                            Image(systemName: "waveform").accessibilityLabel(tr("recording.badge.help"))
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    if !s.preview.isEmpty {
                                        Text(s.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .contextMenu {
                                Button(tr("history.copy")) { model.copyToPasteboard(s) }
                                if history.recordingURL(for: s) != nil {
                                    Button(tr("recording.save")) { model.saveRecording(s) }
                                    Button(tr("recording.reveal")) { model.revealRecording(s) }
                                }
                                Divider()
                                Button(tr("history.delete"), role: .destructive) { model.sessionPendingDelete = s }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Color.black.opacity(0.18))
    }
}

private struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.pillHover : (hover ? Palette.pill : .clear)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 回看歷史紀錄

private struct HistoryDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    let record: SessionRecord
    @ObservedObject var settings: AppSettings

    private var fontSize: CGFloat { CGFloat(settings.data.fontSize) * layout.fontScale }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.selectedSession = nil } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(tr("history.back")).font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                Text(record.title).font(.system(size: layout.headerFont, weight: .semibold)).lineLimit(1)
                if layout.showTitle {
                    Text("\(record.source.label) · \(record.durationText) · \(trf("history.lines", record.lineCount))")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Spacer()
                // 視窗縮小時只留圖示，把寬度讓給日期標題；滑鼠停上去還是看得到文字。
                let iconOnly = layout.density != .regular
                Button { model.copyToPasteboard(record) } label: {
                    Label(tr("history.copy"), systemImage: "doc.on.doc").font(.system(size: 12, weight: .medium))
                        .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .padding(.horizontal, iconOnly ? 9 : 12).frame(height: 30)
                        .background(Capsule().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .help(tr("history.copy"))
                if model.history.recordingURL(for: record) != nil {
                    Button { model.saveRecording(record) } label: {
                        Label(tr("recording.save"), systemImage: "arrow.down.circle").font(.system(size: 12, weight: .medium))
                            .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                            .padding(.horizontal, iconOnly ? 9 : 12).frame(height: 30)
                            .background(Capsule().fill(Palette.pill))
                    }
                    .buttonStyle(.plain)
                    .help(tr("recording.save"))
                    .contextMenu { Button(tr("recording.reveal")) { model.revealRecording(record) } }
                }
                Button(role: .destructive) { model.sessionPendingDelete = record } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .help(tr("history.delete"))
                .accessibilityLabel(tr("history.delete"))
            }
            .padding(.horizontal, layout.outerPad + 4)
            .padding(.bottom, layout.outerPad / 2)
            if record.interrupted == true {
                Banner(text: trf("history.interrupted", SessionRecord.timeFormatter.string(from: record.endedAt)), kind: .info)
                    .padding(.horizontal, layout.outerPad)
                    .padding(.bottom, layout.outerPad / 2)
            }

            let vertical = layout.isMini || (layout.size.width - layout.outerPad * 2) / CGFloat(max(1, record.panes.count)) < 300
            let stack = vertical ? AnyLayout(VStackLayout(spacing: layout.paneGap)) : AnyLayout(HStackLayout(spacing: layout.paneGap))
            stack {
                ForEach(Array(record.panes.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(p.language.displayName).font(.system(size: layout.headerFont, weight: .semibold))
                            if p.language.translation != p.target.translation {
                                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                                Text(p.target.displayName).font(.system(size: layout.headerFont, weight: .semibold)).foregroundStyle(Palette.translation)
                            }
                            Spacer()
                            Text(trf("history.lines", p.lines.count)).font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, layout.panePadH).padding(.top, layout.panePadV).padding(.bottom, layout.panePadV - 2)
                        Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.horizontal, layout.panePadH)
                        FillLayout {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: layout.lineGap) {
                                    ForEach(Array(p.lines.enumerated()), id: \.element.id) { i, l in
                                        if i == 0 || Timeline.bucket(l.time) != Timeline.bucket(p.lines[i - 1].time) {
                                            TimeMarker(date: l.time)
                                        }
                                        LineView(line: SubtitleLine(id: l.id, original: l.original, translated: l.translated,
                                                                    source: l.source, timestamp: l.time),
                                                 fontSize: fontSize, showSource: record.source == .mixed,
                                                 showTranslation: p.language.translation != p.target.translation, isHistory: true)
                                    }
                                }
                                .padding(.horizontal, layout.panePadH).padding(.vertical, layout.panePadV)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: layout.cardRadius).fill(Palette.card)
                            .overlay(RoundedRectangle(cornerRadius: layout.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
                    )
                }
            }
            .padding(.horizontal, layout.outerPad)
            .padding(.bottom, layout.outerPad)
        }
    }
}

// MARK: - 頂部列

private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var settings: AppSettings

    /// 一排從左到右：側欄開關、開始／停止、暫停、計時、REC；右端是目標語言、聲音來源、新增欄位、設定。
    var body: some View {
        HStack(spacing: layout.isMini ? 8 : 12) {
            if !layout.isMini {
                RoundIconButton(symbol: "sidebar.left", help: tr("history.toggle")) {
                    settings.data.sidebarVisible.toggle()
                }
            }
            StartButton(settings: settings)
            if model.isRunning {
                PauseButton()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(model.elapsedSeconds(at: ctx.date)))
                        .font(.system(size: layout.timerFont, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()   // 四分之一螢幕時不固定會被折成兩行
                        .foregroundStyle(model.isPaused ? .secondary : .primary)
                }
                if model.isRecording {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        if !layout.isMini {
                            Text(tr("recording.badge")).font(.system(size: 10, weight: .bold)).tracking(1)
                        }
                    }
                    .foregroundStyle(Color.red)
                    .opacity(model.isPaused ? 0.45 : 1)
                    .padding(.horizontal, layout.isMini ? 5 : 8).frame(height: layout.isMini ? 16 : 22)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
                    .help(tr("recording.badge.help"))
                    .accessibilityLabel(tr("recording.badge.help"))
                }
            } else {
                // 閒置時不要每秒重繪。
                Text("00:00:00")
                    .font(.system(size: layout.timerFont, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            if layout.showTitle {
                HStack(spacing: 8) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.brand)
                    Text(tr("app.title"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }

            // 右：縮小時目標語言／來源／新增欄位收進一個選單；設定
            HStack(spacing: layout.isMini ? 6 : 10) {
                if model.selectedSession == nil {
                    if layout.showControlRow { ControlRow(settings: settings) } else { OptionsMenu(settings: settings) }
                }
                RoundIconButton(symbol: "gearshape.fill", help: tr("settings")) { model.showSettings = true }
            }
            .layoutPriority(1)   // 右側的選單不能被壓扁；寬度不夠時犧牲中間的標題
        }
        .padding(.horizontal, layout.outerPad + 4)
        .padding(.top, layout.topPad)
        .padding(.bottom, layout.isMini ? 6 : 8)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

/// 暫停／繼續。暫停中變成琥珀色的播放鍵，一看就知道按下去會繼續。
private struct PauseButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @State private var hover = false

    var body: some View {
        Button { model.togglePause() } label: {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: layout.startSize * 0.36, weight: .bold))
                .foregroundStyle(model.isPaused ? Color.black.opacity(0.8) : Color.white)
                .offset(x: model.isPaused ? layout.startSize / 24 : 0)
                .frame(width: layout.startSize, height: layout.startSize)
                .background(Circle().fill(model.isPaused ? Color(red: 0.98, green: 0.76, blue: 0.3)
                                                         : (hover ? Palette.pillHover : Palette.pill)))
                .scaleEffect(hover ? 1.05 : 1)
                .animation(.spring(duration: 0.25), value: hover)
                .animation(.spring(duration: 0.25), value: model.isPaused)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command])
        .onHover { hover = $0 }
        .help(model.isPaused ? tr("resume.help") : tr("pause.help"))
        .accessibilityLabel(model.isPaused ? tr("resume") : tr("pause"))
    }
}

/// 視窗縮小時，目標語言、聲音來源、新增欄位收成一個選單。
private struct OptionsMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var settings: AppSettings
    @State private var hover = false

    var body: some View {
        Menu {
            Menu {
                ForEach(model.availableLanguages) { lang in
                    Button(lang.displayName) { model.setTarget(lang.id) }
                }
            } label: {
                Label("\(tr("translate.to")): \(model.target.displayName)", systemImage: "character.bubble.fill")
            }
            Menu {
                Picker(tr("audio.source"), selection: $settings.data.source) {
                    ForEach(AudioSourceKind.allCases) { k in
                        Label(k.label, systemImage: k.symbol).tag(k)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("\(tr("audio.source")): \(settings.data.source.shortLabel)", systemImage: settings.data.source.symbol)
            }
            Divider()
            Button { model.addPane() } label: { Label(tr("pane.add"), systemImage: "plus") }
                .disabled(!model.canAddPane)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: layout.isMini ? 11 : 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: layout.iconButton, height: layout.iconButton)
                .background(Circle().fill(hover ? Palette.pillHover : Palette.pill))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.6 : 1)
        .onHover { hover = $0 }
        .help(tr("options"))
        .accessibilityLabel(tr("options"))
    }
}
private struct StartButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var settings: AppSettings
    @State private var hover = false

    var body: some View {
        Button(action: { model.toggle() }) {
            ZStack {
                Circle()
                    .fill(model.isRunning
                          ? LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.36), Color(red: 0.85, green: 0.18, blue: 0.25)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color(red: 0.36, green: 0.86, blue: 0.56), Color(red: 0.13, green: 0.66, blue: 0.42)], startPoint: .top, endPoint: .bottom))
                    .frame(width: layout.startSize, height: layout.startSize)
                    .shadow(color: (model.isRunning ? Color.red : Color.green).opacity(hover ? 0.55 : 0.35), radius: hover ? layout.startSize / 3 : layout.startSize / 5, y: 2)
                if model.isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: layout.startSize * 0.38, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: model.isRunning ? 0 : layout.startSize / 24)
                }
            }
            .scaleEffect(hover ? 1.05 : 1)
            .animation(.spring(duration: 0.25), value: hover)
            .animation(.spring(duration: 0.25), value: model.isRunning)
        }
        .buttonStyle(.plain)
        .disabled(model.isStarting)
        .keyboardShortcut(.space, modifiers: [.command])
        .onHover { hover = $0 }
        .help(model.isRunning ? tr("stop.help") : tr("start.help"))
        .accessibilityLabel(model.isRunning ? tr("stop") : tr("start"))
    }
}

private struct RoundIconButton: View {
    @Environment(\.layout) private var layout
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: layout.isMini ? 11 : 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: layout.iconButton, height: layout.iconButton)
                .background(Circle().fill(hover ? Palette.pillHover : Palette.pill))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}


// MARK: - 控制列：目標語言、聲音來源、新增欄位

private struct ControlRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings

    /// 排在頂部列右側，所以沒有文字標籤（滑鼠停上去有說明），也不佔第二排。
    var body: some View {
        HStack(spacing: 8) {
            PillMenu(title: model.target.name, symbol: "character.bubble.fill") {
                ForEach(model.availableLanguages) { lang in
                    Button(lang.displayName) { model.setTarget(lang.id) }
                }
            }
            .help(tr("translate.to"))

            PillMenu(title: settings.data.source.shortLabel, symbol: settings.data.source.symbol) {
                Picker(tr("audio.source"), selection: $settings.data.source) {
                    ForEach(AudioSourceKind.allCases) { k in
                        Label(k.label, systemImage: k.symbol).tag(k)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .help(tr("audio.source"))

            Button { model.addPane() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.pill))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddPane)
            .opacity(model.canAddPane ? 1 : 0.4)
            .help(model.panes.count >= AppModel.maxPanes ? trf("pane.add.max", AppModel.maxPanes) : tr("pane.add.help"))
            .accessibilityLabel(tr("pane.add"))
        }
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.75 : 1)
    }
}

// MARK: - 提示 / 錯誤

private struct Banner: View {
    enum Kind { case error, info }
    let text: String
    let kind: Kind
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil
    var dismiss: (() -> Void)? = nil

    init(text: String, kind: Kind, actionTitle: String? = nil, action: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.text = text
        self.kind = kind
        self.actionTitle = actionTitle
        self.action = action
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? Color.orange : Palette.translation)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((kind == .error ? Color.orange : Palette.translation).opacity(0.10))
        )
    }
}

// MARK: - 單一字幕欄

private struct PaneView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var pane: PaneEngine
    @ObservedObject var settings: AppSettings
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var downloadMessage: String?
    /// 使用者往上捲去看舊字幕時變 false：新句子進來不再自動捲到底，改顯示「回到最新」按鈕。
    @State private var followBottom = true

    private var fontSize: CGFloat { CGFloat(settings.data.fontSize) * layout.fontScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, layout.panePadH)
                .padding(.top, layout.panePadV - 2)
                .padding(.bottom, layout.panePadV - 4)
            Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.horizontal, layout.panePadH)
            if let err = pane.lastError {
                Banner(text: err.message, kind: .error,
                       actionTitle: err.packMissing ? tr("pack.download") : nil,
                       action: err.packMissing ? requestDownload : nil)
                    .padding(.horizontal, layout.panePadH).padding(.top, layout.panePadV - 4)
            } else if let hint = pane.translationHint, !layout.isMini {
                // 縮到最小時不顯示線上翻譯提示，位置留給字幕；錯誤還是要顯示。
                Banner(text: hint, kind: .info, actionTitle: tr("pack.download"), action: requestDownload)
                    .padding(.horizontal, layout.panePadH).padding(.top, layout.panePadV - 4)
            }
            if let m = downloadMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).padding(.horizontal, layout.panePadH + 2).padding(.top, 6)
            }
            FillLayout { transcript }
        }
        .background(
            RoundedRectangle(cornerRadius: layout.cardRadius)
                .fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: layout.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
        )
        // 隱形的宿主，只用來觸發系統翻譯語言包的下載對話框。
        .background {
            Color.clear.frame(width: 1, height: 1)
                .translationTask(downloadConfig) { session in
                    do {
                        try await session.prepareTranslation()
                        downloadMessage = tr("pack.ready")
                        pane.languagePackInstalled()
                    } catch {
                        downloadMessage = trf("pack.failed", error.localizedDescription)
                    }
                    downloadConfig = nil
                }
        }
    }

    private func requestDownload() {
        downloadMessage = nil
        downloadConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: pane.language.translation),
            target: Locale.Language(identifier: pane.target.translation))
    }

    // 標題列：聽的語言（可選）→ 目標語言、狀態、清除、關閉
    private var header: some View {
        let small = layout.iconButton - 6
        return HStack(spacing: layout.isMini ? 6 : 10) {
            HStack(spacing: layout.isMini ? 4 : 8) {
                // 縮到最小時語言名稱只顯示原生寫法，省掉括號裡的翻譯。
                PillMenu(title: layout.isMini ? pane.language.nativeName : pane.language.displayName, symbol: "ear.fill") {
                    ForEach(model.availableLanguages) { lang in
                        Button(lang.displayName) { model.setPaneLanguage(pane, lang.id) }
                            .disabled(model.isLanguageUsed(lang.id, except: pane))
                    }
                }
                .disabled(model.isRunning)
                if !pane.sameLanguage {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(layout.isMini ? pane.target.nativeName : pane.target.displayName)
                        .font(.system(size: layout.headerFont, weight: .semibold))
                        .foregroundStyle(Palette.translation)
                        .lineLimit(1)
                } else if !layout.isMini {
                    Text(tr("pane.transcriptOnly"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            StatusDot(running: pane.isRunning, text: pane.isRunning && !layout.isMini ? pane.status : "")

            Button { pane.clear() } label: {
                Image(systemName: "trash")
                    .font(.system(size: layout.isMini ? 10 : 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: small, height: small)
                    .background(Circle().fill(Palette.pill))
            }
            .buttonStyle(.plain)
            .help(tr("pane.clear"))
            .accessibilityLabel(tr("pane.clear"))

            if model.panes.count > 1 {
                Button { model.removePane(pane) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: layout.isMini ? 9 : 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: small, height: small)
                        .background(Circle().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .help(tr("pane.close"))
                .accessibilityLabel(tr("pane.close"))
            }
        }
    }

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var atBottom: Bool
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: layout.lineGap) {
                    if pane.lines.isEmpty && pane.orderedDrafts.isEmpty {
                        emptyState
                    }
                    ForEach(Array(pane.lines.enumerated()), id: \.element.id) { i, line in
                        if i == 0 || Timeline.bucket(line.timestamp) != Timeline.bucket(pane.lines[i - 1].timestamp) {
                            TimeMarker(date: line.timestamp)
                        }
                        LineView(line: line, fontSize: fontSize, showSource: settings.data.source == .mixed,
                                 showTranslation: !pane.sameLanguage, selectable: !pane.isRunning)
                    }
                    ForEach(pane.orderedDrafts, id: \.source) { d in
                        DraftView(original: d.text, translation: d.translation, fontSize: fontSize,
                                  source: settings.data.source == .mixed ? d.source : nil)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, layout.panePadH)
                .padding(.vertical, layout.panePadV)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 分辨「使用者往上捲」和「內容變長」：前者 offset 變小，後者 offset 不變只是離底部變遠。
            .onScrollGeometryChange(for: ScrollState.self) { g in
                ScrollState(offset: g.contentOffset.y,
                            atBottom: g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24)
            } action: { old, new in
                if new.atBottom { followBottom = true }
                else if new.offset < old.offset - 2 { followBottom = false }
            }
            .overlay(alignment: .bottom) {
                if !followBottom {
                    Button {
                        followBottom = true
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down").font(.system(size: layout.isMini ? 9 : 11, weight: .bold))
                            if !layout.isMini { Text(tr("scroll.latest")).font(.system(size: 12, weight: .medium)) }
                        }
                        .padding(.horizontal, layout.isMini ? 8 : 12)
                        .frame(height: layout.isMini ? 22 : 28)
                        .background(Capsule().fill(Palette.pillHover))
                        .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, layout.panePadV)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .help(tr("scroll.latest"))
                    .accessibilityLabel(tr("scroll.latest"))
                }
            }
            .animation(.easeOut(duration: 0.2), value: followBottom)
            .onChange(of: pane.lines.count) { _, count in
                if count == 0 { followBottom = true }   // 清除後重新跟隨
                guard followBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: pane.drafts) { _, _ in if followBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: pane.draftTranslations) { _, _ in if followBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: layout.isMini ? 6 : 10) {
            Image(systemName: settings.data.source.symbol)
                .font(.system(size: layout.isMini ? 22 : 34, weight: .regular))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 4)
            if pane.isRunning {
                Text(pane.status == tr("status.listening") ? trf("empty.listening", pane.language.name) : pane.status)
                    .font(.system(size: layout.isMini ? 12 : 15))
                    .foregroundStyle(.tertiary)
            } else {
                Text(trf("empty.idle", pane.language.name))
                    .font(.system(size: layout.isMini ? 12 : 15))
                    .foregroundStyle(.tertiary)
                if !pane.sameLanguage, !layout.isMini {
                    Text(trf("empty.hint", pane.target.name))
                        .font(.system(size: 13))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, layout.isMini ? 20 : 70)
        .multilineTextAlignment(.center)
    }
}

/// 膠囊造型的下拉選單。
private struct PillMenu<Content: View>: View {
    @Environment(\.layout) private var layout
    let title: String
    var symbol: String? = nil
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: layout.isMini ? 4 : 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: layout.isMini ? 9 : 11, weight: .semibold))
                }
                Text(title).font(.system(size: layout.isMini ? 11 : 13, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, layout.isMini ? 8 : 12)
            .frame(height: layout.pillHeight)
            .background(Capsule().fill(hover ? Palette.pillHover : Palette.pill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
    }
}

/// 聆聽狀態小圓點。
private struct StatusDot: View {
    let running: Bool
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Color.green : Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
                .shadow(color: running ? Color.green.opacity(pulse ? 0.9 : 0.2) : .clear, radius: pulse ? 6 : 2)
                .onAppear { pulse = running }
                .onChange(of: running) { _, now in pulse = now }   // 停止時收掉呼吸燈，再開始時重新閃
                .animation(running ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
            if !text.isEmpty {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 4)
    }
}

/// 時間軸格線：每 5 分鐘一條，中間標該格的起始時間。
private struct TimeMarker: View {
    @Environment(\.layout) private var layout
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.cardStroke).frame(height: 1)
            Text(Timeline.label(date))
                .font(.system(size: layout.isMini ? 9 : 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Rectangle().fill(Palette.cardStroke).frame(height: 1)
        }
        .padding(.vertical, layout.isMini ? 0 : 2)
        .accessibilityLabel(Timeline.label(date))
    }
}

private struct SourceTag: View {
    let source: CaptureKind
    var body: some View {
        Image(systemName: source.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Palette.pill))
            .help(source.label)
    }
}

private struct LineView: View {
    let line: SubtitleLine
    let fontSize: CGFloat
    var showSource = false
    var showTranslation = true
    var isHistory = false
    var selectable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showSource { SourceTag(source: line.source) }
                Text(line.original)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineSpacing(fontSize < 14 ? 1 : 3)
            }
            if !showTranslation {
                EmptyView()
            } else if let t = line.translated {
                Text(t)
                    .font(.system(size: fontSize * 0.95))
                    .foregroundStyle(Palette.translation)
                    .lineSpacing(3)
                    .transition(.opacity)
            } else if line.translationFailed || isHistory {
                Label(tr("line.failed"), systemImage: "exclamationmark.circle")
                    .font(.system(size: fontSize * 0.65))
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(tr("line.translating")).font(.system(size: fontSize * 0.65)).foregroundStyle(.tertiary)
                }
            }
        }
        .modifier(SelectableText(enabled: selectable))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: line.translated)
    }
}

private struct DraftView: View {
    let original: String
    let translation: String
    let fontSize: CGFloat
    var source: CaptureKind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let source { SourceTag(source: source) }
                Text(original)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            if !translation.isEmpty {
                Text(translation)
                    .font(.system(size: fontSize * 0.95))
                    .foregroundStyle(Palette.translation.opacity(0.55))
                    .lineSpacing(3)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15)).frame(width: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 設定

private struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("settings")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)

            Form {
                Section(tr("settings.ui")) {
                    Picker(tr("settings.ui"), selection: $settings.data.uiLanguage) {
                        ForEach(UILanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section(tr("settings.subtitles")) {
                    HStack {
                        Text(tr("settings.fontSize"))
                        Slider(value: $settings.data.fontSize, in: 14...40, step: 1)
                        Text("\(Int(settings.data.fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                    Text(tr("settings.sample"))
                        .font(.system(size: CGFloat(settings.data.fontSize)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Section(tr("settings.translation")) {
                    Toggle(tr("settings.drafts"), isOn: $settings.data.translateDrafts)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("settings.translation.note"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(tr("settings.openRegion")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Section(tr("settings.recognition")) {
                    Toggle(tr("settings.listenTarget"), isOn: $settings.data.listenTarget)
                    Text(tr("settings.listenTarget.help")).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("settings.vocabulary"))
                        TextEditor(text: $settings.data.vocabulary)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 90)
                            .scrollContentBackground(.hidden)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                            .accessibilityLabel(tr("settings.vocabulary"))
                        Text(tr("settings.vocabulary.help")).font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(tr("settings.wording")) {
                    Toggle(tr("settings.taiwanWording"), isOn: $settings.data.taiwanWording)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("settings.wordingRules"))
                        TextEditor(text: $settings.data.wordingRules)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 70)
                            .scrollContentBackground(.hidden)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                            .accessibilityLabel(tr("settings.wordingRules"))
                        Text(tr("settings.wordingRules.help")).font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(tr("settings.recording")) {
                    Toggle(tr("settings.recordAudio"), isOn: $settings.data.recordAudio)
                    Text(tr("settings.recording.note"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(tr("settings.transcript")) {
                    Toggle(trf("settings.saveTranscript", tr("transcript.folder")), isOn: $settings.data.saveTranscript)
                }
                Section(tr("settings.arbiter")) {
                    Text(tr("settings.arbiter.note"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ThresholdRow(title: tr("settings.arb.junk"), help: tr("settings.arb.junk.help"),
                                 value: $settings.data.arbiter.junkConfidence, range: 0...0.6)
                    ThresholdRow(title: tr("settings.arb.loneDrop"), help: tr("settings.arb.loneDrop.help"),
                                 value: $settings.data.arbiter.loneDropBelow, range: 0...0.9)
                    ThresholdRow(title: tr("settings.arb.loneStrict"), help: tr("settings.arb.loneStrict.help"),
                                 value: $settings.data.arbiter.loneStrictBelow, range: 0...0.95)
                    ThresholdRow(title: tr("settings.arb.fastPass"), help: tr("settings.arb.fastPass.help"),
                                 value: $settings.data.arbiter.fastPassConfidence, range: 0.5...1)
                    ThresholdRow(title: tr("settings.arb.bonus"), help: tr("settings.arb.bonus.help"),
                                 value: $settings.data.arbiter.preferredBonus, range: 0...0.3)
                    HStack {
                        Spacer()
                        Button(tr("settings.arb.reset")) { settings.data.arbiter = .standard }
                            .controlSize(.small)
                            .disabled(settings.data.arbiter == .standard)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                // 版本・編譯時間・commit，看一眼就知道開的是哪一版。
                Text("\(tr("app.title")) \(AppInfo.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        // 視窗比設定頁小的時候，設定頁跟著縮，不然會被切掉。
        .frame(width: min(600, max(340, layout.size.width - 40)), height: min(720, max(300, layout.size.height - 40)))
        .background(Palette.window)
    }
}

/// 設定頁裡一條門檻滑桿：標題、說明、滑桿、數值。
private struct ThresholdRow: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Slider(value: $value, in: range, step: 0.01).frame(width: 200)
                Text(String(format: "%.2f", value)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Text(help).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
