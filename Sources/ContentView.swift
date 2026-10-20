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

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack {
            Palette.window.ignoresSafeArea()
            RadialGradient(colors: [Palette.accentA.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                if settings.data.sidebarVisible {
                    HistorySidebar(settings: settings, history: model.history)
                        .frame(width: 260)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(Palette.cardStroke).frame(width: 1).ignoresSafeArea()
                }
                VStack(spacing: 0) {
                    TopBar(settings: settings)
                    if let session = model.selectedSession {
                        HistoryDetail(record: session, settings: settings)
                    } else {
                        ControlRow(settings: settings)
                        if let err = model.globalError {
                            Banner(text: err, kind: .error, dismiss: { model.globalError = nil })
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                        }
                        HStack(spacing: 16) {
                            ForEach(model.panes) { pane in
                                PaneView(pane: pane, settings: settings)
                            }
                        }
                        .animation(.spring(duration: 0.3), value: model.panes.count)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: settings.data.sidebarVisible)
        }
        // 每欄最少 280 pt：四欄加側欄 1420 pt，13 吋 MacBook（1470 pt）還放得下。
        .frame(minWidth: CGFloat(max(1, model.panes.count)) * 280 + 60 + (settings.data.sidebarVisible ? 260 : 0), minHeight: 520)
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
                                    Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
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
    let record: SessionRecord
    @ObservedObject var settings: AppSettings

    private var fontSize: CGFloat { CGFloat(settings.data.fontSize) }

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
                Text(record.title).font(.system(size: 14, weight: .semibold))
                Text("\(record.source.label) · \(record.durationText) · \(trf("history.lines", record.lineCount))")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                Button { model.copyToPasteboard(record) } label: {
                    Label(tr("history.copy"), systemImage: "doc.on.doc").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                if model.history.recordingURL(for: record) != nil {
                    Button { model.saveRecording(record) } label: {
                        Label(tr("recording.save"), systemImage: "arrow.down.circle").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(Palette.pill))
                    }
                    .buttonStyle(.plain)
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
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            HStack(spacing: 16) {
                ForEach(Array(record.panes.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(p.language.displayName).font(.system(size: 14, weight: .semibold))
                            if p.language.translation != p.target.translation {
                                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                                Text(p.target.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.translation)
                            }
                            Spacer()
                            Text(trf("history.lines", p.lines.count)).font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                        Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.horizontal, 16)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(p.lines) { l in
                                    LineView(line: SubtitleLine(id: l.id, original: l.original, translated: l.translated,
                                                                source: l.source, timestamp: l.time),
                                             fontSize: fontSize, showSource: record.source == .mixed,
                                             showTranslation: p.language.translation != p.target.translation, isHistory: true)
                                }
                            }
                            .padding(.horizontal, 18).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18).fill(Palette.card)
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.cardStroke, lineWidth: 1))
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - 頂部列

private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack {
            // 左：側欄開關 + 標題
            HStack(spacing: 10) {
                RoundIconButton(symbol: "sidebar.left", help: tr("history.toggle")) {
                    settings.data.sidebarVisible.toggle()
                }
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.brand)
                Text(tr("app.title"))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 中：開始鈕 + 計時
            HStack(spacing: 16) {
                StartButton(settings: settings)
                if model.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(at: ctx.date))
                            .font(.system(size: 26, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    if model.isRecording {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                            Text(tr("recording.badge")).font(.system(size: 11, weight: .bold)).tracking(1)
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .help(tr("recording.badge.help"))
                        .accessibilityLabel(tr("recording.badge.help"))
                    }
                } else {
                    // 閒置時不要每秒重繪。
                    Text("00:00:00")
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // 右：設定
            HStack(spacing: 10) {
                RoundIconButton(symbol: "gearshape.fill", help: tr("settings")) { model.showSettings = true }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private func elapsed(at now: Date) -> String {
        guard let start = model.startedAt else { return "00:00:00" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private struct StartButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var hover = false

    var body: some View {
        Button(action: { model.toggle() }) {
            ZStack {
                Circle()
                    .fill(model.isRunning
                          ? LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.36), Color(red: 0.85, green: 0.18, blue: 0.25)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color(red: 0.36, green: 0.86, blue: 0.56), Color(red: 0.13, green: 0.66, blue: 0.42)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 48, height: 48)
                    .shadow(color: (model.isRunning ? Color.red : Color.green).opacity(hover ? 0.55 : 0.35), radius: hover ? 16 : 10, y: 2)
                if model.isStarting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: model.isRunning ? 0 : 2)
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
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
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

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(tr("translate.to")).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                PillMenu(title: model.target.displayName, symbol: "character.bubble.fill") {
                    ForEach(model.availableLanguages) { lang in
                        Button(lang.displayName) { model.setTarget(lang.id) }
                    }
                }
            }

            HStack(spacing: 8) {
                Text(tr("audio.source")).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                PillMenu(title: settings.data.source.shortLabel, symbol: settings.data.source.symbol) {
                    Picker(tr("audio.source"), selection: $settings.data.source) {
                        ForEach(AudioSourceKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .padding(.leading, 8)

            Spacer()

            Button { model.addPane() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(tr("pane.add")).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Palette.pill))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddPane)
            .opacity(model.canAddPane ? 1 : 0.4)
            .help(model.panes.count >= AppModel.maxPanes ? trf("pane.add.max", AppModel.maxPanes) : tr("pane.add.help"))
        }
        .disabled(model.isRunning)
        .opacity(model.isRunning ? 0.75 : 1)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
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
    @ObservedObject var pane: PaneEngine
    @ObservedObject var settings: AppSettings
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var downloadMessage: String?

    private var fontSize: CGFloat { CGFloat(settings.data.fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Rectangle().fill(Palette.cardStroke).frame(height: 1).padding(.horizontal, 16)
            if let err = pane.lastError {
                Banner(text: err.message, kind: .error,
                       actionTitle: err.packMissing ? tr("pack.download") : nil,
                       action: err.packMissing ? requestDownload : nil)
                    .padding(.horizontal, 16).padding(.top, 12)
            } else if let hint = pane.translationHint {
                Banner(text: hint, kind: .info, actionTitle: tr("pack.download"), action: requestDownload)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            if let m = downloadMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 6)
            }
            transcript
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.cardStroke, lineWidth: 1))
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
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                PillMenu(title: pane.language.displayName, symbol: "ear.fill") {
                    ForEach(model.availableLanguages) { lang in
                        Button(lang.displayName) { model.setPaneLanguage(pane, lang.id) }
                            .disabled(model.isLanguageUsed(lang.id, except: pane))
                    }
                }
                .disabled(model.isRunning)
                if !pane.sameLanguage {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(pane.target.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.translation)
                } else {
                    Text(tr("pane.transcriptOnly"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            StatusDot(running: pane.isRunning, text: pane.isRunning ? pane.status : "")

            Button { pane.clear() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.pill))
            }
            .buttonStyle(.plain)
            .help(tr("pane.clear"))
            .accessibilityLabel(tr("pane.clear"))

            if model.panes.count > 1 {
                Button { model.removePane(pane) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.pill))
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .help(tr("pane.close"))
                .accessibilityLabel(tr("pane.close"))
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if pane.lines.isEmpty && pane.orderedDrafts.isEmpty {
                        emptyState
                    }
                    ForEach(pane.lines) { line in
                        LineView(line: line, fontSize: fontSize, showSource: settings.data.source == .mixed,
                                 showTranslation: !pane.sameLanguage)
                    }
                    ForEach(pane.orderedDrafts, id: \.source) { d in
                        DraftView(original: d.text, translation: d.translation, fontSize: fontSize,
                                  source: settings.data.source == .mixed ? d.source : nil)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: pane.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: pane.drafts) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: pane.draftTranslations) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: settings.data.source.symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 4)
            if pane.isRunning {
                Text(pane.status == tr("status.listening") ? trf("empty.listening", pane.language.name) : pane.status)
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            } else {
                Text(trf("empty.idle", pane.language.name))
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                if !pane.sameLanguage {
                    Text(trf("empty.hint", pane.target.name))
                        .font(.system(size: 13))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .multilineTextAlignment(.center)
    }
}

/// 膠囊造型的下拉選單。
private struct PillMenu<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showSource { SourceTag(source: line.source) }
                Text(line.original)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
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
        .textSelection(.enabled)
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
                Spacer()
                Button(tr("done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 600, height: 720)
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
