import Foundation
import AVFoundation

enum SelfTest {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw FlowError(message) } }
    static func toneBuffer(frames: Int, offset: Int = 0, rate: Double = 48000, amplitude: Float = 0.5, frequency: Double = 1000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = sin(Float(Double(i + offset) * 2 * .pi * frequency / rate)) * amplitude } }
        return buffer
    }
    static func inspect(_ url: URL) throws -> (duration: Double, rms: Double, peak: Double, rate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var count = 0, sum = 0.0, peak = 0.0
        let skip = min(file.length / 10, Int64(file.processingFormat.sampleRate * 0.1))
        file.framePosition = skip
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for i in 0..<Int(buffer.frameLength) { let value = Double(samples[0][i]); sum += value * value; peak = max(peak, abs(value)); count += 1 }
        }
        return (Double(file.length) / file.processingFormat.sampleRate, sqrt(sum / Double(max(1, count))), peak, file.processingFormat.sampleRate, Int(file.processingFormat.channelCount))
    }
    static func run(folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        print("Checking graph validation and session persistence…")
        var s = Session.template("信号链测试")
        let saved = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(Session.self, from: saved)
        try check(s == restored, "会话 JSON 往返损坏")
        try s.validateForRun()
        s.wires.append(Wire(from: s.blocks[2].id, to: s.blocks[1].id))
        var rejected = false
        do { _ = try s.topologicalOrder() } catch { rejected = true }
        try check(rejected, "循环连线未被拦截")
        results.append(["test": "session_and_cycle_validation", "passed": true])
        print("Checking native exception recovery and corrupted parameters…")
        var recovered = false
        do { try AudioSafety.perform { SFThrowAudioTestException() } }
        catch { recovered = error.localizedDescription.contains("Input HW format is invalid") }
        try check(recovered, "原生硬件异常未被转换成可恢复错误")
        results.append(["test":"native_hardware_exception_recovery", "passed":true])
        var invalid = Session.template("信号链测试"); invalid.blocks[0].frequency = 1e300
        var invalidRejected = false
        do { try invalid.validateStructure() } catch { invalidRejected = true }
        try check(invalidRejected, "超大导入参数可能使界面数值转换溢出")
        invalid.blocks[0].frequency = 440; invalid.blocks[1].pan = .nan; invalidRejected = false
        do { try invalid.validateStructure() } catch { invalidRejected = true }
        try check(invalidRejected, "非有限模块参数未被拒绝")
        results.append(["test":"corrupted_parameter_validation", "passed":true])
        if !DeviceCatalog.hasDefaultInput() {
            let microphone = Session.template("麦克风录音")
            var rejectedMissingInput = false
            do { try AudioGraph().prepare(microphone, folder: folder) }
            catch { rejectedMissingInput = error.localizedDescription.contains("没有检测到麦克风") }
            try check(rejectedMissingInput, "缺少输入设备时没有安全拒绝麦克风启动")
            results.append(["test": "missing_microphone_guard", "passed": true, "input_device_available": false])
        }

        print("Checking real audio encoding, resampling and channel conversion…")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        for f in RecordingFormat.allCases {
            let rates: [Double] = f.lossy ? [44100, 48000] : [44100, 48000, 96000]
            for rate in rates {
                var block = AudioBlock(.recorder, x: 0, y: 0); block.format = f; block.sampleRate = rate; block.channels = rate == 44100 ? 1 : 2; block.filenamePrefix = "test-\(f.rawValue)-\(Int(rate))"
                if f == .mp3 && rate == 48000 { block.bitRate = 320 }
                let writer = try NodeRecorder(block: block, sessionID: s.id, folder: folder, inputFormat: format)
                var record: Recording?, failure: String?
                writer.onComplete = { record = $0 }; writer.onError = { failure = $0 }
                var offset = 0
                while offset < 52800 { let n = min(1024, 52800 - offset); try writer.writeSynchronously(toneBuffer(frames: n, offset: offset)); offset += n }
                writer.finish()
                if let failure { throw FlowError("\(f.rawValue)/\(rate)：\(failure)") }
                guard let record else { throw FlowError("\(f.rawValue) 没有输出文件") }
                let data = try inspect(record.url)
                try check(abs(data.duration - 1.1) < 0.12, "\(f.rawValue) 输出时长不正确：\(data.duration)")
                try check(abs(data.rate - rate) < 1, "采样率未生效")
                try check(data.channels == block.channels, "声道转换未生效")
                try check(data.rms > 0.2 && data.rms < 0.5, "\(f.rawValue) 音频为空或失真")
                try check(record.bytes > 100, "音频文件不完整")
                results.append(["test": "encode_\(f.rawValue)_\(Int(rate))", "passed": true, "duration": data.duration, "sample_rate": data.rate, "channels": data.channels, "rms": data.rms, "file": record.url.lastPathComponent])
            }
        }

        print("Checking pause/resume and split without silent padding…")
        var block = AudioBlock(.recorder, x: 0, y: 0); block.format = .wav; block.filenamePrefix = "pause-split"
        let writer = try NodeRecorder(block: block, sessionID: s.id, folder: folder, inputFormat: format)
        var parts: [Recording] = []
        writer.onComplete = { parts.append($0) }
        writer.consume(toneBuffer(frames: 4800))
        writer.setPaused(true); writer.consume(toneBuffer(frames: 9600)); writer.setPaused(false)
        writer.consume(toneBuffer(frames: 4800)); writer.split(); writer.consume(toneBuffer(frames: 4800)); writer.finish()
        try check(parts.count == 2, "分段文件数量错误")
        try check(abs(parts.reduce(0) { $0 + $1.duration } - 0.3) < 0.001, "暂停时长被写进文件")
        results.append(["test": "pause_resume_split", "passed": true, "parts": parts.count, "duration": parts.reduce(0) { $0 + $1.duration }])

        print("Checking Core Audio routing, fan-out, gain and ten-band EQ…")
        var session = Session(); session.name = "DSP verification"
        var tone = AudioBlock(.tone, x: 0, y: 0); tone.gain = 0; tone.frequency = 1000
        var gain = AudioBlock(.gain, x: 230, y: 0); gain.gain = -12
        var eq = AudioBlock(.equalizer, x: 230, y: 230); eq.bands[5] = -12
        var direct = AudioBlock(.recorder, x: 460, y: 0); direct.format = .wav; direct.filenamePrefix = "graph-reference"
        var attenuated = AudioBlock(.recorder, x: 460, y: 230); attenuated.format = .wav; attenuated.filenamePrefix = "graph-gain"
        var equalized = AudioBlock(.recorder, x: 460, y: 460); equalized.format = .wav; equalized.filenamePrefix = "graph-eq"
        session.blocks = [tone, gain, eq, direct, attenuated, equalized]
        session.wires = [Wire(from: tone.id, to: direct.id), Wire(from: tone.id, to: gain.id), Wire(from: gain.id, to: attenuated.id), Wire(from: tone.id, to: eq.id), Wire(from: eq.id, to: equalized.id)]
        let graph = AudioGraph()
        var graphFiles: [UUID: Recording] = [:], graphError: String?
        let resultLock = NSLock()
        graph.onRecording = { record in resultLock.lock(); if let recorderID = record.recorderID { graphFiles[recorderID] = record }; resultLock.unlock() }
        graph.onError = { graphError = $0 }
        try graph.prepare(session, folder: folder, offline: true); try graph.startOffline(); try graph.renderOffline(frames: 96000); await graph.stop()
        if let graphError { throw FlowError(graphError) }
        guard let referenceFile = graphFiles[direct.id], let gainFile = graphFiles[attenuated.id], let eqFile = graphFiles[equalized.id] else { throw FlowError("音频图没有写出所有分支") }
        let reference = try inspect(referenceFile.url), gained = try inspect(gainFile.url), equal = try inspect(eqFile.url)
        try check(reference.rms > 0.2, "Core Audio 图输出静音")
        let gainDB = 20 * log10(gained.rms / reference.rms), eqDB = 20 * log10(equal.rms / reference.rms)
        try check(abs(gainDB + 12) < 0.3, "增益没有真实生效：\(gainDB) dB")
        try check(eqDB < -9 && eqDB > -15, "均衡器没有真实生效：\(eqDB) dB")
        try check(abs(reference.duration - 2) < 0.1, "图录音时长错误")
        try check(abs(gained.duration - 2) < 0.001 && abs(equal.duration - 2) < 0.001, "处理分支在停止时丢失了尾部缓冲")
        results.append(["test": "graph_fanout_gain_eq", "passed": true, "gain_db": gainDB, "eq_db": eqDB, "reference_rms": reference.rms, "duration": reference.duration])

        print("Checking Core Audio fan-in mixing and limiter…")
        var mixSession = Session(); mixSession.name = "Mix verification"
        var t1 = AudioBlock(.tone, x: 0, y: 0); t1.frequency = 440; t1.gain = 0
        var t2 = AudioBlock(.tone, x: 0, y: 200); t2.frequency = 880; t2.gain = 0
        var mixer = AudioBlock(.mixer, x: 230, y: 0); mixer.gain = -6
        let limiter = AudioBlock(.limiter, x: 460, y: 0)
        var mixRec = AudioBlock(.recorder, x: 690, y: 0); mixRec.format = .wav; mixRec.filenamePrefix = "graph-mix"
        mixSession.blocks = [t1,t2,mixer,limiter,mixRec]
        mixSession.wires = [Wire(from: t1.id, to: mixer.id), Wire(from: t2.id, to: mixer.id), Wire(from: mixer.id, to: limiter.id), Wire(from: limiter.id, to: mixRec.id)]
        let mixGraph = AudioGraph(); var mixed: Recording?
        mixGraph.onRecording = { mixed = $0 }
        try mixGraph.prepare(mixSession, folder: folder, offline: true); try mixGraph.startOffline(); try mixGraph.renderOffline(frames: 96000); await mixGraph.stop()
        guard let mixed else { throw FlowError("混音分支未输出") }
        let mix = try inspect(mixed.url)
        try check(abs(mix.rms - 0.2506) < 0.025, "多输入混音结果错误：\(mix.rms)")
        try check(mix.peak <= 1.001, "限幅输出过载")
        results.append(["test": "graph_fanin_limiter", "passed": true, "rms": mix.rms, "peak": mix.peak])

        print("Checking actual overload limiting and dynamic compression…")
        for kind in [BlockKind.limiter, .compressor] {
            var dspSession = Session()
            var source = AudioBlock(.tone, x: 0, y: 0); source.frequency = 1000; source.gain = 12
            var effect = AudioBlock(kind, x: 230, y: 0); effect.threshold = -24; effect.headroom = 1
            var rec = AudioBlock(.recorder, x: 460, y: 0); rec.format = .wav; rec.bitDepth = 32; rec.filenamePrefix = "overload-" + kind.rawValue
            dspSession.blocks = [source, effect, rec]
            dspSession.wires = [Wire(from: source.id, to: effect.id), Wire(from: effect.id, to: rec.id)]
            let dsp = AudioGraph(); var result: Recording?
            dsp.onRecording = { result = $0 }
            try dsp.prepare(dspSession, folder: folder, offline: true); try dsp.startOffline(); try dsp.renderOffline(frames: 96000); await dsp.stop()
            guard let result else { throw FlowError("动态处理未输出") }
            let audio = try inspect(result.url)
            if kind == .limiter { try check(audio.peak <= 1.001 && audio.rms > 0.3, "限幅器未限制真实过载：\(audio.peak)") }
            else { try check(audio.rms > 0.001 && audio.rms < 0.4, "压缩器没有压低超过阈值的信号：\(audio.rms)") }
            results.append(["test": "overload_" + kind.rawValue, "passed": true, "rms": audio.rms, "peak": audio.peak, "file": result.url.lastPathComponent])
        }

        print("Checking local file source and processing…")
        var fileSession = Session()
        var fileSource = AudioBlock(.file, x: 0, y: 0); fileSource.filePath = referenceFile.url.path; fileSource.loop = false; fileSource.gain = -6
        var fileRec = AudioBlock(.recorder, x: 230, y: 0); fileRec.format = .wav; fileRec.filenamePrefix = "file-source"
        fileSession.blocks = [fileSource, fileRec]; fileSession.wires = [Wire(from: fileSource.id, to: fileRec.id)]
        let fileGraph = AudioGraph(); var processed: Recording?
        fileGraph.onRecording = { processed = $0 }
        try fileGraph.prepare(fileSession, folder: folder, offline: true); try fileGraph.startOffline(); try fileGraph.renderOffline(frames: 72000); await fileGraph.stop()
        guard let processed else { throw FlowError("文件音源未输出") }
        let fileAudio = try inspect(processed.url), fileGain = 20 * log10(fileAudio.rms / reference.rms)
        try check(abs(fileGain + 6) < 0.3 && abs(fileAudio.duration - 1.5) < 0.001, "本地文件处理失败：\(fileGain) dB / \(fileAudio.duration) s")
        results.append(["test": "local_file_source", "passed": true, "gain_db": fileGain, "duration": fileAudio.duration])

        print("Checking automatic timed file segmentation…")
        var autoBlock = AudioBlock(.recorder, x: 0, y: 0); autoBlock.format = .wav; autoBlock.splitMinutes = 0.001; autoBlock.filenamePrefix = "automatic-split"
        let autoWriter = try NodeRecorder(block: autoBlock, sessionID: session.id, folder: folder, inputFormat: format)
        var automatic: [Recording] = []
        autoWriter.onComplete = { automatic.append($0) }
        for i in 0..<3 { try autoWriter.writeSynchronously(toneBuffer(frames: 4800, offset: i * 4800)) }
        autoWriter.finish()
        try check(automatic.count == 3 && abs(automatic.reduce(0) { $0 + $1.duration } - 0.3) < 0.001, "自动分段丢失了音频或生成了空文件")
        results.append(["test": "automatic_segmentation", "passed": true, "parts": automatic.count])

        print("Checking waveform extraction…")
        let wave = RecordingAnalysis.waveform(url: referenceFile.url)
        try check(wave.count == 120 && (wave.max() ?? 0) > 0.9, "波形提取失败")
        results.append(["test": "waveform", "passed": true, "bins": wave.count])
        print("Checking repeated graph start/stop and recovery after missing input…")
        for cycle in 0..<20 {
            let graph = AudioGraph()
            if !DeviceCatalog.hasDefaultInput() {
                do { try await graph.start(.template("麦克风录音"), folder: folder); throw FlowError("无麦克风时意外启动") }
                catch { try check(error.localizedDescription.contains("没有检测到麦克风"), "缺输入设备的错误路径异常") }
            }
            var session = Session.template("信号链测试")
            session.blocks[2].format = .wav; session.blocks[2].filenamePrefix = "lifecycle-\(cycle)"
            var files: [Recording] = []
            graph.onRecording = { files.append($0) }
            try graph.prepare(session, folder: folder, offline: true); try graph.startOffline(); try graph.renderOffline(frames: 9600)
            await graph.stop()
            try check(files.count == 1 && abs(files[0].duration - 0.2) < 0.001, "反复启停出现丢失／重复文件，轮次 \(cycle)")
        }
        results.append(["test":"twenty_start_stop_recovery_cycles", "passed":true, "cycles":20])
        results += try RecordingNamingChecks.run(folder: folder)
        results += try await ApplicationWorkflowChecks.run(folder: folder)
        let report: [String: Any] = ["app": "SoundFlow", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "platform": ProcessInfo.processInfo.operatingSystemVersionString, "date": ISO8601DateFormatter().string(from: Date()), "passed": true, "tests": results, "not_covered": ["Interactive macOS Screen/System Audio permission", "Interactive microphone permission", "User-chosen hardware input/output devices"]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("verification.json"), options: .atomic)
        print("Verified \(results.count) checks; report: \(folder.appendingPathComponent("verification.json").path)")
    }
}
