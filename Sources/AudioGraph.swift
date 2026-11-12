import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox
import AppKit

enum DeviceCatalog {
    static func hasDefaultInput() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return false }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &streamSize) == noErr, streamSize > 0 else { return false }
        address.mSelector = kAudioDevicePropertyNominalSampleRate; address.mScope = kAudioObjectPropertyScopeGlobal
        var rate: Float64 = 0; size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate.isFinite, rate > 0 else { return false }
        address.mSelector = kAudioDevicePropertyStreamConfiguration; address.mScope = kAudioDevicePropertyScopeInput
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &streamSize) == noErr, streamSize >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &streamSize, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
    static func outputs() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0) }
            guard status == noErr, let name else { return nil }
            return AudioDevice(id: device, name: name.takeRetainedValue() as String)
        }
    }
}

final class SystemAudioSource: NSObject, SCStreamOutput, SCStreamDelegate {
    let id: UUID
    private var stream: SCStream?
    private var native: AnyObject?
    private let queue = DispatchQueue(label: "soundflow.capture", qos: .userInteractive)
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?
    var stopping = false
    init(id: UUID, format: AVAudioFormat) { self.id = id; self.format = format }
    func start(bundleID: String?) async throws {
        if #available(macOS 14.2, *) {
            let capture = ProcessAudioSource(format: format)
            capture.onBuffer = { [weak self] in self?.onBuffer?($0) }
            capture.onError = { [weak self] in self?.onError?($0) }
            native = capture
            try capture.start(bundleID: bundleID)
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw FlowError("macOS 14.0／14.1 的兼容采集接口需要录屏权限；更新到 macOS 14.2 或更新版本可使用音频专用授权。") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw FlowError("找不到显示器。系统声音采集需要一个有效显示器。") }
        let filter: SCContentFilter
        if let bundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else { throw FlowError("目标应用尚未运行，请打开应用后重试。") }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width = 16; config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3; config.showsCursor = false
        config.capturesAudio = true; config.sampleRate = 48000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    func stop() async {
        stopping = true
        if #available(macOS 14.2, *), let capture = native as? ProcessAudioSource { capture.stop(); native = nil }
        try? await stream?.stopCapture(); stream = nil; queue.sync {}
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { if !stopping { onError?("系统音频采集中断：" + error.localizedDescription) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !stopping, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let incoming = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: incoming, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { onError?("无法解码系统音频。") ; return }
        if incoming == format { onBuffer?(buffer); return }
        if sourceFormat != incoming { sourceFormat = incoming; converter = AVAudioConverter(from: incoming, to: format) }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * format.sampleRate / incoming.sampleRate) + 256)) else { return }
        var sent = false, error: NSError?
        let result = converter.convert(to: converted, error: &error) { _, status in
            if sent { status.pointee = .noDataNow; return nil }
            sent = true; status.pointee = .haveData; return buffer
        }
        if result == .error { onError?("系统音频转换失败：" + (error?.localizedDescription ?? "未知错误")); return }
        if converted.frameLength > 0 { onBuffer?(converted) }
    }
}

final class RuntimeBlock {
    let spec: AudioBlock
    var input: AVAudioMixerNode?
    var output: AVAudioNode!
    var gainUnit: AVAudioUnitEQ!
    var eqUnit: AVAudioUnitEQ?
    var dynamics: AVAudioUnitEffect?
    var player: AVAudioPlayerNode?
    var monitoring: AVAudioMixerNode?
    var tapped: AVAudioNode?
    var file: AVAudioFile?
    var lastLevelTime = 0.0
    let queueLock = NSLock()
    var scheduled = 0
    init(_ spec: AudioBlock) { self.spec = spec }
}

private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

final class AudioGraph {
    private let stateLock = NSRecursiveLock()
    private(set) var engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var runtimes: [UUID: RuntimeBlock] = [:]
    private var captures: [SystemAudioSource] = []
    private var captureGates: [UUID: CaptureGate] = [:]
    private var recorders: [UUID: NodeRecorder] = [:]
    private var runningState = false
    private(set) var isRunning: Bool { get { stateLock.lock(); defer { stateLock.unlock() }; return runningState } set { stateLock.lock(); runningState = newValue; stateLock.unlock() } }
    private var offline = false
    private var stoppingState = false
    private var stopping: Bool { get { stateLock.lock(); defer { stateLock.unlock() }; return stoppingState } set { stateLock.lock(); stoppingState = newValue; stateLock.unlock() } }
    private var configurationObserver: NSObjectProtocol?
    var onLevel: ((UUID, Level) -> Void)?
    var onRecording: ((Recording) -> Void)?
    var onRecorderTime: ((UUID, Double) -> Void)?
    var onError: ((String) -> Void)?
    var onSourceFinished: ((UUID) -> Void)?

