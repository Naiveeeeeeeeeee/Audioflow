import AppKit
import AVFoundation

@MainActor enum BackgroundChecks {
    static func run(folder: URL, helper: URL, alternative: URL? = nil) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tone = folder.appendingPathComponent("input-tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: tone, settings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:48000, AVNumberOfChannelsKey:2, AVLinearPCMBitDepthKey:24])
        try file?.write(from: SelfTest.toneBuffer(frames: 96000)); file = nil
        let commands = Pipe(), emitter = Process()
        emitter.executableURL = helper; emitter.arguments = [tone.path]; emitter.standardInput = commands
        emitter.standardOutput = FileHandle.nullDevice; emitter.standardError = FileHandle.nullDevice
        try emitter.run()
        defer { if emitter.isRunning { emitter.terminate() } }
        func command(_ text: String) { commands.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        try await Task.sleep(nanoseconds: 600_000_000)
        var results: [[String: Any]] = []
        for kind in [BlockKind.system, .application] {
            guard emitter.isRunning else { throw FlowError("后台验证音源未能启动。") }
            command("play")
            try await Task.sleep(nanoseconds: 200_000_000)
            var session = Session()
            var source = AudioBlock(kind, x: 0, y: 0); source.bundleID = "studio.twiggy.SoundFlow.BackgroundEmitter"
            var rec = AudioBlock(.recorder, x: 192, y: 0); rec.format = .wav; rec.filenamePrefix = "background-" + kind.rawValue
            session.blocks = [source,rec]; session.wires = [Wire(from: source.id,to: rec.id)]
            let graph = AudioGraph(), records = LockedRecords()
            graph.onRecording = { records.append($0) }
            graph.onError = { records.fail($0) }
            try await graph.start(session, folder: folder)
            try await Task.sleep(nanoseconds: 650_000_000)
            command("pause")
            let other = Process(); other.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); other.arguments = ["-v","0.01",tone.path]
            other.standardOutput = FileHandle.nullDevice; other.standardError = FileHandle.nullDevice
            try other.run()
            try await Task.sleep(nanoseconds: 700_000_000)
            await graph.stop()
            if other.isRunning { other.terminate() }
            guard records.errors.isEmpty, let result = records.records.first, records.records.count == 1 else { throw FlowError("后台采集失败：" + records.errors.joined(separator: "; ")) }
            let audio = try SelfTest.inspect(result.url)
            try SelfTest.check(audio.rms > 0.0005 && audio.duration > 1, "后台采集没有真实音频。")
            let read = try AVAudioFile(forReading: result.url)
            let tailFrames = min(read.length, Int64(read.processingFormat.sampleRate * 0.3))
            read.framePosition = read.length - tailFrames
            let tail = AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(tailFrames))!
            try read.read(into: tail)
            let tailLevel = measurePCM(tail)
            if kind == .application { try SelfTest.check(tailLevel.rms <= -89, "目标应用暂停后仍混入了其他进程的声音。") }
            else { try SelfTest.check(tailLevel.rms > -85, "系统声音采集漏掉了其他进程。") }
            results.append(["test":"background_" + kind.rawValue + "_capture", "passed":true, "duration":audio.duration,"rms":audio.rms,"tail_rms_db":tailLevel.rms,"file":result.url.lastPathComponent])
        }
        if let alternative {
            let secondTone = folder.appendingPathComponent("input-tone-440.wav")
            var secondFile: AVAudioFile? = try AVAudioFile(forWriting: secondTone, settings: [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:24])
            try secondFile?.write(from: SelfTest.toneBuffer(frames:96000,frequency:440)); secondFile = nil
            let second = Process(), secondCommands = Pipe()
            second.executableURL = alternative; second.arguments = [secondTone.path]; second.standardInput = secondCommands
            second.standardOutput = FileHandle.nullDevice; second.standardError = FileHandle.nullDevice
            try second.run(); defer { if second.isRunning { second.terminate() } }
            try await Task.sleep(nanoseconds:600_000_000)
            command("play"); secondCommands.fileHandleForWriting.write(Data("play\n".utf8))
            let store = StudioStore(baseOverride:folder.appendingPathComponent("SwitchState"),registerSystemEvents:false)
            var session = Session.template("应用录音",appID:"studio.twiggy.SoundFlow.BackgroundEmitter")
            let sourceID = session.blocks[0].id
            session.blocks[2].format = .wav; session.blocks[2].filenamePrefix = "live-switch"
            store.sessions = [session]; store.selectedSessionID = session.id
            await store.start()
            try SelfTest.check(store.running && store.error == nil,"切换验证未能开始录音")
            try await Task.sleep(nanoseconds:650_000_000)
            store.selectRecordingApplication(sourceID,bundleID:"studio.twiggy.SoundFlow.BackgroundEmitterB")
            try await waitForStore(store)
            try SelfTest.check(store.running && store.session.blocks[0].bundleID.hasSuffix("EmitterB") && store.error == nil,"录制应用没有成功切换")
            try await Task.sleep(nanoseconds:650_000_000)
            store.selectRecordingApplication(sourceID,bundleID:"studio.twiggy.SoundFlow.UnavailableTestSource")
            try await waitForStore(store)
            try SelfTest.check(store.running && store.session.blocks[0].bundleID.hasSuffix("EmitterB") && store.error != nil,"切换失败后没有保留原音源")
            store.error = nil
            try await Task.sleep(nanoseconds:350_000_000)
            store.stop(); try await waitForStore(store)
            try SelfTest.check(store.recordings.count == 1,"切换过程截断或丢失了当前录音")
            let record = store.recordings[0]
            let before = try spectralAmplitudes(record.url, offset:0.15,duration:0.25)
            let read = try AVAudioFile(forReading:record.url)
            let after = try spectralAmplitudes(record.url,offset:Double(read.length)/48000 - 0.3,duration:0.25)
            try SelfTest.check(before[0] > 0.002 && before[0] > before[1] * 8,"切换前不是指定的 1000 Hz 应用")
            try SelfTest.check(after[1] > 0.002 && after[1] > after[0] * 8,"切换后没有改录 440 Hz 应用，或混入了旧应用")
            let saved = try JSONDecoder().decode([Recording].self,from:Data(contentsOf:folder.appendingPathComponent("SwitchState/recordings.json")))
            try SelfTest.check(saved.count == 1,"停止后录音库索引未保存完整")
            await store.shutdown()
            results.append(["test":"live_application_switch_and_failure_rollback","passed":true,"continuous_files":1,"before_1000hz":before[0],"before_440hz":before[1],"after_1000hz":after[0],"after_440hz":after[1],"file":record.url.lastPathComponent])
            second.terminate()
            for _ in 0..<100 where second.isRunning { try await Task.sleep(nanoseconds:20_000_000) }
            try SelfTest.check(!second.isRunning, "自动启动验证前音源未退出")
            let appURL = alternative.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let entry = try store.addApplication(appURL)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            try await store.ensureApplicationRunning(entry.id)
            guard let launched = NSRunningApplication.runningApplications(withBundleIdentifier: entry.id).first else { throw FlowError("未能启动手动添加的未运行应用") }
            defer { launched.terminate() }
            try SelfTest.check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "后台启动应用抢占前台")
            results.append(["test":"saved_application_background_launch", "passed":true, "foreground_unchanged":true])

        }
        command("quit")
        let report: [String:Any] = ["passed":true,"foreground_windows_created":false,"tests":results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("background-verification.json"))
        print("BACKGROUND_CAPTURE_PASS")
    }
    private static func waitForStore(_ store: StudioStore) async throws {
        for _ in 0..<500 {
            if !store.busy { return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw FlowError("切换或保存操作超时")
    }
    private static func spectralAmplitudes(_ url: URL, offset: Double, duration: Double) throws -> [Double] {
        let file = try AVAudioFile(forReading:url), rate = 48000.0
        file.framePosition = max(0,Int64(offset * rate))
        let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(duration * rate))!
        try file.read(into:buffer)
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { throw FlowError("无法读取切换测试音频") }
        return [1000.0,440.0].map { frequency in
            var sine = 0.0, cosine = 0.0
            for i in 0..<Int(buffer.frameLength) {
                let angle = 2 * Double.pi * frequency * Double(i) / rate
                sine += Double(samples[0][i]) * sin(angle); cosine += Double(samples[0][i]) * cos(angle)
            }
            return 2 * sqrt(sine * sine + cosine * cosine) / Double(buffer.frameLength)
        }
    }
}

private final class LockedRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Recording] = []
    private var failures: [String] = []
    var records: [Recording] { lock.lock(); defer { lock.unlock() }; return saved }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    func append(_ record: Recording) { lock.lock(); saved.append(record); lock.unlock() }
    func fail(_ error: String) { lock.lock(); failures.append(error); lock.unlock() }
}
