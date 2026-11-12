import SwiftUI
import AppKit

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: StudioStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.busy || store.running {
            Task { @MainActor in await store.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        store.save(); return .terminateNow
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        for window in NSApp.windows {
            window.title = store?.session.name ?? "录音"
            window.setFrameAutosaveName("SoundFlowCompactMain")
            window.isOpaque = true; window.backgroundColor = NSColor(srgbRed: 0.985, green: 0.988, blue: 0.99, alpha: 1)
            window.titlebarAppearsTransparent = false
            if !UserDefaults.standard.bool(forKey: "SoundFlow.compactWindowMigration1_2") {
                let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
                let size = NSSize(width: max(960, min(1080, visible.width)), height: min(600, visible.height - 50))
                window.setContentSize(size)
                var frame = window.frame
                frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
                frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
                window.setFrame(frame, display: false)
                UserDefaults.standard.set(true, forKey: "SoundFlow.compactWindowMigration1_2")
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first?.makeKeyAndOrderFront(nil) }; return true
    }
}

@main struct SoundFlowApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var store = StudioStore()
    init() {
        if Bundle.main.object(forInfoDictionaryKey: "SoundFlowUIReview") as? Bool == true {
            PreviewRenderer.reviewWindow()
            NSApplication.shared.run()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-smoke"), CommandLine.arguments.count > index + 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1]), helper = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            let alternative = CommandLine.arguments.count > index + 3 ? URL(fileURLWithPath: CommandLine.arguments[index + 3]) : nil
            Task { @MainActor in
                do { try await BackgroundChecks.run(folder: output, helper: helper, alternative: alternative); exit(0) }
                catch { fputs("BACKGROUND_CAPTURE_FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            while true { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try PreviewRenderer.render(folder: output); exit(0) }
                catch { fputs("PREVIEW_FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            while true { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        if CommandLine.arguments.contains("--self-test") {
            let output: String
            if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > index + 1 { output = CommandLine.arguments[index + 1] }
            else { output = FileManager.default.temporaryDirectory.appendingPathComponent("soundflow-test").path }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await SelfTest.run(folder: URL(fileURLWithPath: output)); print("SELF_TEST_PASS"); exit(0) }
                catch { fputs("SELF_TEST_FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
    }
    var body: some Scene {
        WindowGroup {
            StudioView(store: store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 1080, height: 600)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话…") { store.showTemplates = true }.keyboardShortcut("n").disabled(store.running || store.busy)
                Button("导入会话…") { store.importSession() }.keyboardShortcut("o").disabled(store.running || store.busy)
                Button("导出当前会话…") { store.exportSession() }.keyboardShortcut("s")
                Divider()
                Button("导入音频…") { store.importRecordings() }.keyboardShortcut("i")
            }
            CommandMenu("控制") {
                Button(store.running ? "停止会话" : "开始会话") { store.toggleRun() }.keyboardShortcut("r").disabled(store.busy)
                Button(store.paused ? "继续录音" : "暂停录音") { store.pauseRecording() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!store.running)
                Button("录音分段") { store.splitRecording() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.running)
                Divider()
                Button("播放／暂停录音") { store.togglePlayback() }
                Button("从头重播") { store.replay() }
            }
            CommandMenu("流程") {
                Button("复制当前会话") { store.duplicateSession() }.disabled(store.running || store.busy)
                Button("自动排列模块") { store.autoArrange() }.disabled(store.running || store.busy)
                Button("删除选中模块／连线") { store.deleteSelection() }.disabled(store.running || store.busy)
                Divider()
                ForEach(BlockKind.allCases) { kind in Button("添加" + kind.title) { store.addBlock(kind) }.disabled(store.running || store.busy) }
            }
            CommandGroup(replacing: .help) {
                Button("显示录音文件夹") { try? FileManager.default.createDirectory(at: store.recordFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(store.recordFolder) }
            }
        }
    }
}
