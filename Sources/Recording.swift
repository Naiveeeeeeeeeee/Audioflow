import Foundation
import AVFoundation

func clonePCM(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for i in 0..<min(source.count, target.count) {
        if let from = source[i].mData, let to = target[i].mData {
            memcpy(to, from, Int(source[i].mDataByteSize))
        }
    }
    return copy
}

func measurePCM(_ buffer: AVAudioPCMBuffer) -> Level {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return Level() }
    let count = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
    var peaks = [Float](repeating: 0, count: max(2, channels)), sum: Double = 0
    for c in 0..<channels {
        for i in 0..<count {
            let value = data[c][i]
            peaks[c] = max(peaks[c], abs(value)); sum += Double(value * value)
        }
    }
    if channels == 1 { peaks[1] = peaks[0] }
    func db(_ x: Float) -> Float { max(-90, 20 * log10(max(0.0000316, x))) }
    return Level(left: db(peaks[0]), right: db(peaks[1]), rms: db(Float(sqrt(sum / Double(count * channels)))), clipped: peaks.max()! >= 1)
}

final class NodeRecorder {
    let blockID: UUID
    let sessionID: UUID
    let folder: URL
    private var spec: AudioBlock
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var finalURL: URL?
    private var converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var frames: AVAudioFramePosition = 0
    private var reservationURL: URL?
    private let sourceName: String
    private var pending = 0
    private var failed = false
    private var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    private let lock = NSLock()
    private var paused = false
    private var accepting = true
    private let queue = DispatchQueue(label: "soundflow.disk", qos: .userInitiated)
    var onComplete: ((Recording) -> Void)?
    var onError: ((String) -> Void)?
    var onFrames: ((UUID, Double) -> Void)?
    private var sessionSeconds: Double = 0

    init(block: AudioBlock, sessionID: UUID, folder: URL, inputFormat: AVAudioFormat, sourceName: String = "") throws {
        self.blockID = block.id; self.sessionID = sessionID; self.folder = folder; self.spec = block
        self.sourceName = sourceName
        self.inputFormat = inputFormat
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: block.sampleRate, channels: AVAudioChannelCount(block.channels))!
        if inputFormat != outputFormat { converter = AVAudioConverter(from: inputFormat, to: outputFormat) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if block.format == .mp3 && Self.encoderURL == nil { throw FlowError("找不到随程序提供的 MP3 编码器。请重新构建完整应用。") }
        try openFile()
    }

    static var encoderURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if let path = ProcessInfo.processInfo.environment["SOUNDFLOW_FFMPEG"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    private func openFile() throws {
        frames = 0
        let reserved = try RecordingNaming.reserve(folder: folder, source: sourceName, ext: spec.format.ext)
        let final = reserved.file
        reservationURL = reserved.reservation
        let working = spec.format == .mp3 ? folder.appendingPathComponent("." + final.deletingPathExtension().lastPathComponent + ".source.wav") : final
        let native = spec.format == .mp3 ? RecordingFormat.wav : spec.format
        var settings: [String: Any] = [AVFormatIDKey: native.nativeID, AVSampleRateKey: spec.sampleRate, AVNumberOfChannelsKey: spec.channels]
        if native == .wav || native == .aiff {
            settings[AVLinearPCMBitDepthKey] = spec.format == .mp3 ? 16 : spec.bitDepth
            settings[AVLinearPCMIsFloatKey] = spec.bitDepth == 32 && spec.format != .mp3
            settings[AVLinearPCMIsBigEndianKey] = native == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        } else if native == .aac {
            settings[AVEncoderBitRateKey] = spec.bitRate * 1000
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        } else if native == .alac {
            settings[AVEncoderBitDepthHintKey] = spec.bitDepth == 32 ? 24 : spec.bitDepth
        } else if native == .flac {
            settings[AVEncoderBitDepthHintKey] = spec.bitDepth == 32 ? 24 : spec.bitDepth
        }
        do { file = try AVAudioFile(forWriting: working, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { try? FileManager.default.removeItem(at: reserved.reservation); reservationURL = nil; throw error }
        fileURL = working; finalURL = final
    }

    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting && !paused && !failed else { lock.unlock(); return }
        guard pending < 128 else {
            failed = true; lock.unlock()
            onError?("磁盘写入跟不上音频，录音已停止，已写入部分仍会保留。请检查磁盘空间。")
            return
        }
        pending += 1; lock.unlock()
        guard let copy = clonePCM(buffer) else { lock.lock(); pending -= 1; lock.unlock(); return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            do { try self.write(copy) }
            catch { self.fail(error.localizedDescription) }
        }
    }

    // Used by deterministic offline verification; no real-time capture or permissions.
    func writeSynchronously(_ buffer: AVAudioPCMBuffer) throws { try queue.sync { try write(buffer) } }

    private func write(_ input: AVAudioPCMBuffer) throws {
        guard file != nil, !hasFailed else { return }
        var buffer = input
        if let converter {
            let cap = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 256)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: cap) else { throw FlowError("无法分配重采样缓冲区。") }
            var supplied = false, error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            if status == .error { throw FlowError("音频重采样失败。") }
            buffer = converted
        }
        if buffer.frameLength > 0 {
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            sessionSeconds += Double(buffer.frameLength) / outputFormat.sampleRate
            onFrames?(blockID, sessionSeconds)
        }
        if spec.splitMinutes > 0 && Double(frames) / outputFormat.sampleRate >= spec.splitMinutes * 60 { try closeFile(); try openFile() }
    }

