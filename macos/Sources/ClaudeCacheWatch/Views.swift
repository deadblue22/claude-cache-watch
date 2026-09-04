import AppKit
import SwiftUI

struct CachePanel: View {
    @ObservedObject var model: CacheWatchModel
    @AppStorage("pinWindowOnTop") private var isPinned = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 416)
        .background(WindowLevelConfigurator(isPinned: isPinned))
        .task { model.start() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(headerStatusColor)
                .frame(width: 6, height: 6)
            Text(summaryText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 25, height: 25)
                    .foregroundStyle(isPinned ? Color.accentColor : Color.primary)
                    .background(
                        isPinned ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消窗口置顶" : "窗口置顶")
            .accessibilityLabel(isPinned ? "取消窗口置顶" : "窗口置顶")
            Button {
                model.restartMonitor()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 25, height: 25)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("每 2 秒自动更新；点击立即刷新")
            .accessibilityLabel("立即刷新")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summaryText: String {
        if model.isConnecting { return "正在读取 Session…" }
        if model.errorMessage != nil { return "读取失败" }
        if model.sessions.isEmpty { return "没有运行中的 Session" }
        return "\(model.sessions.count) 个运行中的 Session"
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
                    Text("读取 ~/.claude 中的 session 记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.snapshot == nil {
                ErrorState(message: error) {
                    model.restartMonitor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sessions.isEmpty {
                EmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, now: model.now)
                            if index < model.sessions.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }
                .scrollIndicators(model.sessions.count > 5 ? .visible : .hidden)
            }
        }
        .frame(height: contentHeight)
    }

    private var contentHeight: CGFloat {
        if model.isConnecting || model.errorMessage != nil || model.sessions.isEmpty { return 118 }
        let rowsHeight = CGFloat(model.sessions.count) * 72
        let dividersHeight = CGFloat(max(0, model.sessions.count - 1))
        return min(365, max(72, rowsHeight + dividersHeight))
    }
}

private struct WindowLevelConfigurator: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            view.window?.level = isPinned ? .floating : .normal
        }
    }
}

struct SessionRow: View {
    let session: SessionSnapshot
    let now: Date
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
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(remainingText)
                            .font(.system(size: status == .expired ? 14 : 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(color)
                        if status == .valid {
                            Text("后过期")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(session.displayModel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .fixedSize()
                    Text(session.compactProjectPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.cwd ?? "")
                }
                Text(session.lastPrompt ?? "暂无指令记录")
                    .font(.system(size: 10.5))
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
        .help("切换到 Claude Code Desktop")
        .contextMenu {
            if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
                Button("在 Finder 中打开项目") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                }
            }
            Button("复制 Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionID, forType: .string)
            }
        }
    }

    private var remainingText: String {
        guard let entry = session.primaryCacheEntry,
              let expiry = entry.expiresAtEarliest else {
            return status == .noData ? "无记录" : "无缓存"
        }
        if expiry <= now { return status == .uncertain ? "即将过期" : "已过期" }
        return formatDuration(expiry.timeIntervalSince(now))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有运行中的 Desktop session")
                .font(.system(size: 12, weight: .medium))
            Text("在 Claude Code Desktop 中开始或继续一个 session 后会自动显示。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
    }
}

struct ErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 21))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text("无法读取 session")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("重试", action: retry)
        }
    }
}
