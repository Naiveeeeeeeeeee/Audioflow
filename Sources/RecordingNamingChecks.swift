import Foundation

private final class NameChecksState: @unchecked Sendable {
    let lock = NSLock()
    var names: [ReservedRecordingName] = []
    var errors: [String] = []
}

enum RecordingNamingChecks {
    static func run(folder: URL) throws -> [[String:Any]] {
        let directory = folder.appendingPathComponent("FilenameChecks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = NameChecksState(), instant = Date(timeIntervalSince1970: 1_794_500_000)
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                let reservation = try RecordingNaming.reserve(folder: directory, date: instant, source: "剪映/专业:版", ext: "wav")
                try Data("original-payload-\(index)".utf8).write(to: reservation.file, options: .withoutOverwriting)
                state.lock.lock(); state.names.append(reservation); state.lock.unlock()
            } catch { state.lock.lock(); state.errors.append(error.localizedDescription); state.lock.unlock() }
        }
        try SelfTest.check(state.errors.isEmpty && state.names.count == 24, "同秒并发命名失败或覆盖了录音：\(state.errors)")
        try SelfTest.check(Set(state.names.map { $0.file }).count == 24, "同秒录音重名")
        let names = state.names.map { $0.file.lastPathComponent }
        try SelfTest.check(names.allSatisfy { $0.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_剪映-专业-版(?:_\d+)?\.wav$"#, options: .regularExpression) != nil }, "录音文件名含多余前缀或随机码")
        let contents = try state.names.map { try String(contentsOf: $0.file, encoding: .utf8) }
        try SelfTest.check(Set(contents).count == 24, "同秒并发录音发生内容覆盖")
        for reservation in state.names { try FileManager.default.removeItem(at: reservation.reservation) }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try SelfTest.check(!remaining.contains(where: { $0.contains("soundflow-reservation") }), "命名占用标记未释放")
        return [["test":"short_filenames_and_concurrent_collision_protection", "passed":true, "parallel_files":24, "no_random_suffix":true]]
    }
}