    func split() { queue.async { [weak self] in
        guard let self, !self.hasFailed else { return }
        do { try self.closeFile(); try self.openFile() } catch { self.fail(error.localizedDescription) }
    } }

    func finish() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {
            do {
                if let converter, file != nil, !hasFailed {
                    let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048)!
                    var error: NSError?
                    _ = converter.convert(to: tail, error: &error) { _, status in status.pointee = .endOfStream; return nil }
                    if tail.frameLength > 0 { try file?.write(from: tail); frames += AVAudioFramePosition(tail.frameLength) }
                }
                try closeFile()
            } catch { fail(error.localizedDescription) }
        }
    }

    private func fail(_ message: String) { lock.lock(); let first = !failed; failed = true; lock.unlock(); if first { onError?(message) } }

    private func closeFile() throws {
        let reservation = reservationURL; reservationURL = nil
        defer { if let reservation { try? FileManager.default.removeItem(at: reservation) } }
        file = nil
        guard let working = fileURL, let final = finalURL else { return }
        fileURL = nil; finalURL = nil
        guard frames > 0 else { try? FileManager.default.removeItem(at: working); return }
        if spec.format == .mp3 {
            guard let encoder = Self.encoderURL else { throw FlowError("MP3 编码器不可用，原始 WAV 已保留。") }
            let process = Process(); process.executableURL = encoder
            process.arguments = ["-nostdin", "-v", "error", "-i", working.path, "-c:a", "libmp3lame", "-b:a", "\(spec.bitRate)k", "-ar", "\(Int(spec.sampleRate))", "-ac", "\(spec.channels)", "-n", final.path]
            let errors = Pipe(); process.standardError = errors
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FlowError("MP3 导出失败，原始 WAV 已保留。\n" + String(data: data, encoding: .utf8)!) }
            try? FileManager.default.removeItem(at: working)
        }
        let audio = try AVAudioFile(forReading: final)
        let size = (try FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value ?? 0
        let recording = Recording(url: final, sessionID: sessionID, name: final.deletingPathExtension().lastPathComponent, duration: Double(audio.length) / audio.processingFormat.sampleRate, format: spec.format.rawValue.uppercased(), sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount), bytes: size, recorderID: blockID)
        onComplete?(recording)
    }
}

enum RecordingAnalysis {
    static func waveform(url: URL, bins: Int = 120) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return [] }
        var points = [Float](repeating: 0, count: bins), position: Int64 = 0
        while position < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - position))) }
            catch { break }
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                let bin = min(bins - 1, Int((position + Int64(i)) * Int64(bins) / max(1, file.length)))
                for c in 0..<Int(format.channelCount) { points[bin] = max(points[bin], abs(samples[c][i])) }
            }
            position += Int64(buffer.frameLength)
        }
        let peak = max(0.0001, points.max() ?? 1)
        return points.map { min(1, $0 / peak) }
    }
}
