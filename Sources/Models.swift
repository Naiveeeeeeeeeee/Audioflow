import Foundation
import AVFoundation
import AppKit

enum BlockKind: String, Codable, CaseIterable, Identifiable {
    case application, system, microphone, file, tone, mixer, gain, equalizer, compressor, limiter, meter, recorder, output
    var id: String { rawValue }
    var title: String {
        switch self {
        case .application: return "应用声音"
        case .system: return "系统声音"
        case .microphone: return "麦克风"
        case .file: return "音频文件"
        case .tone: return "测试音"
        case .mixer: return "混音器"
        case .gain: return "音量"
        case .equalizer: return "十段均衡器"
        case .compressor: return "压缩器"
        case .limiter: return "限幅器"
        case .meter: return "电平表"
        case .recorder: return "录音机"
        case .output: return "监听输出"
        }
    }
    var symbol: String {
        switch self {
        case .application: return "macwindow"
        case .system: return "desktopcomputer"
        case .microphone: return "mic.fill"
        case .file: return "waveform"
        case .tone: return "waveform.path"
        case .mixer: return "arrow.triangle.merge"
        case .gain: return "slider.horizontal.3"
        case .equalizer: return "slider.vertical.3"
        case .compressor: return "waveform.path.ecg"
        case .limiter: return "waveform.badge.minus"
        case .meter: return "chart.bar.xaxis"
        case .recorder: return "record.circle"
        case .output: return "speaker.wave.2.fill"
        }
    }
    var detail: String {
        switch self {
        case .application: return "单独采集一个应用的声音"
        case .system: return "采集系统播放的声音"
        case .microphone: return "使用默认音频输入设备"
        case .file: return "播放本地文件作为音源"
        case .tone: return "生成正弦波，检查信号链"
        case .mixer: return "将多路输入叠加为一路"
        case .gain: return "调整增益与左右声像"
        case .equalizer: return "31 Hz 到 16 kHz 十段调节"
        case .compressor: return "控制动态，平衡声音大小"
        case .limiter: return "限制瞬时峰值，降低过载"
        case .meter: return "显示实际峰值与 RMS"
        case .recorder: return "保存音频、暂停与分段"
        case .output: return "选择设备并监听处理后的声音"
        }
    }
    var isSource: Bool { [.application, .system, .microphone, .file, .tone].contains(self) }
    var category: String { isSource ? "声音来源" : (self == .recorder || self == .output ? "录制与输出" : "处理与分析") }
}

enum RecordingFormat: String, Codable, CaseIterable, Identifiable {
    case wav, aiff, aac, alac, flac, mp3
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wav: return "WAV · 无压缩"
        case .aiff: return "AIFF · 无压缩"
        case .aac: return "AAC · M4A"
        case .alac: return "ALAC · 无损 M4A"
        case .flac: return "FLAC · 无损"
        case .mp3: return "MP3"
        }
    }
    var ext: String { self == .aac || self == .alac ? "m4a" : rawValue }
    var lossy: Bool { self == .aac || self == .mp3 }
    var nativeID: AudioFormatID {
        switch self {
        case .aac: return kAudioFormatMPEG4AAC
        case .alac: return kAudioFormatAppleLossless
        case .flac: return kAudioFormatFLAC
        default: return kAudioFormatLinearPCM
        }
    }
}

struct AudioBlock: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: BlockKind
    var name: String
    var x: Double
    var y: Double
    var enabled = true
    var bundleID = ""
    var filePath = ""
    var loop = false
    var gain: Double = 0
    var pan: Double = 0
    var bands = [Double](repeating: 0, count: 10)
    var threshold: Double = -18
    var headroom: Double = 6
    var attack: Double = 0.01
    var release: Double = 0.15
    var frequency: Double = 440
    var monitor = false
    var outputDeviceID: UInt32 = 0
    var format: RecordingFormat = .aac
    var sampleRate: Double = 48000
    var channels = 2
    var bitDepth = 24
    var bitRate = 256
    var splitMinutes: Double = 0
    var filenamePrefix = "录音"
    init(_ kind: BlockKind, x: Double, y: Double) {
        self.kind = kind; self.name = kind.title; self.x = x; self.y = y
        if kind == .tone { gain = -18 }
    }
}

