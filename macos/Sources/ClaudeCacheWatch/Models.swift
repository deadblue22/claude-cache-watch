import Foundation

struct CacheSnapshot: Decodable, Sendable {
    let generatedAtSGT: String
    let timezone: String
    let sessions: [SessionSnapshot]

    enum CodingKeys: String, CodingKey {
        case generatedAtSGT = "generated_at_sgt"
        case timezone
        case sessions
    }
}

struct SessionSnapshot: Decodable, Identifiable, Sendable {
    let sessionID: String
    let title: String?
    let cwd: String?
    let entrypoint: String?
    let claudeCodeVersion: String?
    let lastPrompt: String?
    let running: Bool
    let transcriptPath: String?
    let lastActivitySGT: String?
    let cache: CacheInfo?

    var id: String { sessionID }
    var displayTitle: String {
        guard let title, !title.isEmpty else { return "未命名 session" }
        return title
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "路径不可用" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var compactProjectPath: String {
        guard let cwd, !cwd.isEmpty else { return "项目路径不可用" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title
        case cwd
        case entrypoint
        case claudeCodeVersion = "claude_code_version"
        case lastPrompt = "last_prompt"
        case running
        case transcriptPath = "transcript_path"
        case lastActivitySGT = "last_activity_sgt"
        case cache
    }

    func status(at now: Date) -> CacheDisplayStatus {
        guard let cache else {
            return transcriptPath == nil ? .noData : .noCache
        }
        let states = cache.entries.map { entry -> CacheDisplayStatus in
            guard let earliest = entry.expiresAtEarliest, let latest = entry.expiresAtLatest else {
                return .noData
            }
            if now < earliest { return .valid }
            if now < latest { return .uncertain }
            return .expired
        }
        guard !states.isEmpty else { return .noCache }
        if states.allSatisfy({ $0 == .valid }) { return .valid }
        if states.allSatisfy({ $0 == .expired }) { return .expired }
        if states.count == 1 { return .uncertain }
        return .partial
    }

    var primaryCacheEntry: CacheEntry? {
        cache?.entries.min { lhs, rhs in
            lhs.ttlSeconds < rhs.ttlSeconds
        }
    }
}

struct CacheInfo: Decodable, Sendable {
    let status: String?
    let requestID: String
    let requestStartedAfterSGT: String
    let requestStartedBeforeSGT: String
    let ttlSource: String
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let entries: [CacheEntry]

    enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case requestStartedAfterSGT = "request_started_after_sgt"
        case requestStartedBeforeSGT = "request_started_before_sgt"
        case ttlSource = "ttl_source"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case entries
    }
}

struct CacheEntry: Decodable, Sendable {
    let ttl: String
    let remainingSecondsLower: Int
    let remainingSecondsUpper: Int
    let expiresAtEarliestSGT: String
    let expiresAtLatestSGT: String

    var ttlSeconds: TimeInterval {
        switch ttl {
        case "1h": return 3_600
        default: return 300
        }
    }

    var expiresAtEarliest: Date? { ISODateParser.parse(expiresAtEarliestSGT) }
    var expiresAtLatest: Date? { ISODateParser.parse(expiresAtLatestSGT) }

    enum CodingKeys: String, CodingKey {
        case ttl
        case remainingSecondsLower = "remaining_seconds_lower"
        case remainingSecondsUpper = "remaining_seconds_upper"
        case expiresAtEarliestSGT = "expires_at_earliest_sgt"
        case expiresAtLatestSGT = "expires_at_latest_sgt"
    }
}

enum CacheDisplayStatus: String {
    case valid
    case uncertain
    case partial
    case expired
    case noCache
    case noData

    var label: String {
        switch self {
        case .valid: return "有效"
        case .uncertain: return "判定区间"
        case .partial: return "部分有效"
        case .expired: return "已过期"
        case .noCache: return "无缓存"
        case .noData: return "无记录"
        }
    }
}

enum MonitorScope: String, CaseIterable, Identifiable {
    case active
    case recent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "运行中"
        case .recent: return "最近记录"
        }
    }
}

enum ISODateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

func formatRemaining(for entry: CacheEntry, now: Date) -> String {
    guard let earliest = entry.expiresAtEarliest, let latest = entry.expiresAtLatest else {
        return "不可判定"
    }
    let lower = max(0, earliest.timeIntervalSince(now))
    let upper = max(0, latest.timeIntervalSince(now))
    if upper <= 0 { return "已过期" }
    if lower <= 0 { return "0–\(formatDuration(upper))" }
    let lowerText = formatDuration(lower)
    let upperText = formatDuration(upper)
    return lowerText == upperText ? lowerText : "\(lowerText)–\(upperText)"
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%02d:%02d", minutes, seconds)
}

func formatExpiry(for entry: CacheEntry, now: Date) -> String {
    guard let earliest = entry.expiresAtEarliest, let latest = entry.expiresAtLatest else {
        return "过期时间不可判定"
    }
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
    formatter.dateFormat = "HH:mm:ss"
    if latest <= now {
        return "已于 \(formatter.string(from: latest)) SGT 过期"
    }
    let first = formatter.string(from: earliest)
    let last = formatter.string(from: latest)
    if first == last { return "预计 \(first) SGT 过期" }
    return "预计 \(first)–\(last) SGT 过期"
}

func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fk", Double(value) / 1_000)
    }
    return String(value)
}
