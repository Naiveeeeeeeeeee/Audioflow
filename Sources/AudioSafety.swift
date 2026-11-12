import Foundation

enum AudioSafety {
    static func perform<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        let success = SFPerformAudioOperation({ result = Result(catching: operation) }, &error)
        guard success else { throw error ?? FlowError("音频设备发生异常，请检查设备后重试。") }
        guard let result else { throw FlowError("音频操作未完成。") }
        return try result.get()
    }
}
