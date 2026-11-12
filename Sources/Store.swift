import Foundation
import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

@MainActor final class StudioStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedSessionID: UUID?
    @Published var selectedBlockID: UUID?
    @Published var selectedWireID: UUID?
    @Published var pendingConnection: UUID?
    @Published var recordings: [Recording] = []
    @Published var apps: [RunningAudioApp] = []
    @Published var savedApplications: [SavedAudioApp] = []
    @Published var previewRecording: Recording?
    @Published var devices: [AudioDevice] = []
    @Published var levels: [UUID: Level] = [:]
    @Published var recorderTimes: [UUID: Double] = [:]
    @Published var running = false
    @Published var busy = false
    @Published var paused = false
    @Published var elapsed: Double = 0
    @Published var status = "就绪"
    @Published var error: String?
    @Published var toast = ""
    @Published var inspectorTab = "模块"
    @Published var showTemplates = false
    @Published var showSidebar = false
    @Published var zoom: Double = 1
    @Published var search = ""
    @Published var allRecordings = false
    @Published var selectedRecordingID: UUID?
    @Published var playingID: UUID?
    @Published var playerPlaying = false
    @Published var playerPosition: Double = 0
    @Published var playerDuration: Double = 0
    @Published var playerSeeking = false
    @Published var recordFolder: URL
    @Published var screenPermission = false
    @Published var microphonePermission = false
    @Published var log: [String] = []
    @Published var recordingPausedIDs = Set<UUID>()
    private let base: URL
    private let sessionsURL: URL
    private let libraryURL: URL
    let applicationsURL: URL
    private var graph: AudioGraph?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastTick = Date()
    private var runningSessionID: UUID?
    private var recovering = false
    private var saveWork: DispatchWorkItem?
    private var sourceFinished = Set<UUID>()
    private var spaceMonitor: Any?

    var session: Session { sessions.first { $0.id == selectedSessionID } ?? Session() }
    var block: AudioBlock? { session.blocks.first { $0.id == selectedBlockID } }
    var activeRecordings: [Recording] {
        recordings.filter { (allRecordings || $0.sessionID == selectedSessionID) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted { $0.date > $1.date }
    }
    var recordingCount: Int { recordings.count }
    var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }
    var formatSummary: String { guard let b = session.blocks.first(where: { $0.kind == .recorder && $0.enabled }) else { return "仅监听" }; return "\(b.format.rawValue.uppercased()) · \(Int(b.sampleRate / 1000)) kHz · \(b.channels == 2 ? "立体声" : "单声道")" }
    var peak: Level { session.blocks.reversed().compactMap { levels[$0.id] }.first ?? Level() }

    init(baseOverride: URL? = nil, registerSystemEvents: Bool = true) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        base = baseOverride ?? home.appendingPathComponent("Library/Application Support/SoundFlow", isDirectory: true)
        sessionsURL = base.appendingPathComponent("sessions.json")
        libraryURL = base.appendingPathComponent("recordings.json")
        applicationsURL = base.appendingPathComponent("applications.json")
        recordFolder = baseOverride?.appendingPathComponent("Recordings") ?? URL(fileURLWithPath: UserDefaults.standard.string(forKey: "SoundFlow.recordFolder") ?? home.appendingPathComponent("Music/声流录音").path, isDirectory: true)
        do { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) } catch { self.error = error.localizedDescription }
        load()
        loadApplications(); refreshApps(); refreshPermissions(); devices = DeviceCatalog.outputs()
        if sessions.isEmpty {
            let preferred = apps.first(where: { $0.id.localizedCaseInsensitiveContains("qqmusic") })?.id ?? apps.first(where: { $0.id.contains("Safari") })?.id ?? ""
            sessions = [.template("应用录音", appID: preferred), .template("系统录音"), .template("麦克风录音")]
            if !recovering { save() }
        }
        selectedSessionID = sessions.first?.id
        bootstrapApplications()
        compactLegacyLayouts()
        if registerSystemEvents {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        installKeys()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshApps() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshApps() } }
        }
    }
    private func compactLegacyLayouts() {
        var changed = false
        for i in sessions.indices {
            if !sessions[i].blocks.isEmpty, sessions[i].blocks.allSatisfy({ [24.0,216,408,600].contains($0.x) && [32.0,56,224].contains($0.y) }) {
                for j in sessions[i].blocks.indices { sessions[i].blocks[j].x = 20 + (sessions[i].blocks[j].x - 24) / 192 * StudioLayout.column }
                changed = true; continue
            }
            guard !sessions[i].blocks.isEmpty, sessions[i].blocks.allSatisfy({ b in
                [48.0, 278, 508, 738].contains(b.x) && [65.0, 175, 330].contains(b.y)
            }) else { continue }
            for j in sessions[i].blocks.indices {
                let old = sessions[i].blocks[j]
                sessions[i].blocks[j].x = 20 + (old.x - 48) / 230 * StudioLayout.column
                sessions[i].blocks[j].y = old.y == 330 ? 224 : old.y == 65 ? 32 : 56
            }
            changed = true
        }
        if changed { save() }
    }

    private func load() {
        do {
            if FileManager.default.fileExists(atPath: sessionsURL.path) {
                let loaded = try JSONDecoder().decode([Session].self, from: Data(contentsOf: sessionsURL))
                for s in loaded { try s.validateStructure() }
                sessions = loaded
            }
        } catch { recovering = true; self.error = "会话文件无法读取，原文件已保留：\(sessionsURL.path)\n\(error.localizedDescription)" }
        do {
            if FileManager.default.fileExists(atPath: libraryURL.path) { recordings = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: libraryURL)) }
        } catch { self.error = "录音索引无法读取，原始音频不会被删除。可在「文件」菜单重新导入音频。\n" + error.localizedDescription }
    }
    func save() {
        guard !recovering else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sessions).write(to: sessionsURL, options: .atomic)
            try encoder.encode(recordings).write(to: libraryURL, options: .atomic)
        } catch { self.error = "保存失败：" + error.localizedDescription }
    }
    func saveSoon() {
        saveWork?.cancel()
        let task = DispatchWorkItem { [weak self] in Task { @MainActor in self?.save() } }
        saveWork = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }
    func updateSession(_ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        change(&sessions[index]); saveSoon()
    }
    func updateBlock(_ id: UUID, _ change: (inout AudioBlock) -> Void) {
        guard let s = sessions.firstIndex(where: { $0.id == selectedSessionID }), let i = sessions[s].blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[s].blocks[i]); if running { graph?.update(sessions[s].blocks[i]) }; saveSoon()
    }
    func selectRecordingApplication(_ id: UUID, bundleID: String) {
        guard !busy, let source = session.blocks.first(where: { $0.id == id && $0.kind == .application }), source.bundleID != bundleID else { return }
        guard !bundleID.isEmpty else { return }
        if !running || !source.enabled { updateBlock(id) { $0.bundleID = bundleID }; return }
        guard let graph else { return }
        busy = true; status = "正在切换录制应用…"
        Task {
            do {
                try await ensureApplicationRunning(bundleID)
                try await graph.switchApplication(id, to: bundleID)
                updateBlock(id) { $0.bundleID = bundleID }
                busy = false; status = paused ? "录音已暂停" : "录制中"
                let name = apps.first(where: { $0.id == bundleID })?.name ?? bundleID
                addLog("录制应用已切换为「\(name)」")
            } catch {
                busy = false; self.error = "切换应用失败：\(error.localizedDescription)"
                if !graph.isRunning { stop() }
                else { status = paused ? "录音已暂停" : "继续原音源录制" }
                addLog("切换失败：\(error.localizedDescription)")
            }
        }
    }
    func selectSession(_ id: UUID) {
        guard !running && !busy else { showToast("请先停止当前会话，再切换流程。"); return }
        selectedSessionID = id; selectedBlockID = nil; selectedWireID = nil; pendingConnection = nil; levels = [:]; recorderTimes = [:]; elapsed = 0; status = "就绪"; zoom = 1
    }
    func create(_ template: String) {
        guard !running && !busy else { showToast("请先停止当前会话。"); return }
        let preferred = apps.first(where: { $0.id.localizedCaseInsensitiveContains("qqmusic") })?.id ?? ""
        var value = Session.template(template, appID: preferred)
        if sessions.contains(where: { $0.name == value.name }) { value.name += " \(sessions.filter { $0.name.hasPrefix(template) }.count + 1)" }
        sessions.append(value); selectSession(value.id); showTemplates = false; save()
    }
    func duplicateSession() {
        guard !running && !busy else { return }
        let old = session; var copy = old; copy.id = UUID(); copy.name += " 副本"; copy.created = Date(); copy.schedule.enabled = false
        var map: [UUID: UUID] = [:]
        copy.blocks = old.blocks.map { var block = $0; block.id = UUID(); map[$0.id] = block.id; return block }
        copy.wires = old.wires.map { Wire(from: map[$0.from]!, to: map[$0.to]!) }
        sessions.append(copy); selectSession(copy.id); save()
    }
    func deleteSession() {
        guard !running && !busy, sessions.count > 1 else { showToast("至少保留一个会话。"); return }
        let alert = NSAlert(); alert.messageText = "删除「\(session.name)」？"; alert.informativeText = "只删除流程配置，录音文件会保留。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        sessions.removeAll { $0.id == selectedSessionID }; selectedSessionID = sessions.first?.id; selectedBlockID = nil; save()
    }
    func addBlock(_ kind: BlockKind, at point: CGPoint? = nil) {
        guard !running && !busy else { showToast("停止后即可编辑流程；运行时可调节音量与音效参数。"); return }
        let count = session.blocks.count
        var b = AudioBlock(kind, x: point.map { Double($0.x) } ?? 20 + Double(count % 4) * StudioLayout.column, y: point.map { Double($0.y) } ?? 56 + Double(count / 4) * StudioLayout.row)
        if kind == .application { b.bundleID = apps.first(where: { $0.id.localizedCaseInsensitiveContains("qqmusic") })?.id ?? "" }
        updateSession { $0.blocks.append(b) }; selectedBlockID = b.id; selectedWireID = nil; inspectorTab = "模块"
        if kind == .file { chooseSourceFile(b.id) }
    }
    func deleteSelection() {
        guard !running && !busy else { showToast("请先停止录音，再删除模块或连线。"); return }
        if let wire = selectedWireID { updateSession { $0.wires.removeAll { $0.id == wire } }; selectedWireID = nil }
        else if let id = selectedBlockID { updateSession { $0.blocks.removeAll { $0.id == id }; $0.wires.removeAll { $0.from == id || $0.to == id } }; selectedBlockID = nil; pendingConnection = nil }
    }
    func connect(to target: UUID) {
        guard let from = pendingConnection, !running && !busy else { return }
        pendingConnection = nil
        if session.wires.contains(where: { $0.from == from && $0.to == target }) { showToast("这两个模块已经连接。"); return }
        var candidate = session; candidate.wires.append(Wire(from: from, to: target))
        do { _ = try candidate.topologicalOrder(); updateSession { $0 = candidate } }
        catch { self.error = error.localizedDescription }
    }
    func autoArrange() {
        guard !running && !busy else { return }
        let s = session
        guard let order = try? s.topologicalOrder() else { return }
        var columns: [UUID: Int] = [:], rows: [Int: Int] = [:]
        for id in order {
            let incoming = s.wires.filter { $0.to == id }
            columns[id] = incoming.map { (columns[$0.from] ?? 0) + 1 }.max() ?? 0
        }
        updateSession { session in
            for i in session.blocks.indices {
                let col = columns[session.blocks[i].id] ?? 0, row = rows[col, default: 0]; rows[col] = row + 1
                session.blocks[i].x = 20 + Double(col) * StudioLayout.column; session.blocks[i].y = 56 + Double(row) * StudioLayout.row
            }
        }
    }

    func toggleRun() { if running { stop() } else if !busy { Task { await start() } } }
    func start() async {
        guard !busy && !running else { return }
        do { try session.validateForRun() } catch { self.error = error.localizedDescription; inspectorTab = "模块"; return }
        busy = true; error = nil; status = "正在连接音频…"; player?.pause(); playerPlaying = false; levels = [:]; recorderTimes = [:]; elapsed = 0; paused = false; recordingPausedIDs = []; sourceFinished = []
        let captured = session
        let graph = AudioGraph(); self.graph = graph
        graph.onLevel = { [weak self] id, level in DispatchQueue.main.async { self?.levels[id] = level } }
        graph.onRecording = { [weak self] record in DispatchQueue.main.async { self?.addRecording(record) } }
        graph.onRecorderTime = { [weak self] id, seconds in DispatchQueue.main.async { self?.recorderTimes[id] = seconds } }
        graph.onError = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.running || self.busy else { return }
            self.error = message; if self.running { self.stop() }
        } }
        graph.onSourceFinished = { [weak self] id in
            guard let self else { return }; self.sourceFinished.insert(id)
            let sources = captured.blocks.filter { $0.kind.isSource && $0.enabled }
            if sources.allSatisfy({ $0.kind == .file && !$0.loop && self.sourceFinished.contains($0.id) }) { self.stop() }
        }
        do {
            for source in captured.blocks where source.kind == .application && source.enabled { try await ensureApplicationRunning(source.bundleID) }
            try await graph.start(captured, folder: recordFolder)
            running = true; runningSessionID = captured.id; busy = false; status = "录制中"; lastTick = Date()
            addLog("已运行「\(captured.name)」")
            if captured.blocks.filter({ $0.kind == .recorder && $0.enabled }).isEmpty { status = "音频处理中" }
            let files = captured.blocks.filter { $0.kind.isSource && $0.enabled }
            if !files.isEmpty && files.allSatisfy({ $0.kind == .file && !$0.loop && sourceFinished.contains($0.id) }) { stop() }
        } catch {
            busy = false; running = false; status = "未启动"; self.graph = nil
            let ns = error as NSError
            if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || ns.code == -3801 {
                self.error = "系统声音权限尚未开启。\n请到系统设置 → 隐私与安全性 → 屏幕与系统音频录制，允许「声流」，然后重新打开程序。\n\n系统返回：\(error.localizedDescription)"
            } else { self.error = error.localizedDescription }
            addLog("启动失败：\(error.localizedDescription)")
        }
        refreshPermissions()
    }
    func stop() {
        guard !busy, running, let graph else { return }
        busy = true; running = false; status = "正在保存录音…"
        Task {
            await graph.stop()
            // Writer callbacks reach the main queue before this barrier. Persist the
            // completed library entries before permitting another run or application exit.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            self.graph = nil; runningSessionID = nil; busy = false; paused = false; recordingPausedIDs = []; levels = [:]
            status = error == nil ? "已停止" : "已停止 · 请检查错误"
            if recordings.contains(where: { $0.sessionID == runningSessionID || $0.sessionID == selectedSessionID }) { inspectorTab = "录音" }
            save(); addLog(error == nil ? "录音已保存" : "录音停止，请检查错误及已保存文件")
        }
    }
    func pauseRecording() {
        guard running else { return }; paused.toggle(); graph?.pauseRecorders(paused)
        recordingPausedIDs = paused ? Set(session.blocks.filter { $0.kind == .recorder }.map(\.id)) : []
        status = paused ? "录音已暂停 · 音频处理继续" : "录制中"; addLog(paused ? "暂停录音" : "继续录音")
    }
    func pauseRecorder(_ id: UUID) {
        guard running else { return }
        let value = !recordingPausedIDs.contains(id)
        if value { recordingPausedIDs.insert(id) } else { recordingPausedIDs.remove(id) }
        graph?.pauseRecorders(value, id: id)
    }
    func splitRecording() { guard running else { return }; graph?.splitRecorders(); showToast("已分段，录音继续。"); addLog("手动分段") }

    private func addRecording(_ record: Recording) {
        recordings.insert(record, at: 0); selectedRecordingID = record.id; saveSoon(); addLog("已保存 \(record.url.lastPathComponent)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wave = RecordingAnalysis.waveform(url: record.url)
            DispatchQueue.main.async { guard let self, let i = self.recordings.firstIndex(where: { $0.id == record.id }) else { return }; self.recordings[i].waveform = wave; self.saveSoon() }
        }
    }
    func refreshApps() {
        var available = NSWorkspace.shared.runningApplications.compactMap { app -> RunningAudioApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, let name = app.localizedName else { return nil }
            return RunningAudioApp(id: id, name: name, pid: app.processIdentifier, path: app.bundleURL?.path ?? "")
        }
        for saved in savedApplications where !available.contains(where: { $0.id == saved.id }) {
            available.append(RunningAudioApp(id: saved.id, name: saved.name, pid: 0, path: saved.path))
        }
        for id in Set(sessions.flatMap { $0.blocks.filter { $0.kind == .application }.map(\.bundleID) }) where !id.isEmpty && !available.contains(where: { $0.id == id }) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), let bundle = Bundle(url: url) {
                let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
                available.append(RunningAudioApp(id: id, name: name, pid: 0, path: url.path))
            }
        }
        apps = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        devices = DeviceCatalog.outputs()
    }
    func refreshPermissions() { screenPermission = CGPreflightScreenCaptureAccess(); microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    func openPrivacy(_ microphone: Bool = false) {
        NSWorkspace.shared.open(URL(string: microphone ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "保存到这里"; panel.directoryURL = recordFolder
        if panel.runModal() == .OK, let url = panel.url { recordFolder = url; UserDefaults.standard.set(url.path, forKey: "SoundFlow.recordFolder") }
    }
    func chooseSourceFile(_ id: UUID) {
        guard !running && !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.prompt = "用作音源"
        if panel.runModal() == .OK, let url = panel.url { updateBlock(id) { $0.filePath = url.path; $0.name = url.deletingPathExtension().lastPathComponent } }
    }
    func exportSession() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = session.name + ".soundflow.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(session).write(to: url, options: .atomic); showToast("会话已导出。") }
            catch { self.error = error.localizedDescription }
        }
    }
    func importSession() {
        guard !running && !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.prompt = "导入会话"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url); guard data.count < 2_000_000 else { throw FlowError("会话文件超过 2 MB。") }
                var imported = try JSONDecoder().decode(Session.self, from: data); try imported.validateStructure()
                guard imported.schemaVersion == 1 else { throw FlowError("此会话版本暂不受支持。") }
                imported.id = UUID(); imported.schedule.enabled = false
                sessions.append(imported); selectSession(imported.id); save()
            } catch { self.error = "导入失败：" + error.localizedDescription }
        }
    }
    func importRecordings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = true; panel.prompt = "加入录音库"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if recordings.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
            do {
                let audio = try AVAudioFile(forReading: url)
                let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                addRecording(Recording(url: url, sessionID: session.id, name: url.deletingPathExtension().lastPathComponent, duration: Double(audio.length) / audio.processingFormat.sampleRate, format: url.pathExtension.uppercased(), sampleRate: audio.processingFormat.sampleRate, channels: Int(audio.processingFormat.channelCount), bytes: bytes))
            } catch { self.error = "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)" }
        }
    }
    func togglePlayback(_ record: Recording? = nil) {
        if let record, playingID != record.id {
            do { player = try AVAudioPlayer(contentsOf: record.url); player?.prepareToPlay(); playingID = record.id; selectedRecordingID = record.id; playerDuration = player?.duration ?? record.duration; playerPosition = 0 }
            catch { self.error = "无法播放录音：" + error.localizedDescription; return }
        }
        if player == nil, let first = activeRecordings.first { togglePlayback(first); return }
        guard let player else { return }
        if player.isPlaying { player.pause(); playerPlaying = false }
        else { if player.currentTime >= player.duration - 0.02 { player.currentTime = 0 }; player.play(); playerPlaying = true }
    }
    func seek(_ time: Double) { player?.currentTime = max(0, min(playerDuration, time)); playerPosition = time }
    func replay() { guard player != nil else { return }; player?.currentTime = 0; playerPosition = 0; player?.play(); playerPlaying = true }
    func reveal(_ recording: Recording) { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) }
    func trash(_ recording: Recording) {
        let alert = NSAlert(); alert.messageText = "将这条录音移到废纸篓？"; alert.informativeText = recording.url.lastPathComponent; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            if playingID == recording.id { player?.stop(); player = nil; playingID = nil; playerPlaying = false }
            if FileManager.default.fileExists(atPath: recording.url.path) { try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil) }
            recordings.removeAll { $0.id == recording.id }; save()
        } catch { self.error = error.localizedDescription }
    }
    func renameRecording(_ recording: Recording, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let url = recording.url.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension(recording.url.pathExtension)
        if url == recording.url { return }
        do {
            if playingID == recording.id { player?.stop(); player = nil; playingID = nil; playerPlaying = false }
            try FileManager.default.moveItem(at: recording.url, to: url); recordings[index].name = clean; recordings[index].url = url; save()
        } catch { self.error = "重命名失败：" + error.localizedDescription }
    }
    func exportRecording(_ recording: Recording, format: RecordingFormat, sampleRate: Double, bitRate: Int) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .audio]; panel.nameFieldStringValue = recording.name + "." + format.ext
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != recording.url.standardizedFileURL else { error = "请另存到不同文件，保留原始录音。"; return }
        busy = true; status = "正在转换录音…"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("soundflow-export-" + UUID().uuidString, isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                defer { try? FileManager.default.removeItem(at: temp) }
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let source = try AVAudioFile(forReading: recording.url)
                let standard = AVAudioFormat(standardFormatWithSampleRate: source.processingFormat.sampleRate, channels: source.processingFormat.channelCount)!
                var block = AudioBlock(.recorder, x: 0, y: 0); block.format = format; block.sampleRate = sampleRate; block.channels = min(2, Int(source.processingFormat.channelCount)); block.bitRate = bitRate; block.filenamePrefix = "转换"
                let writer = try NodeRecorder(block: block, sessionID: recording.sessionID, folder: temp, inputFormat: standard)
                var result: URL?
                var writeError: String?
                writer.onComplete = { result = $0.url }; writer.onError = { writeError = $0 }
                let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192)!
                while source.framePosition < source.length { try source.read(into: input); if input.frameLength == 0 { break }; try writer.writeSynchronously(input) }
                writer.finish()
                if let writeError { throw FlowError(writeError) }
                guard let result else { throw FlowError("源文件没有可导出的音频。") }
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: result) }
                else { try FileManager.default.copyItem(at: result, to: destination) }
                DispatchQueue.main.async { self?.busy = false; self?.status = "导出完成"; self?.showToast("录音已导出。") }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.status = "导出失败"; self?.error = error.localizedDescription } }
        }
    }

    func showToast(_ text: String) { toast = text; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.toast == text { self?.toast = "" } } }
    func addLog(_ text: String) { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; log.insert("\(f.string(from: Date()))  \(text)", at: 0); if log.count > 100 { log.removeLast() } }
    private func tick() {
        let now = Date(), delta = min(1, max(0, now.timeIntervalSince(lastTick))); lastTick = now
        if running && !paused { elapsed += delta }
        if !playerSeeking { playerPosition = player?.currentTime ?? 0 }
        if playerPlaying && player?.isPlaying == false { playerPlaying = false }

    }
    private func installKeys() {
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, RunLoop.current.currentMode != .eventTracking else { return event }
            let responder = NSApp.keyWindow?.firstResponder
            if let text = responder as? NSTextView, text.isEditable { return event }
            if responder is NSTextField || responder is NSComboBox || responder is NSPopUpButton { return event }
            if self?.previewRecording != nil { return event }
            if event.keyCode == 49 { Task { @MainActor in self?.togglePlayback() }; return nil }
            if event.keyCode == 51 || event.keyCode == 117 { Task { @MainActor in self?.deleteSelection() }; return nil }
            if event.keyCode == 53 { Task { @MainActor in self?.pendingConnection = nil }; return event }
            return event
        }
    }
    func shutdown() async {
        timer?.invalidate()
        // A conversion or a start/stop already in progress owns its completion path.
        // Wait for it instead of closing its writer twice or terminating mid-export.
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        if running { stop() }
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        save()
    }
}
