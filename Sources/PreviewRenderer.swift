import SwiftUI
import AppKit
import AVFoundation

@MainActor enum PreviewRenderer {
    private static var reviewWindowReference: NSWindow?
    static func reviewWindow() {
        NSApplication.shared.finishLaunching()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhideWithoutActivation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoundFlow-UIReview-" + UUID().uuidString)
        let store = StudioStore(baseOverride: folder, registerSystemEvents: false)
        let tone = folder.appendingPathComponent("界面核对音频.wav")
        if let audio = try? AVAudioFile(forWriting: tone, settings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:48000, AVNumberOfChannelsKey:2, AVLinearPCMBitDepthKey:16]) {
            try? audio.write(from: SelfTest.toneBuffer(frames: 48000))
            store.recordings = [Recording(url:tone, sessionID:store.session.id, name:"界面核对音频", duration:1, format:"WAV", sampleRate:48000, channels:2, bytes:192000)]
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1080, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        reviewWindowReference = window
        window.title = "界面核对"; window.isReleasedWhenClosed = false
        window.isOpaque = true; window.backgroundColor = NSColor(srgbRed: 0.985, green: 0.988, blue: 0.99, alpha: 1)
        window.titlebarAppearsTransparent = false
        window.contentView = NSHostingView(rootView: StudioView(store: store))
        window.orderBack(nil)
        Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { _ in exit(0) }
    }
    static func render(folder: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = StudioStore(baseOverride: folder.appendingPathComponent("PreviewState"), registerSystemEvents: false)
        try snapshot(store: store, to: folder.appendingPathComponent("compact.png"))
        store.running = true; store.status = "录制中"; store.elapsed = 84
        for (index, block) in store.session.blocks.enumerated() {
            let measured = measurePCM(SelfTest.toneBuffer(frames: 4800, amplitude: index == 0 ? 0.4 : 0.32))
            store.levels[block.id] = measured
        }
        try snapshot(store: store, to: folder.appendingPathComponent("recording.png"))
        store.running = false; store.levels = [:]; store.status = "就绪"; store.elapsed = 0

        store.sessions = [Session.template("双路混音", appID: store.apps.first(where: { $0.id.localizedCaseInsensitiveContains("qqmusic") })?.id ?? "")]
        store.selectedSessionID = store.sessions[0].id
        store.selectedBlockID = store.sessions[0].blocks.first(where: { $0.kind == .mixer })?.id
        try snapshot(store: store, to: folder.appendingPathComponent("branches.png"))
        print("PREVIEW_PASS \(folder.path)")
    }
    private static func snapshot(store: StudioStore, to url: URL) throws {
        // This window is never ordered onto the user's desktop. AppKit renders native
        // scroll views and materials that SwiftUI ImageRenderer cannot rasterize.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1080, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StudioView(store: store).frame(width: 1080, height: 600))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw FlowError("无法创建界面位图。") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw FlowError("界面位图编码失败。") }
        try data.write(to: url)
        window.close()
    }
}
