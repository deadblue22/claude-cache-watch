import Foundation

@MainActor
final class CacheWatchModel: ObservableObject {
    @Published private(set) var snapshot: CacheSnapshot?
    @Published private(set) var now = Date()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConnecting = true
    @Published var scope: MonitorScope = .active {
        didSet {
            if scope != oldValue { restartMonitor() }
        }
    }

    private var monitor: MonitorProcess?
    private var streamTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var started = false

    var sessions: [SessionSnapshot] { snapshot?.sessions ?? [] }

    var validCount: Int {
        sessions.filter { $0.status(at: now) == .valid }.count
    }

    var attentionCount: Int {
        sessions.filter { [.uncertain, .partial, .expired].contains($0.status(at: now)) }.count
    }

    var menuBarIcon: String {
        if errorMessage != nil { return "exclamationmark.triangle" }
        if sessions.contains(where: { [.uncertain, .partial].contains($0.status(at: now)) }) {
            return "exclamationmark.circle"
        }
        if sessions.contains(where: { $0.status(at: now) == .valid }) {
            return "timer"
        }
        return "timer.circle"
    }

    func start() {
        guard !started else { return }
        started = true
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        restartMonitor()
    }

    func restartMonitor() {
        streamTask?.cancel()
        monitor?.stop()
        errorMessage = nil
        isConnecting = true

        let monitor = MonitorProcess()
        self.monitor = monitor
        do {
            let stream = try monitor.start(scope: scope)
            streamTask = Task { [weak self] in
                do {
                    for try await snapshot in stream {
                        guard !Task.isCancelled else { break }
                        self?.snapshot = snapshot
                        self?.errorMessage = nil
                        self?.isConnecting = false
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.errorMessage = error.localizedDescription
                    self?.isConnecting = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isConnecting = false
        }
    }

    deinit {
        streamTask?.cancel()
        clockTask?.cancel()
        monitor?.stop()
    }
}
