import SwiftUI
import AppKit

struct StudioView: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(store: store).frame(width: StudioLayout.sidebar)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    FlowCanvas(store: store).frame(minWidth: 500, maxWidth: .infinity)
                    Divider()
                    InspectorPanel(store: store).frame(width: StudioLayout.inspector)
                }
                Divider()
                HStack(spacing: 0) { transport; Divider(); PlaybackBar(store: store) }.frame(height: 70)
            }
        }
        .background(StudioTheme.panel)
        .foregroundStyle(StudioTheme.ink).tint(StudioTheme.cyan).preferredColorScheme(.light)
        .font(.system(size: 13)).frame(minWidth: 960, minHeight: 540)
        .sheet(item: $store.previewRecording) { recording in RecordingPreviewSheet(store: store, recording: recording) }
        .sheet(isPresented: $store.showTemplates) { TemplateSheet(store: store) }
        .alert("录音", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
            if store.error?.contains("权限") == true { Button("打开权限设置") { let mic = store.error?.contains("麦克风权限") == true; store.error = nil; store.openPrivacy(mic) } }
        } message: { Text(store.error ?? "") }
    }
    var header: some View {
        HStack(spacing: 8) {
            if let source = store.session.blocks.first(where: { $0.kind == .application }) {
                FavoriteApplicationsBar(store: store, sourceID: source.id)
            } else { Spacer() }
            Button { store.autoArrange() } label: { Image(systemName: "rectangle.3.group").font(.system(size: 15)).frame(width: 30, height: 30) }.disabled(store.running || store.busy).help("整理模块")
            Menu {
                Button("导入会话…") { store.importSession() }.disabled(store.running || store.busy)
                Button("导出当前会话…") { store.exportSession() }
                Button("导入音频…") { store.importRecordings() }

            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: 26, height: 30) }.menuStyle(.borderlessButton).frame(width: 28)
        }.buttonStyle(StudioButtonStyle()).foregroundStyle(StudioTheme.ink).padding(.trailing, 10).frame(height: 44).background(NativePanel())
    }
    var transport: some View {
        HStack(spacing: 10) {
            Button { store.toggleRun() } label: {
                HStack(spacing: 7) {
                    if store.busy { ProgressView().controlSize(.small).tint(.white).frame(width: 16, height: 16) }
                    else { Image(systemName: store.running ? "stop.fill" : "record.circle").font(.system(size: 19, weight: .medium)) }
                    Text(store.busy ? "处理中" : store.running ? "停止" : "录音").font(.system(size: 14, weight: .semibold))
                }.foregroundStyle(.white).frame(width: 94, height: 37)
                    .background(LinearGradient(colors: store.running ? [.red.opacity(0.9), .red.opacity(0.75)] : [Color(red: 0.02, green: 0.77, blue: 0.91), StudioTheme.cyan], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 11))
                    .shadow(color: StudioTheme.cyan.opacity(0.20), radius: 9, y: 4)
            }.buttonStyle(StudioButtonStyle()).disabled(store.busy).help("开始／停止 · ⌘R")
            Button { store.pauseRecording() } label: { Image(systemName: store.paused ? "play.fill" : "pause.fill").font(.system(size: 17)).frame(width: 25, height: 32) }.disabled(!store.running).help("暂停／继续录音 · ⌘⇧P")
            Button { store.splitRecording() } label: { Image(systemName: "scissors").font(.system(size: 17)).frame(width: 25, height: 32) }.disabled(!store.running).help("分段 · ⌘⇧S")
            Divider().overlay(.white.opacity(0.15)).frame(height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(timeString(store.elapsed)).font(.system(size: 25, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                Text(store.formatSummary).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }.frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) { Circle().fill(store.running ? (store.paused ? .orange : StudioTheme.cyan) : .white.opacity(0.45)).frame(width: 6, height: 6); Text(store.status).font(.system(size: 12, weight: .medium)).lineLimit(1) }.foregroundStyle(.white.opacity(0.9))
                StereoMeter(level: store.peak, dark: true, detailed: true).frame(maxWidth: 230).frame(height: 34)
            }.frame(maxWidth: 240, alignment: .leading)
            Spacer(minLength: 4)
            Button { store.inspectorTab = "录音" } label: { Image(systemName: "recordingtape").font(.system(size: 19)).frame(width: 28, height: 30) }.help("录音库")
        }.buttonStyle(StudioButtonStyle()).foregroundStyle(store.running ? Color.white : Color.white.opacity(0.65))
            .padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 70)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.27), Color(red: 0.08, green: 0.13, blue: 0.18)], startPoint: .top, endPoint: .bottom))
    }
}

