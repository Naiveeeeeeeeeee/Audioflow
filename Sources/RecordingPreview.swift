import SwiftUI
import AppKit
import QuickLookUI

extension StudioStore {
    func quickLook(_ recording: Recording) {
        guard FileManager.default.fileExists(atPath: recording.url.path) else { error = "录音文件已移动或不存在：" + recording.url.path; return }
        previewRecording = recording
    }
}

struct NativeRecordingPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct RecordingPreviewSheet: View {
    @ObservedObject var store: StudioStore
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye").foregroundStyle(StudioTheme.cyan)
                Text(recording.url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).padding(6)
            }.padding(14)
            Divider()
            NativeRecordingPreview(url: recording.url).frame(minWidth: 520, minHeight: 300)
            Divider()
            HStack {
                Text(recording.format + " · " + ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file)).font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button { store.reveal(recording) } label: { Label("在 Finder 中显示", systemImage: "folder").font(.system(size: 12)).padding(7) }
            }.padding(10)
        }.buttonStyle(StudioButtonStyle()).foregroundStyle(StudioTheme.ink).preferredColorScheme(.light).background(StudioTheme.panel)
    }
}
