import Foundation
import AVFoundation
import CoreAudio
import AppKit

// Audio-only process taps. No display/window enumeration or screen recording access.
@available(macOS 14.2, *)
final class ProcessAudioSource {
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "soundflow.process-audio", qos: .userInteractive)
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var incoming: AVAudioFormat?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?
    init(format: AVAudioFormat) { self.format = format }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw FlowError("\(operation)失败（Core Audio \(status)）。请检查「系统设置 → 隐私与安全性 → 录屏与系统录音 → 仅系统录音」中的声流权限。") }
    }
    private func processes() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private func pid(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0, size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }
    private func bundleID(_ object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    func start(bundleID target: String?) throws {
        do {
            let objects = processes()
            let description: CATapDescription
            if let target {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty else { throw FlowError("目标应用尚未运行，请打开应用后重试。") }
                let included = objects.filter { let id = bundleID($0); return id == target || id.hasPrefix(target + ".") }
                description = CATapDescription(stereoMixdownOfProcesses: included)
                if #available(macOS 26.0, *) {
                    description.bundleIDs = [target]
                    description.isProcessRestoreEnabled = true
                } else if included.isEmpty { throw FlowError("目标应用尚未建立音频输出，请先开始播放，再运行会话。") }
            } else {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects.filter { pid($0) == getpid() })
            }
            description.name = "SoundFlow audio source"
            description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "创建系统音频采集")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "读取音频格式")
            guard let incoming = AVAudioFormat(streamDescription: &asbd), incoming.sampleRate > 0 else { throw FlowError("系统音频格式无效。") }
            self.incoming = incoming
            converter = incoming == format ? nil : AVAudioConverter(from: incoming, to: format)
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundFlow private audio input",
                kAudioAggregateDeviceUIDKey: "studio.twiggy.SoundFlow.tap." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "创建私有音频输入")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, queue) { [weak self] _, input, _, _, _ in self?.receive(input) }, "连接系统音频")
            try check(AudioDeviceStart(aggregate, ioProc), "启动系统音频")
        } catch { stop(); throw error }
    }
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard let incoming else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, incoming.streamDescription.pointee.mBytesPerFrame > 0 else { return }
        let frames = first.mDataByteSize / incoming.streamDescription.pointee.mBytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: incoming, frameCapacity: frames) else { return }
        copy.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(list.count, buffers.count) {
            if let source = list[i].mData, let destination = buffers[i].mData { memcpy(destination, source, min(Int(list[i].mDataByteSize), Int(buffers[i].mDataByteSize))) }
        }
        guard let converter else { onBuffer?(copy); return }
        let count = AVAudioFrameCount(ceil(Double(frames) * format.sampleRate / incoming.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        var sent = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if sent { status.pointee = .noDataNow; return nil }
            sent = true; status.pointee = .haveData; return copy
        }
        if result == .error { onError?("系统音频重采样失败：" + (error?.localizedDescription ?? "未知错误")) }
        else if output.frameLength > 0 { onBuffer?(output) }
    }
    func stop() {
        if aggregate != 0, let ioProc { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        queue.sync {}; converter = nil; incoming = nil
    }
    deinit { stop() }
}
