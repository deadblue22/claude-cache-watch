import AppKit
import SwiftUI

struct CachePanel: View {
    @ObservedObject var model: CacheWatchModel
    @AppStorage("pinWindowOnTop") private var isPinned = false
    @State private var windowWidth: CGFloat = 416

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            statusBar
        }
        .frame(
            minWidth: 320,
            idealWidth: 416,
            maxWidth: .infinity,
            minHeight: 103,
            idealHeight: preferredContentHeight + 31,
            maxHeight: .infinity
        )
        .background(
            WindowConfigurator(
                isPinned: isPinned,
                preferredContentHeight: preferredContentHeight + 31
            )
        )
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WindowWidthPreferenceKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(WindowWidthPreferenceKey.self) { windowWidth = $0 }
        .task { model.start() }
    }

    private var textScale: CGFloat {
        min(1.2, max(0.88, windowWidth / 416))
    }

    private var statusBar: some View {
        HStack(alignment: .center, spacing: 7) {
            Circle()
                .fill(headerStatusColor)
                .frame(width: 5, height: 5)
            Text(summaryText)
                .font(.system(size: 10.5 * textScale, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(isPinned ? Color.accentColor : Color.primary)
                    .background(
                        isPinned ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin window" : "Keep window on top")
            .accessibilityLabel(isPinned ? "Unpin window" : "Keep window on top")
            Button {
                model.restartMonitor()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Updates every 2 seconds; click to refresh now")
            .accessibilityLabel("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var summaryText: String {
        if model.isConnecting { return "Loading sessions…" }
        if model.errorMessage != nil { return "Unable to read sessions" }
        if model.sessions.isEmpty { return "No monitored sessions" }
        let count = model.sessions.count
        return "\(count) monitored \(count == 1 ? "session" : "sessions")"
    }

    private var headerStatusColor: Color {
        if model.errorMessage != nil { return Color(nsColor: .systemRed) }
        if model.isConnecting { return Color(nsColor: .systemOrange) }
        if model.sessions.isEmpty { return .secondary.opacity(0.6) }
        return Color(nsColor: .systemGreen)
    }

    private var content: some View {
        Group {
            if model.isConnecting && model.snapshot == nil {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading session data from ~/.claude")
                        .font(.system(size: 12 * textScale))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.snapshot == nil {
                ErrorState(message: error, textScale: textScale) {
                    model.restartMonitor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sessions.isEmpty {
                EmptyState(textScale: textScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, now: model.now, textScale: textScale)
                            if index < model.sessions.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 72, idealHeight: preferredContentHeight, maxHeight: .infinity)
    }

    private var preferredContentHeight: CGFloat {
        if model.isConnecting || model.errorMessage != nil || model.sessions.isEmpty { return 118 }
        let rowsHeight = CGFloat(model.sessions.count) * 72
        let dividersHeight = CGFloat(max(0, model.sessions.count - 1))
        return min(510, max(72, rowsHeight + dividersHeight))
    }
}

private struct WindowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 416

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let preferredContentHeight: CGFloat

    final class Coordinator {
        var lastPreferredContentHeight: CGFloat?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    private func apply(to view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = isPinned ? .floating : .normal

            if let lastHeight = coordinator.lastPreferredContentHeight,
               abs(lastHeight - preferredContentHeight) < 0.5 {
                return
            }

            let currentFrame = window.frame
            let currentContentHeight = window.contentLayoutRect.height
            if abs(currentContentHeight - preferredContentHeight) >= 0.5 {
                let titleBarHeight = max(0, currentFrame.height - currentContentHeight)
                let targetFrameHeight = preferredContentHeight + titleBarHeight
                let currentTop = currentFrame.maxY
                let minimumY = window.screen?.visibleFrame.minY ?? currentFrame.minY
                var targetFrame = currentFrame
                targetFrame.size.height = targetFrameHeight
                targetFrame.origin.y = max(minimumY, currentTop - targetFrameHeight)
                window.setFrame(
                    targetFrame,
                    display: true,
                    animate: coordinator.lastPreferredContentHeight != nil
                )
            }
            coordinator.lastPreferredContentHeight = preferredContentHeight
        }
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let now: Date
    let textScale: CGFloat
    @State private var isHovered = false

    private var status: CacheDisplayStatus { session.status(at: now) }
    private var color: Color {
        switch status {
        case .valid: return Color(nsColor: .systemGreen)
        case .uncertain, .partial: return Color(nsColor: .systemOrange)
        case .expired: return Color(nsColor: .systemRed)
        case .noCache, .noData: return .secondary
        }
    }

    var body: some View {
        Button {
            ClaudeDesktopOpener.activate()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session.displayTitle)
                        .font(.system(size: 13 * textScale, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(remainingText)
                            .font(.system(size: (status == .expired ? 14 : 17) * textScale, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(color)
                        if status == .valid {
                            Text("left")
                                .font(.system(size: 9 * textScale, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(session.displayModel)
                        .font(.system(size: 9.5 * textScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor, in: Capsule())
                        .fixedSize()
                    Text(session.compactProjectPath)
                        .font(.system(size: 10 * textScale, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.cwd ?? "")
                }
                Text(session.lastPrompt ?? "No instruction recorded")
                    .font(.system(size: 10.5 * textScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 72)
            .contentShape(Rectangle())
            .background(isHovered ? Color.accentColor.opacity(0.055) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Switch to Claude Code Desktop")
        .contextMenu {
            if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
                Button("Open Project in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionID, forType: .string)
            }
        }
    }

    private var remainingText: String {
        guard let entry = session.primaryCacheEntry,
              let expiry = entry.expiresAtEarliest else {
            return status == .noData ? "No data" : "No cache"
        }
        if expiry <= now { return status == .uncertain ? "Expiring" : "Expired" }
        return formatDuration(expiry.timeIntervalSince(now))
    }
}

struct EmptyState: View {
    let textScale: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(.secondary)
            Text("No active or cached Desktop sessions")
                .font(.system(size: 12 * textScale, weight: .medium))
            Text("Start a session in Claude Code Desktop and it will appear here while active or cached.")
                .font(.system(size: 10.5 * textScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
    }
}

struct ErrorState: View {
    let message: String
    let textScale: CGFloat
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 21))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text("Unable to Read Sessions")
                .font(.system(size: 12 * textScale, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5 * textScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Retry", action: retry)
                .font(.system(size: 11 * textScale))
        }
    }
}