struct Wire: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var from: UUID
    var to: UUID
}

struct Schedule: Codable, Equatable {
    var enabled = false
    var date = Date().addingTimeInterval(3600)
    var durationMinutes: Double = 30
}

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "应用录音"
    var blocks: [AudioBlock] = []
    var wires: [Wire] = []
    var schedule = Schedule()
    var created = Date()
    var schemaVersion = 1
    static func template(_ type: String, appID: String = "") -> Session {
        var s = Session(); s.name = type
        let source: BlockKind = type == "系统录音" ? .system : type == "麦克风录音" ? .microphone : type == "信号链测试" ? .tone : type == "文件处理" ? .file : .application
        var input = AudioBlock(source, x: 20, y: 56); input.bundleID = appID
        let gain = AudioBlock(.gain, x: 176, y: 56)
        let recorder = AudioBlock(.recorder, x: 332, y: 56)
        let output = AudioBlock(.output, x: 488, y: 56)
        s.blocks = [input, gain, recorder, output]
        s.wires = [Wire(from: input.id, to: gain.id), Wire(from: gain.id, to: recorder.id), Wire(from: recorder.id, to: output.id)]
        if type == "双路混音" {
            s.blocks[0].y = 32
            var mic = AudioBlock(.microphone, x: 20, y: 224); mic.gain = -6
            s.blocks.append(mic)
            s.blocks[1].kind = .mixer; s.blocks[1].name = "混音器"
            s.wires.append(Wire(from: mic.id, to: gain.id))
        }
        return s
    }
    func topologicalOrder() throws -> [UUID] {
        guard blocks.count <= 64, wires.count <= 256 else { throw FlowError("会话过大：最多支持 64 个模块和 256 条连线。") }
        let ids = Set(blocks.map(\.id))
        guard ids.count == blocks.count else { throw FlowError("会话包含重复模块。") }
        var degrees = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, 0) })
        var pairs = Set<String>()
        for w in wires {
            guard ids.contains(w.from), ids.contains(w.to), w.from != w.to else { throw FlowError("会话中有无效连线。") }
            guard let target = blocks.first(where: { $0.id == w.to }), !target.kind.isSource else { throw FlowError("声音来源不能接收连线。") }
            guard blocks.first(where: { $0.id == w.from })?.kind != .output else { throw FlowError("监听输出必须位于流程末端。") }
            let pair = "\(w.from)-\(w.to)"
            guard pairs.insert(pair).inserted else { throw FlowError("会话包含重复连线。") }
            degrees[w.to, default: 0] += 1
        }
        var queue = blocks.filter { degrees[$0.id] == 0 }.map(\.id), result: [UUID] = []
        while !queue.isEmpty {
            let id = queue.removeFirst(); result.append(id)
            for wire in wires where wire.from == id {
                degrees[wire.to, default: 0] -= 1
                if degrees[wire.to] == 0 { queue.append(wire.to) }
            }
        }
        guard result.count == blocks.count else { throw FlowError("不能形成循环音频回路。请移除造成循环的连线。") }
        return result
    }
    func activeIDs() -> Set<UUID> {
        var active = Set(blocks.filter { $0.kind.isSource && $0.enabled }.map(\.id))
        var changed = true
        while changed {
            changed = false
            for w in wires where active.contains(w.from) && !active.contains(w.to) { active.insert(w.to); changed = true }
        }
        return active
    }
    func validateStructure() throws {
        _ = try topologicalOrder()
        guard schedule.date.timeIntervalSinceReferenceDate.isFinite && schedule.durationMinutes.isFinite && (1...1440).contains(schedule.durationMinutes) else { throw FlowError("定时参数无效。") }
        for b in blocks {
            let numbers = [b.x,b.y,b.gain,b.pan,b.frequency,b.threshold,b.headroom,b.attack,b.release,b.sampleRate,b.splitMinutes]
            guard numbers.allSatisfy(\.isFinite), b.bands.count == 10, b.bands.allSatisfy({ $0.isFinite && (-18...18).contains($0) }), (0...4500).contains(b.x), (0...3500).contains(b.y), (-120...60).contains(b.gain), (-1...1).contains(b.pan), (20...20000).contains(b.frequency), (-100...0).contains(b.threshold), (0...40).contains(b.headroom), (0.0001...1).contains(b.attack), (0.001...10).contains(b.release) else { throw FlowError("模块参数损坏或超出有效范围。") }
            if b.kind == .recorder {
                guard [44100.0,48000.0,96000.0].contains(b.sampleRate), [1,2].contains(b.channels), [16,24,32].contains(b.bitDepth), [128,192,256,320].contains(b.bitRate), (0...1440).contains(b.splitMinutes) else { throw FlowError("录音格式参数无效。") }
                if b.format.lossy && b.sampleRate > 48000 { throw FlowError("AAC／MP3 请使用 44.1 kHz 或 48 kHz；96 kHz 可用于无损格式。") }
                if [.alac,.flac].contains(b.format) && b.bitDepth == 32 { throw FlowError("ALAC／FLAC 请使用 16 或 24 bit；32 bit float 可用于 WAV／AIFF。") }
            }
        }
    }
    func validateForRun() throws {
        try validateStructure()
        let active = activeIDs()
        guard blocks.contains(where: { $0.kind.isSource && $0.enabled }) else { throw FlowError("请添加并启用一个声音来源。") }
        guard blocks.contains(where: { active.contains($0.id) && ($0.kind == .recorder || $0.kind == .output) && $0.enabled }) else { throw FlowError("请将声音来源连接到录音机或监听输出。") }
        for b in blocks where b.enabled && active.contains(b.id) {
            if b.kind == .application && b.bundleID.isEmpty { throw FlowError("请先为「\(b.name)」选择要录制的应用。") }
            if b.kind == .file && !FileManager.default.fileExists(atPath: b.filePath) { throw FlowError("音频文件不存在，请重新选择。") }
            if b.kind == .recorder && (![44100.0, 48000.0, 96000.0].contains(b.sampleRate) || ![1,2].contains(b.channels) || ![16,24,32].contains(b.bitDepth) || b.splitMinutes < 0) { throw FlowError("录音格式参数无效。") }
            if b.kind == .recorder && b.format.lossy && b.sampleRate > 48000 { throw FlowError("AAC／MP3 请使用 44.1 kHz 或 48 kHz；96 kHz 可用于无损格式。") }
            if b.kind == .recorder && [.alac, .flac].contains(b.format) && b.bitDepth == 32 { throw FlowError("ALAC／FLAC 请使用 16 或 24 bit；32 bit float 可用于 WAV／AIFF。") }
        }
    }
}

