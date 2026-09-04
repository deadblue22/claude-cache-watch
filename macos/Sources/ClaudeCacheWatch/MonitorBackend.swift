import Foundation

enum MonitorBackendError: LocalizedError {
    case scriptNotFound
    case pythonNotFound
    case launchFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "The bundled monitor script could not be found."
        case .pythonNotFound:
            return "Python 3 could not be found. Set CLAUDE_CACHE_WATCH_PYTHON to its path."
        case .launchFailed(let detail):
            return "Unable to start the local monitor: \(detail)"
        case .processFailed(let detail):
            return "The local monitor stopped: \(detail)"
        }
    }
}

final class MonitorProcess {
    private var process: Process?
    private var readerTask: Task<Void, Never>?

    func start(scope: MonitorScope) throws -> AsyncThrowingStream<CacheSnapshot, Error> {
        stop()

        guard let scriptURL = Self.findScript() else {
            throw MonitorBackendError.scriptNotFound
        }
        guard let pythonURL = Self.findPython() else {
            throw MonitorBackendError.pythonNotFound
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = pythonURL
        var arguments = [scriptURL.path, "--json", "--watch", "2"]
        if scope == .recent {
            arguments.append(contentsOf: ["--all", "--limit", "30"])
        }
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw MonitorBackendError.launchFailed(error.localizedDescription)
        }
        self.process = process

        return AsyncThrowingStream { continuation in
            self.readerTask = Task.detached(priority: .utility) {
                do {
                    for try await line in outputPipe.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        guard let data = line.data(using: .utf8) else { continue }
                        do {
                            let snapshot = try JSONDecoder().decode(CacheSnapshot.self, from: data)
                            continuation.yield(snapshot)
                        } catch {
                            continue
                        }
                    }

                    process.waitUntilExit()
                    if !Task.isCancelled && process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.finish(throwing: MonitorBackendError.processFailed(detail ?? "exit code \(process.terminationStatus)"))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    deinit {
        stop()
    }

    private static func findScript() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CACHE_WATCH_SCRIPT"] {
            let url = URL(fileURLWithPath: override)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "claude_cache_watch", withExtension: "py") {
            return bundled
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentScript = repositoryRoot.appendingPathComponent("claude_cache_watch.py")
        return fileManager.fileExists(atPath: developmentScript.path) ? developmentScript : nil
    }

    private static func findPython() -> URL? {
        let fileManager = FileManager.default
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CACHE_WATCH_PYTHON"] {
            paths.append(override)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ])
        return paths.lazy
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
