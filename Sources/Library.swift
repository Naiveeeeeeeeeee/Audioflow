import SwiftUI
import AppKit

struct RecordingLibrary: View {
    @ObservedObject var store: StudioStore
    @State private var exportRecord: Recording?
    @State private var renameRecord: Recording?
    @State private var renameText = ""
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("录音库").font(.system(size: 18, weight: .semibold)); Spacer(); Button { store.importRecordings() } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 14)) }.buttonStyle(StudioButtonStyle()).help("导入音频") }
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.muted); TextField("搜索录音", text: $store.search).textFieldStyle(.plain) }.font(.system(size: 13)).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.line))
                Picker("范围", selection: $store.allRecordings) { Text("当前会话").tag(false); Text("全部录音").tag(true) }.pickerStyle(.segmented).controlSize(.small)
            }.padding(12)
            Divider()
            if store.activeRecordings.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(StudioTheme.cyan.opacity(0.6))
                    Text(store.running ? "停止或分段后，录音会出现在这里" : "这里还没有录音").font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                    Text("录制完成后可回放、重命名和转换格式。").font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                    Button("导入音频…") { store.importRecordings() }.font(.system(size: 13))
                    Spacer()
                }.padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.activeRecordings) { recording in
                            RecordingCard(store: store, recording: recording, onExport: { exportRecord = recording }, onRename: { renameRecord = recording; renameText = recording.name })
                        }
                    }.padding(12)
                }
            }
            Divider()
            HStack {
                Text("\(store.activeRecordings.count) 条录音").font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button { try? FileManager.default.createDirectory(at: store.recordFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(store.recordFolder) } label: { Label("打开文件夹", systemImage: "folder").font(.system(size: 12)) }.buttonStyle(StudioButtonStyle()).help("打开录音文件夹")
            }.padding(.horizontal, 12).frame(height: 37)
        }
        .sheet(item: $exportRecord) { recording in ExportRecordingSheet(store: store, recording: recording) }
        .alert("重命名录音", isPresented: Binding(get: { renameRecord != nil }, set: { if !$0 { renameRecord = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameRecord = nil }
            Button("保存") { if let recording = renameRecord { store.renameRecording(recording, to: renameText) }; renameRecord = nil }
        } message: { Text("只修改文件名，保留原来的音频格式。") }
    }
}

struct RecordingCard: View {
    @ObservedObject var store: StudioStore
    var recording: Recording
    var onExport: () -> Void
    var onRename: () -> Void
    @State private var hovered = false
    var isCurrent: Bool { store.playingID == recording.id }
    var selected: Bool { store.selectedRecordingID == recording.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 8) {
                Text(recording.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("重命名…", action: onRename)
                    Button("快速查看") { store.quickLook(recording) }
                    Button("在 Finder 中显示") { store.reveal(recording) }
                    Button("另存／转换格式…", action: onExport).disabled(store.busy || store.running)
                    Divider()
                    Button("移到废纸篓…", role: .destructive) { store.trash(recording) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)) }.menuStyle(.borderlessButton).frame(width: 22)
            }
            HStack(spacing: 9) {
                Button { store.togglePlayback(recording) } label: { Image(systemName: isCurrent && store.playerPlaying ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 22, height: 28) }.buttonStyle(StudioButtonStyle()).help("播放／暂停")
                WaveformView(points: recording.waveform, progress: isCurrent && store.playerDuration > 0 ? store.playerPosition / store.playerDuration : 0, active: isCurrent).frame(height: 31)
                Text(timeString(recording.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioTheme.muted)
            }
            HStack(spacing: 6) {
                Text(recording.format).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 3).background(StudioTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Text("\(Int(recording.sampleRate)) Hz · \(recording.channels == 2 ? "立体声" : "单声道")").font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                Spacer(minLength: 0)
                Text(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file)).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
            }
            HStack(spacing: 8) {
                Button { store.quickLook(recording) } label: { Label("快速查看", systemImage: "eye").font(.system(size: 11)).padding(.horizontal, 6).frame(height: 25) }
                    .help("使用 macOS 快速查看浏览录音文件")
                Spacer(minLength: 0)
                Button { store.reveal(recording) } label: { Label("显示文件", systemImage: "folder").font(.system(size: 11)).padding(.horizontal, 6).frame(height: 25) }
                    .help("在 Finder 中选中这条录音")
            }.buttonStyle(StudioButtonStyle())
        }.padding(12).background(selected ? StudioTheme.cyan.opacity(0.085) : Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? StudioTheme.cyan.opacity(0.3) : StudioTheme.line.opacity(0.75)))
            .shadow(color: .black.opacity(hovered ? 0.13 : 0.08), radius: 6, y: 3)
            .onHover { hovered = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture { store.selectedRecordingID = recording.id }
            .onDrag { NSItemProvider(contentsOf: recording.url) ?? NSItemProvider() }
    }
}

struct ExportRecordingSheet: View {
    @ObservedObject var store: StudioStore
    var recording: Recording
    @Environment(\.dismiss) private var dismiss
    @State private var format = RecordingFormat.wav
    @State private var rate = 48000.0
    @State private var bitrate = 256
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("导出录音", systemImage: "square.and.arrow.up").font(.system(size: 21, weight: .semibold)).foregroundStyle(StudioTheme.ink)
            Text(recording.name).font(.system(size: 14)).foregroundStyle(StudioTheme.muted).lineLimit(2)
            Form {
                Picker("格式", selection: $format) { ForEach(RecordingFormat.allCases) { f in Text(f.label).tag(f) } }
                Picker("采样率", selection: $rate) { Text("44.1 kHz").tag(44100.0); Text("48 kHz").tag(48000.0); if !format.lossy { Text("96 kHz").tag(96000.0) } }
                if format.lossy { Picker("比特率", selection: $bitrate) { ForEach([128,192,256,320], id: \.self) { Text("\($0) kbps").tag($0) } } }
            }
            Text("另存为新的音频文件，原始录音保留。").font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("选择保存位置…") { if format.lossy && rate == 96000 { rate = 48000 }; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.exportRecording(recording, format: format, sampleRate: rate, bitRate: bitrate) } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 380).tint(StudioTheme.cyan).onChange(of: format) { _, value in if value.lossy && rate > 48000 { rate = 48000 } }
    }
}

struct PlaybackBar: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        HStack(spacing: 9) {
            Button { store.togglePlayback() } label: { Image(systemName: store.playerPlaying ? "pause.fill" : "play.fill").font(.system(size: 14)).frame(width: 24, height: 26) }.buttonStyle(StudioButtonStyle()).help("录音回放／暂停 · 空格")
            Button { store.replay() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 13)).frame(width: 20, height: 26) }.buttonStyle(StudioButtonStyle()).disabled(store.playingID == nil).help("从头重播")
            VStack(spacing: 4) {
                HStack {
                    Text(store.recordings.first { $0.id == store.playingID }?.name ?? "录音回放").lineLimit(1).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 5)
                    Text("\(timeString(store.playerPosition)) / \(timeString(store.playerDuration))").font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.muted)
                }
                Slider(value: Binding(get: { min(max(0, store.playerPosition), max(0.01, store.playerDuration)) }, set: { store.seek($0) }), in: 0...max(0.01, store.playerDuration), onEditingChanged: { store.playerSeeking = $0 }).controlSize(.small).disabled(store.playingID == nil).accessibilityLabel("回放进度")
            }
        }.foregroundStyle(StudioTheme.ink).padding(.horizontal, 12).frame(width: StudioLayout.inspector, height: 70).background(NativePanel())
    }
}
