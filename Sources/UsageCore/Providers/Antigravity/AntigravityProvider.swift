import Foundation

/// Runs `agy -p /usage --output-format json`, which answers from the account's quota
/// without a model call.
public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID("antigravity")
    public let displayName = "Antigravity"
    public let symbolName = "atom"
    public let monogram = "A"
    static let arguments = ["-p", "/usage", "--output-format", "json"]
    public var timeout: TimeInterval = 20
    public var workDirectory: String

    public init(workDirectory: String = NSHomeDirectory() + "/Library/Application Support/Noonchi") {
        self.workDirectory = workDirectory
    }

    public func locateExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["NOONCHI_AGY_PATH"],
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func fetch() async throws -> ProviderUsage {
        // The read blocks for seconds; keep it off the cooperative thread pool.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: read())
            }
        }
    }

    func read() -> Result<ProviderUsage, ProviderFailure> {
        guard let agy = locateExecutable() else { return .failure(ProviderFailure(.notInstalled)) }
        let noBrowser = workDirectory + "/no-browser"
        do {
            try FileManager.default.createDirectory(atPath: noBrowser, withIntermediateDirectories: true)
            // Signed out, agy runs `open <login URL>` through PATH. Every refresh would open a
            // browser tab, so `open` resolves to this no-op first.
            try "#!/bin/sh\nexit 0\n".write(toFile: noBrowser + "/open", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noBrowser + "/open")
        } catch {
            return .failure(ProviderFailure(.launchFailed, raw: String(describing: error)))
        }

        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["PATH"] = "\(noBrowser):\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agy)
        process.arguments = Self.arguments
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: workDirectory)
        process.standardInput = FileHandle.nullDevice
        let output = Output()
        process.standardOutput = output.stdout
        process.standardError = output.stderr
        do { try process.run() } catch { return .failure(ProviderFailure(.launchFailed)) }
        defer {
            output.stopReading()
            if process.isRunning { process.terminate() }
            process.stopInBackground()
        }

        switch output.wait(until: Date().addingTimeInterval(timeout)) {
        case .timeout: return .failure(ProviderFailure(.timeout))
        case .notLoggedIn: return .failure(ProviderFailure(.notLoggedIn))
        case .finished(let data): return Self.usage(from: data)
        }
    }

    static func usage(from output: Data, at date: Date = Date()) -> Result<ProviderUsage, ProviderFailure> {
        guard let response = AgyUsageResponse.decode(output) else {
            return .failure(ProviderFailure(.unparsable, raw: redacted(output)))
        }
        if response.status == "ERROR" {
            let message = response.error ?? ""
            let error: ProviderError = message.localizedCaseInsensitiveContains("authentication")
                ? .notLoggedIn : .failed(message)
            return .failure(ProviderFailure(error, raw: message))
        }
        let raw = redacted(output)
        let windows = response.windows
        guard !windows.isEmpty else { return .failure(ProviderFailure(.unparsable, raw: raw)) }
        return .success(ProviderUsage(windows: windows, fetchedAt: date, raw: raw))
    }

    /// Pretty JSON of `command.data` only, for the raw output window.
    static func redacted(_ output: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let command = obj["command"] as? [String: Any], let usage = command["data"],
              let data = try? JSONSerialization.data(withJSONObject: usage, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Collects stdout until it closes, and watches stderr for the sign-in prompt, which comes
/// about 60 s before the CLI gives up on its own.
private final class Output: @unchecked Sendable {
    enum Outcome { case finished(Data), notLoggedIn, timeout }

    let stdout = Pipe()
    let stderr = Pipe()
    private let lock = NSCondition()
    private var out = Data()
    private var err = Data()
    private var outClosed = false

    init() {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.update { s in
                if data.isEmpty { s.outClosed = true; handle.readabilityHandler = nil } else { s.out.append(data) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.update { s in
                if data.isEmpty { handle.readabilityHandler = nil } else { s.err.append(data) }
            }
        }
    }

    private func update(_ change: (Output) -> Void) {
        lock.lock()
        change(self)
        lock.broadcast()
        lock.unlock()
    }

    func wait(until deadline: Date) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if String(decoding: err, as: UTF8.self).contains("Authentication required") { return .notLoggedIn }
            if outClosed { return .finished(out) }
            if !lock.wait(until: deadline) { return .timeout }
        }
    }

    func stopReading() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }
}