struct SessionSidebar: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("会话").font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(store.sessions.count)").font(.system(size: 11, design: .monospaced)) }.foregroundStyle(StudioTheme.muted).padding(.horizontal, 12).frame(height: 34)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        Button { store.selectSession(session.id) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: session.blocks.first(where: { $0.kind.isSource })?.kind.symbol ?? "square.stack.3d.up").font(.system(size: 14)).foregroundStyle(StudioTheme.cyan).frame(width: 19)
                                Text(session.name).font(.system(size: 13, weight: session.id == store.selectedSessionID ? .semibold : .regular)).lineLimit(1).foregroundStyle(StudioTheme.ink)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).frame(height: 39)
                                .background(session.id == store.selectedSessionID ? StudioTheme.cyan.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(StudioButtonStyle()).contextMenu {
                            Button("复制会话") { store.selectSession(session.id); store.duplicateSession() }.disabled(store.running || store.busy)
                            Button("导出会话…") { store.selectSession(session.id); store.exportSession() }.disabled(store.running || store.busy)
                            Button("删除会话…", role: .destructive) { store.selectSession(session.id); store.deleteSession() }.disabled(store.running || store.busy)
                        }
                    }
                }.padding(.horizontal, 6)
            }
            HStack { Button { store.showTemplates = true } label: { Image(systemName: "plus.circle").font(.system(size: 17)) }.buttonStyle(StudioButtonStyle()).disabled(store.running || store.busy).help("新建会话"); Spacer(); Text("\(store.recordingCount) 条录音").font(.system(size: 11)).foregroundStyle(StudioTheme.muted) }.padding(12)
        }.background(NativePanel())
    }
}

struct TemplateSheet: View {
    @ObservedObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let templates: [(String, String, String)] = [
        ("应用录音", "macwindow", "只录一个应用，其他声音不混入"),
        ("系统录音", "desktopcomputer", "记录 Mac 正在播放的音频"),
        ("麦克风录音", "mic.fill", "录制旁白、乐器与外部音频输入"),
        ("双路混音", "arrow.triangle.merge", "应用声音与麦克风汇入同一录音"),
        ("文件处理", "waveform", "处理已有音频并另存新文件"),
        ("信号链测试", "waveform.path", "用真实测试音检查处理与录音")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("新建会话").font(.system(size: 24, weight: .semibold)); Text("选择一个起点，所有模块和连线都可以编辑。").font(.system(size: 12)).foregroundStyle(StudioTheme.muted) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 21)).foregroundStyle(StudioTheme.muted.opacity(0.5)) }.buttonStyle(StudioButtonStyle()) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(templates, id: \.0) { name, symbol, description in
                    Button { store.create(name) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(StudioTheme.cyan).frame(height: 33)
                            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.ink)
                            Text(description).font(.system(size: 10)).foregroundStyle(StudioTheme.muted).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.line))
                    }.buttonStyle(StudioButtonStyle())
                }
            }
            HStack { Button("空白会话") { var s = Session(); s.name = "空白会话"; store.sessions.append(s); store.selectSession(s.id); store.save(); dismiss() }.buttonStyle(.borderless); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(30).frame(width: 600).background(StudioTheme.canvas).tint(StudioTheme.cyan)
    }
}
