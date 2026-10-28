import Foundation
import VakenCore

final class ProcessRunner: CommandRunning {
    func run(_ path: String, _ arguments: [String]) -> CommandResult {
        let task = Process(), out = Pipe()
        task.executableURL = URL(fileURLWithPath: path); task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        task.standardOutput = out; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .init(exitCode: -1, stdout: "", stderr: error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return .init(exitCode: task.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }
}
