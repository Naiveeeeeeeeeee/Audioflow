import Foundation
import AppKit
import Darwin

struct ReservedRecordingName {
    let file: URL
    let reservation: URL
}

enum RecordingNaming {
    static func reserve(folder: URL, date: Date = Date(), source: String, ext: String) throws -> ReservedRecordingName {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = String(source.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let stem = formatter.string(from: date) + (clean.isEmpty ? "" : "_" + clean)
        for count in 1...10000 {
            let name = stem + (count == 1 ? "" : "_\(count)") + "." + ext
            let target = folder.appendingPathComponent(name)
            let marker = folder.appendingPathComponent("." + name + ".soundflow-reservation")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let descriptor = Darwin.open(marker.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            Darwin.close(descriptor)
            if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: marker); continue }
            return ReservedRecordingName(file: target, reservation: marker)
        }
        throw FlowError("同一时间的录音文件过多，请更换保存目录。")
    }
    static func source(in session: Session, recorderID: UUID) -> String {
        var visited = Set<UUID>(), sources: [AudioBlock] = []
        func visit(_ id: UUID) {
            guard visited.insert(id).inserted, let block = session.blocks.first(where: { $0.id == id }) else { return }
            if block.kind.isSource { if block.enabled { sources.append(block) }; return }
            for wire in session.wires where wire.to == id { visit(wire.from) }
        }
        visit(recorderID)
        guard sources.count == 1, let source = sources.first else { return sources.isEmpty ? "" : "混合音源" }
        switch source.kind {
        case .application:
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == source.bundleID && $0.activationPolicy == .regular }), let name = app.localizedName { return name }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID), let bundle = Bundle(url: url) {
                return bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "应用"
            }
            return "应用"
        case .microphone: return "麦克风"
        case .system: return "系统声音"
        case .file: return "音频文件"
        case .tone: return "测试音"
        default: return ""
        }
    }
}