struct FlowError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Recording: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var sessionID: UUID
    var name: String
    var date = Date()
    var duration: Double
    var format: String
    var sampleRate: Double
    var channels: Int
    var bytes: Int64
    var waveform: [Float] = []
    var recorderID: UUID? = nil
}

struct RunningAudioApp: Identifiable, Hashable {
    var id: String
    var name: String
    var pid: pid_t
    var path: String = ""
    var icon: NSImage? { ApplicationIcons.icon(bundleID: id, path: path) }
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SavedAudioApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
}

enum ApplicationIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(bundleID: String, path: String = "") -> NSImage? {
        let url = !path.isEmpty ? URL(fileURLWithPath: path) : NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular }?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let url else { return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular }?.icon }
        if let image = cache[url.path] { return image }
        var image: NSImage?
        if let bundle = Bundle(url: url), let filename = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let name = (filename as NSString).deletingPathExtension
            if let iconURL = bundle.url(forResource: name, withExtension: (filename as NSString).pathExtension.isEmpty ? "icns" : (filename as NSString).pathExtension) { image = NSImage(contentsOf: iconURL) }
        }
        let result = image ?? NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = result
        return result
    }
}

struct AudioDevice: Identifiable, Equatable {
    var id: UInt32
    var name: String
}

struct Level: Equatable {
    var left: Float = -90
    var right: Float = -90
    var rms: Float = -90
    var clipped = false
}

func timeString(_ time: Double, precise: Bool = false) -> String {
    let total = Int(max(0, time.isFinite ? time : 0))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%02d:%02d", total / 60, total % 60)
}

let eqFrequencies: [Float] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let eqLabels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