    func prepare(_ session: Session, folder: URL, offline: Bool = false) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        try AudioSafety.perform { try prepareHardware(session, folder: folder, offline: offline) }
    }
    private func prepareHardware(_ session: Session, folder: URL, offline: Bool) throws {
        try session.validateForRun()
        self.offline = offline; stopping = false
        let active = session.activeIDs()
        if session.blocks.contains(where: { active.contains($0.id) && $0.kind == .microphone && $0.enabled }), !DeviceCatalog.hasDefaultInput() {
            throw FlowError("没有检测到麦克风或音频输入设备。\n请连接 USB 麦克风／声卡或带麦克风的蓝牙耳机，并在「系统设置 → 声音 → 输入」中选中它，再开始录音。")
        }
        if offline && session.blocks.contains(where: { active.contains($0.id) && $0.enabled && [.system, .application, .microphone].contains($0.kind) }) { throw FlowError("离线验证只接受测试音或文件音源。") }
        let devices = Set(session.blocks.filter { active.contains($0.id) && $0.kind == .output && $0.monitor && $0.outputDeviceID != 0 }.map(\.outputDeviceID))
        guard devices.count <= 1 else { throw FlowError("同一会话的监听输出请使用同一物理设备；可在多个分支中分别调节监听音量。") }
        engine = AVAudioEngine()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self, self.isRunning, !self.stopping else { return }
            self.onError?("音频设备或采样率发生变化，已停止并保存当前录音。请检查设备后重新开始。")
        }
        if let device = devices.first, !offline, let audioUnit = engine.outputNode.audioUnit {
            var value = device
            let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &value, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw FlowError("无法使用该监听设备（\(status)），可能已断开连接。") }
        }
        for block in session.blocks where active.contains(block.id) {
            let runtime = RuntimeBlock(block); runtimes[block.id] = runtime
            let gain = AVAudioUnitEQ(numberOfBands: 0); runtime.gainUnit = gain; engine.attach(gain)
            if block.kind.isSource {
                let source: AVAudioNode
                switch block.kind {
                case .microphone: source = engine.inputNode
                case .tone:
                    var phase = 0.0
                    let frequency = min(20000, max(20, block.frequency))
                    let tone = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
                        let buffers = UnsafeMutableAudioBufferListPointer(list)
                        for i in 0..<Int(frames) {
                            let value = Float(sin(phase) * 0.5)
                            phase += 2 * .pi * frequency / 48000
                            if phase > 2 * .pi { phase -= 2 * .pi }
                            for item in buffers { item.mData?.assumingMemoryBound(to: Float.self)[i] = value }
                        }
                        return noErr
                    }
                    engine.attach(tone); source = tone
                default:
                    let player = AVAudioPlayerNode(); runtime.player = player; engine.attach(player); source = player
                    if block.kind == .file { runtime.file = try AVAudioFile(forReading: URL(fileURLWithPath: block.filePath)) }
                }
                if block.kind == .microphone {
                    let micFormat = engine.inputNode.outputFormat(forBus: 0)
                    guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw FlowError("没有可用的麦克风／输入设备。") }
                    let mixer = AVAudioMixerNode(); engine.attach(mixer)
                    engine.connect(source, to: mixer, format: micFormat)
                    engine.connect(mixer, to: gain, format: format)
                } else if block.kind == .file, let file = runtime.file {
                    let mixer = AVAudioMixerNode(); engine.attach(mixer)
                    engine.connect(source, to: mixer, format: file.processingFormat)
                    engine.connect(mixer, to: gain, format: format)
                } else { engine.connect(source, to: gain, format: format) }
            } else {
                let mixer = AVAudioMixerNode(); runtime.input = mixer; engine.attach(mixer)
                engine.connect(mixer, to: gain, format: format)
            }
            var previous: AVAudioNode = gain
            if block.kind == .equalizer {
                let eq = AVAudioUnitEQ(numberOfBands: 10); engine.attach(eq); runtime.eqUnit = eq
                for i in 0..<10 { eq.bands[i].filterType = .parametric; eq.bands[i].frequency = eqFrequencies[i]; eq.bands[i].bandwidth = 1; eq.bands[i].bypass = false }
                engine.connect(previous, to: eq, format: format); previous = eq
            } else if block.kind == .compressor || block.kind == .limiter {
                let subtype = block.kind == .compressor ? kAudioUnitSubType_DynamicsProcessor : kAudioUnitSubType_PeakLimiter
                let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
                runtime.dynamics = unit; engine.attach(unit); engine.connect(previous, to: unit, format: format); previous = unit
            }
            let out = AVAudioMixerNode(); engine.attach(out); engine.connect(previous, to: out, format: format); runtime.output = out
            update(block)
            if block.kind == .recorder && block.enabled {
                let writer = try NodeRecorder(block: block, sessionID: session.id, folder: folder, inputFormat: format, sourceName: RecordingNaming.source(in: session, recorderID: block.id))
                writer.onComplete = { [weak self] record in self?.onRecording?(record) }
                writer.onError = { [weak self] error in self?.onError?(error) }
                writer.onFrames = { [weak self] id, time in self?.onRecorderTime?(id, time) }
                recorders[block.id] = writer
            }
            runtime.tapped = out
            let writer = recorders[block.id]
            out.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak runtime, writer] buffer, _ in
                guard let self, let runtime, !self.stopping else { return }
                writer?.consume(buffer)
                let now = ProcessInfo.processInfo.systemUptime
                if now - runtime.lastLevelTime >= 0.05 {
                    runtime.lastLevelTime = now
                    self.onLevel?(block.id, measurePCM(buffer))
                }
            }
        }
        // Assign a distinct mixer input bus per incoming edge; fan-out is one Core Audio connection operation.
        var destinationBus: [UUID: AVAudioNodeBus] = [:]
        var mainBus: AVAudioNodeBus = 0
        for block in session.blocks where active.contains(block.id) {
            guard let runtime = runtimes[block.id] else { continue }
            let outgoing = session.wires.filter { $0.from == block.id && active.contains($0.to) }
            var points: [AVAudioConnectionPoint] = []
            for wire in outgoing {
                if let input = runtimes[wire.to]?.input {
                    let bus = destinationBus[wire.to, default: 0]; destinationBus[wire.to] = bus + 1
                    points.append(AVAudioConnectionPoint(node: input, bus: bus))
                }
            }
            if outgoing.isEmpty {
                let monitor = AVAudioMixerNode(); engine.attach(monitor); runtime.monitoring = monitor
                engine.connect(runtime.output, to: monitor, format: format)
                monitor.outputVolume = block.kind == .output && block.monitor && block.enabled && !offline ? 1 : 0
                engine.connect(monitor, to: engine.mainMixerNode, fromBus: 0, toBus: mainBus, format: format)
                mainBus += 1
            } else { engine.connect(runtime.output, to: points, fromBus: 0, format: format) }
        }
        if offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
        engine.prepare()
    }

    func start(_ session: Session, folder: URL) async throws {
        do {
            if session.blocks.contains(where: { $0.kind == .microphone && $0.enabled }) {
                guard DeviceCatalog.hasDefaultInput() else { throw FlowError("没有检测到麦克风或音频输入设备。请连接设备并在系统声音设置中选为输入，然后重试。") }
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw FlowError("麦克风权限未开启。请到系统设置 → 隐私与安全性 → 麦克风，允许「声流」。") }
            }
            try prepare(session, folder: folder)
            try AudioSafety.perform { try engine.start() }; isRunning = true
            for runtime in runtimes.values {
                if let player = runtime.player {
                    if runtime.spec.kind == .file { scheduleFile(runtime) }
                    player.play()
                }
            }
            for block in session.blocks where block.enabled && (block.kind == .application || block.kind == .system) && runtimes[block.id] != nil {
                let capture = SystemAudioSource(id: block.id, format: format)
                let gate = CaptureGate(true); captureGates[block.id] = gate
                capture.onError = { [weak self] message in self?.onError?(message) }
                capture.onBuffer = { [weak self, gate] buffer in if gate.enabled { self?.scheduleCaptured(buffer, id: block.id) } }
                captures.append(capture)
                try await capture.start(bundleID: block.kind == .application ? block.bundleID : nil)
            }
        } catch { await stop(); throw error }
    }

    func switchApplication(_ id: UUID, to bundleID: String) async throws {
        stateLock.lock()
        let runtime = runtimes[id]
        let index = captures.firstIndex(where: { $0.id == id })
        let oldGate = captureGates[id]
        stateLock.unlock()
        guard isRunning, !stopping, let runtime, runtime.spec.kind == .application,
              let player = runtime.player, let index else { throw FlowError("应用音源当前未运行。") }
        let next = SystemAudioSource(id: id, format: format), gate = CaptureGate(false)
        next.onBuffer = { [weak self, gate] buffer in if gate.enabled { self?.scheduleCaptured(buffer, id: id) } }
        next.onError = { [weak self, gate] message in if gate.enabled { self?.onError?(message) } }
        // Prepare the replacement before touching the current source. Failure leaves
        // the old application and the existing recorder running.
        do { try await next.start(bundleID: bundleID) }
        catch { await next.stop(); throw error }
        guard isRunning, !stopping else { await next.stop(); throw FlowError("会话已停止。") }
        oldGate?.set(false)
        await captures[index].stop()
        do { try AudioSafety.perform { player.stop(); player.play() } }
        catch { isRunning = false; await next.stop(); throw error }
        stateLock.lock(); captures[index] = next; captureGates[id] = gate; stateLock.unlock()
        gate.set(true)
    }

    private func scheduleCaptured(_ buffer: AVAudioPCMBuffer, id: UUID) {
        stateLock.lock()
        let runtime = isRunning && !stopping ? runtimes[id] : nil
        stateLock.unlock()
        guard let runtime, let player = runtime.player else { return }
        runtime.queueLock.lock()
        guard runtime.scheduled < 48 else { runtime.queueLock.unlock(); onError?("音频采集积压，已停止以避免静默丢帧。请检查输出设备或系统负载。"); return }
        runtime.scheduled += 1; runtime.queueLock.unlock()
        player.scheduleBuffer(buffer) { [weak runtime] in
            runtime?.queueLock.lock(); runtime?.scheduled -= 1; runtime?.queueLock.unlock()
        }
    }

    private func scheduleFile(_ runtime: RuntimeBlock) {
        guard let player = runtime.player, let file = runtime.file else { return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak runtime] _ in
            guard let self, let runtime else { return }
            DispatchQueue.main.async {
                guard self.isRunning, !self.stopping else { return }
                if runtime.spec.loop { self.scheduleFile(runtime) } else { self.onSourceFinished?(runtime.spec.id) }
            }
        }
    }

    func update(_ block: AudioBlock) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let runtime = runtimes[block.id] else { return }
        runtime.gainUnit.globalGain = Float(block.enabled || !block.kind.isSource ? min(24, max(-96, block.gain)) : -96)
        if !block.enabled && !block.kind.isSource { runtime.gainUnit.globalGain = 0 }
        (runtime.output as? AVAudioMixerNode)?.pan = block.enabled ? Float(max(-1, min(1, block.pan))) : 0
        if let eq = runtime.eqUnit { eq.bypass = !block.enabled; for i in 0..<min(10, block.bands.count) { eq.bands[i].gain = Float(min(18, max(-18, block.bands[i]))) } }
        if let unit = runtime.dynamics {
            unit.bypass = !block.enabled
            if block.kind == .compressor {
                AudioUnitSetParameter(unit.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, Float(block.threshold), 0)
                AudioUnitSetParameter(unit.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, Float(block.headroom), 0)
                AudioUnitSetParameter(unit.audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, Float(block.attack), 0)
                AudioUnitSetParameter(unit.audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, Float(block.release), 0)
                AudioUnitSetParameter(unit.audioUnit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 1, 0)
            } else {
                AudioUnitSetParameter(unit.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
                AudioUnitSetParameter(unit.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
            }
        }
        runtime.monitoring?.outputVolume = block.kind == .output && block.monitor && block.enabled && !offline ? 1 : 0
    }
    func pauseRecorders(_ paused: Bool, id: UUID? = nil) { for (key, writer) in recorders where id == nil || key == id { writer.setPaused(paused) } }
    func splitRecorders() { for writer in recorders.values { writer.split() } }

    func stop() async {
        isRunning = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        for capture in captures { await capture.stop() }; captures.removeAll()
        captureGates.removeAll()
        // Stop rendering first, then allow already-delivered asynchronous tap callbacks
        // to reach the writers before closing their serial disk queues.
        do { try AudioSafety.perform { engine.pause() } } catch { onError?(error.localizedDescription) }
        try? await Task.sleep(nanoseconds: 120_000_000)
        stopping = true
        do { try AudioSafety.perform {
            engine.stop()
            for runtime in runtimes.values { runtime.player?.stop(); runtime.tapped?.removeTap(onBus: 0) }
        } } catch { onError?(error.localizedDescription) }
        let writers = Array(recorders.values)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { for writer in writers { writer.finish() }; continuation.resume() }
        }
        stateLock.lock(); recorders.removeAll(); runtimes.removeAll(); stateLock.unlock()
        do { try AudioSafety.perform {
            if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
            engine.reset()
        } } catch { onError?(error.localizedDescription) }
    }

    func startOffline() throws { try AudioSafety.perform { try engine.start() }; isRunning = true; for r in runtimes.values { if let p = r.player { if r.spec.kind == .file { scheduleFile(r) }; p.play() } } }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }
    func renderOffline(frames: AVAudioFrameCount) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw FlowError("缓冲区分配失败。") }
        var remaining = frames, retries = 0
        while remaining > 0 {
            let n = min(remaining, 4096)
            let status = try engine.renderOffline(n, to: buffer)
            if status == .success { remaining -= n; retries = 0 }
            else if status == .cannotDoInCurrentContext && retries < 100 { retries += 1 }
            else { throw FlowError("离线渲染失败：\(status.rawValue)") }
        }
    }
}
