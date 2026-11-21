// AI Session Viewer データエンジン (Claude Code + Antigravity 統合版)。
// ~/.claude/projects/ および ~/.gemini/antigravity*/ 配下のセッションを読み取り専用で解析する。
import Foundation
import SQLite3

enum Engine {
    static let truncateLimit = 10000
    static let unassignedProject = "_unassigned"

    static func claudeProjectsDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_PROJECTS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    static func antigravityDirs() -> [URL] {
        if let env = ProcessInfo.processInfo.environment["ANTIGRAVITY_HOME"], !env.isEmpty {
            return env.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".gemini/antigravity-cli"),
            home.appendingPathComponent(".gemini/antigravity"),
        ]
    }

    // MARK: - 共通ユーティリティ

    private static func opt(_ s: String?) -> Any {
        s ?? NSNull()
    }

    static func encodeProject(_ cwd: String?, fallbackClaudeDir: String? = nil) -> String {
        if let cwd, !cwd.isEmpty {
            return Data(cwd.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        if let dir = fallbackClaudeDir, !dir.isEmpty {
            return "c_" + dir
        }
        return unassignedProject
    }

    static func fileUriToPath(_ uri: String) -> String {
        if uri.hasPrefix("file://") {
            let stripped = String(uri.dropFirst(7))
            return stripped.removingPercentEncoding ?? stripped
        }
        return uri
    }

    static func parseWorkspaceUris(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              let arr = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String],
              let first = arr.first, !first.isEmpty else { return nil }
        return fileUriToPath(first)
    }

    static func parseLine(_ line: Substring) -> [String: Any]? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func truncate(_ s: String, _ n: Int = truncateLimit) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n)) + "\n… (\(s.count - n) 文字省略)"
    }

    static func mtimeMs(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    static func jsonlFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    // 軽量メタキャッシュ (filePath -> CachedMeta)
    private struct FileMeta {
        let mtime: Double
        let title: String?
        let firstPrompt: String?
        let firstTs: String?
        let cwd: String?
    }
    private static var metaCache: [String: FileMeta] = [:]
    private static let metaLock = NSLock()

    // MARK: - 共通レコード

    struct SessionRecord {
        let id: String
        let source: String // "claude" | "antigravity"
        let fileURL: URL
        let size: Int
        let mtime: Double
        var title: String?
        var preview: String?
        var firstPrompt: String?
        var firstTs: String?
        var cwd: String?
        var project: String
        let parentId: String?
        let agentName: String?
    }

    // ============================================================
    // MARK: - Claude Code パーサ
    // ============================================================

    static let claudeInjectedTags = [
        "task-notification", "system-reminder", "bash-stdout", "bash-stderr", "bash-input",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
    ]

    static func claudeInjectedTag(_ content: String) -> String? {
        for tag in claudeInjectedTags {
            if content.hasPrefix("<\(tag)>") && content.contains("</\(tag)>") { return tag }
        }
        if content.hasPrefix("<hook-"),
           let end = content.dropFirst(1).firstIndex(of: ">") {
            let tag = String(content[content.index(content.startIndex, offsetBy: 1)..<end])
            if content.contains("</\(tag)>") { return tag }
        }
        return nil
    }

    static func claudeToolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    static func claudeToolInputSummary(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty {
                return String(v.split(separator: "\n", omittingEmptySubsequences: false)[0].prefix(100))
            }
        }
        return ""
    }

    private static func claudeSessionMeta(_ file: URL, mtime: Double) -> FileMeta {
        metaLock.lock()
        if let cached = metaCache[file.path], cached.mtime == mtime {
            metaLock.unlock()
            return cached
        }
        metaLock.unlock()

        let meta: FileMeta = autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                return FileMeta(mtime: mtime, title: nil, firstPrompt: nil, firstTs: nil, cwd: nil)
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            var title: String?
            var firstPrompt: String?
            var firstTs: String?
            var cwd: String?
            for line in text.split(separator: "\n") {
                guard let row = parseLine(line) else { continue }
                let type = row["type"] as? String
                if type == "ai-title", title == nil { title = row["aiTitle"] as? String }
                if type == "summary", title == nil { title = row["summary"] as? String }
                if firstTs == nil { firstTs = row["timestamp"] as? String }
                if cwd == nil { cwd = row["cwd"] as? String }
                if firstPrompt == nil, type == "user",
                   let message = row["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.hasPrefix("<") {
                    firstPrompt = String(content.prefix(120))
                }
                if title != nil && firstPrompt != nil && cwd != nil { break }
            }
            return FileMeta(mtime: mtime, title: title, firstPrompt: firstPrompt, firstTs: firstTs, cwd: cwd)
        }
        metaLock.lock()
        metaCache[file.path] = meta
        metaLock.unlock()
        return meta
    }

    static func collectClaudeSessions() -> [SessionRecord] {
        let fm = FileManager.default
        let base = claudeProjectsDir()
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [SessionRecord] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = jsonlFiles(in: dir)
            guard !files.isEmpty else { continue }

            var dirCwd: String?
            var recs: [SessionRecord] = []
            for file in files {
                let mtime = mtimeMs(file)
                let meta = claudeSessionMeta(file, mtime: mtime)
                if dirCwd == nil, let c = meta.cwd { dirCwd = c }
                recs.append(SessionRecord(
                    id: file.deletingPathExtension().lastPathComponent,
                    source: "claude",
                    fileURL: file,
                    size: fileSize(file),
                    mtime: mtime,
                    title: meta.title,
                    preview: nil,
                    firstPrompt: meta.firstPrompt,
                    firstTs: meta.firstTs,
                    cwd: meta.cwd,
                    project: "",
                    parentId: nil,
                    agentName: nil
                ))
            }
            for i in 0..<recs.count {
                let cwd = recs[i].cwd ?? dirCwd
                recs[i].cwd = cwd
                recs[i].project = encodeProject(cwd, fallbackClaudeDir: dir.lastPathComponent)
                out.append(recs[i])
            }
        }
        return out
    }

    static func parseClaudeSession(file: URL, includeSidechain: Bool) -> Any {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return ["error": "not found"]
        }
        let messages = NSMutableArray()
        var toolUseIndex: [String: NSMutableDictionary] = [:]

        autoreleasepool {
            for line in text.split(separator: "\n") {
                guard let row = parseLine(line) else { continue }
                let sidechain = row["isSidechain"] as? Bool ?? false
                if sidechain && !includeSidechain { continue }
                let type = row["type"] as? String
                let ts = opt(row["timestamp"] as? String)
                let message = row["message"] as? [String: Any]

                if type == "summary", let summary = row["summary"] as? String {
                    messages.add(["kind": "summary", "text": summary, "ts": ts, "source": "claude"])
                    continue
                }

                if type == "user" {
                    if let content = message?["content"] as? String {
                        if content.hasPrefix("<command-name>"),
                           let range = content.range(of: "</command-name>") {
                            let cmd = String(content[content.index(content.startIndex, offsetBy: 14)..<range.lowerBound])
                            messages.add(["kind": "command", "text": cmd.trimmingCharacters(in: .whitespaces), "ts": ts, "source": "claude"])
                        } else if let tag = claudeInjectedTag(content) {
                            messages.add(["kind": "system", "label": tag, "text": truncate(content, 4000), "ts": ts, "sidechain": sidechain, "source": "claude"])
                        } else if row["isMeta"] as? Bool == true || content.hasPrefix("[Request interrupted") {
                            messages.add(["kind": "system", "label": "meta", "text": truncate(content, 4000), "ts": ts, "sidechain": sidechain, "source": "claude"])
                        } else {
                            messages.add(["kind": "user", "text": content, "ts": ts, "sidechain": sidechain, "source": "claude"])
                        }
                    } else if let blocks = message?["content"] as? [[String: Any]] {
                        let hasImage = blocks.contains { $0["type"] as? String == "image" }
                        for block in blocks {
                            switch block["type"] as? String {
                            case "tool_result":
                                let resultText = truncate(claudeToolResultText(block["content"]))
                                if let useId = block["tool_use_id"] as? String, let entry = toolUseIndex[useId] {
                                    entry["result"] = resultText
                                    entry["isError"] = block["is_error"] as? Bool ?? false
                                } else {
                                    messages.add([
                                        "kind": "tool", "name": "(不明なツール)", "input": "", "inputSummary": "",
                                        "result": resultText, "isError": block["is_error"] as? Bool ?? false,
                                        "ts": ts, "sidechain": sidechain, "source": "claude",
                                    ])
                                }
                            case "text":
                                guard let t = block["text"] as? String,
                                      !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                                if hasImage && row["isMeta"] as? Bool != true {
                                    messages.add(["kind": "user", "text": t, "ts": ts, "sidechain": sidechain, "source": "claude"])
                                } else {
                                    messages.add(["kind": "system", "label": "injected", "text": truncate(t, 4000), "ts": ts, "sidechain": sidechain, "source": "claude"])
                                }
                            case "image":
                                messages.add(["kind": "user", "text": "(画像添付)", "ts": ts, "source": "claude"])
                            default: break
                            }
                        }
                    }
                    continue
                }

                if type == "assistant", let blocks = message?["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String,
                               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                messages.add([
                                    "kind": "assistant", "text": t, "ts": ts,
                                    "model": opt(message?["model"] as? String),
                                    "sidechain": sidechain, "source": "claude",
                                ])
                            }
                        case "thinking":
                            if let t = block["thinking"] as? String,
                               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                messages.add([
                                    "kind": "thinking", "text": truncate(t, 3000),
                                    "ts": ts, "sidechain": sidechain, "source": "claude",
                                ])
                            }
                        case "tool_use":
                            let input = block["input"] as? [String: Any]
                            let inputJson = (input.flatMap {
                                try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys])
                            }).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                            let entry = NSMutableDictionary(dictionary: [
                                "kind": "tool",
                                "name": block["name"] as? String ?? "?",
                                "input": truncate(inputJson),
                                "inputSummary": claudeToolInputSummary(input),
                                "result": NSNull(),
                                "isError": false,
                                "ts": ts,
                                "sidechain": sidechain,
                                "source": "claude",
                            ])
                            if let blockId = block["id"] as? String { toolUseIndex[blockId] = entry }
                            messages.add(entry)
                        default: break
                        }
                    }
                }
            }
        }
        return messages
    }

    // ============================================================
    // MARK: - Antigravity パーサ
    // ============================================================

    struct DbSummary {
        var title: String?
        var preview: String?
        var cwd: String?
        var parentId: String?
        var agentName: String?
        var nestingDepth: Int = 0
    }

    private static func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    static func readSummariesDb(_ dbURL: URL) -> [String: DbSummary] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [:] }
        let sql = """
        SELECT conversation_id, title, preview, workspace_uris, agent_name, parent_conversation_id, nesting_depth
        FROM conversation_summaries
        """

        // WALモードDBではSQLITE_OPEN_READONLYが-shmマップで失敗する場合があるため、
        // 失敗時はSQLITE_OPEN_READWRITE + PRAGMA query_only = ON (読み取り専用) で開く
        func queryRows(flags: Int32, setQueryOnly: Bool) -> [String: DbSummary]? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return nil
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            if setQueryOnly {
                guard sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil) == SQLITE_OK else {
                    return nil
                }
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }

            var rows: [String: DbSummary] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = colText(stmt, 0) else { continue }
                rows[id] = DbSummary(
                    title: colText(stmt, 1),
                    preview: colText(stmt, 2),
                    cwd: parseWorkspaceUris(colText(stmt, 3)),
                    parentId: colText(stmt, 5),
                    agentName: colText(stmt, 4),
                    nestingDepth: Int(sqlite3_column_int(stmt, 6))
                )
            }
            return rows
        }

        if let rows = queryRows(flags: SQLITE_OPEN_READONLY, setQueryOnly: false) { return rows }
        if let rows = queryRows(flags: SQLITE_OPEN_READWRITE, setQueryOnly: true) { return rows }
        return [:]
    }

    static func readHistoryWorkspaces(_ historyURL: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return result }
        autoreleasepool {
            guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard let row = parseLine(line),
                      let cid = row["conversationId"] as? String,
                      let ws = row["workspace"] as? String,
                      !cid.isEmpty, !ws.isEmpty,
                      result[cid] == nil else { continue }
                result[cid] = ws
            }
        }
        return result
    }

    private static let localTimeOnlyRegex = try! NSRegularExpression(
        pattern: "<ADDITIONAL_METADATA>\\s*The current local time is:[^\\n]*\\s*</ADDITIONAL_METADATA>"
    )
    private static let slashCommandOnlyRegex = try! NSRegularExpression(pattern: "^/[A-Za-z0-9:_-]+$")
    private static let subagentIdRegex = try! NSRegularExpression(pattern: "\"conversationId\"\\s*:\\s*\"([A-Za-z0-9._-]+)\"")

    static func parseAgyUserInput(_ raw: String) -> (text: String, extraMeta: String?) {
        let startTag = "<USER_REQUEST>"
        let endTag = "</USER_REQUEST>"
        if let sRange = raw.range(of: startTag),
           let eRange = raw.range(of: endTag, range: sRange.upperBound..<raw.endIndex) {
            let text = raw[sRange.upperBound..<eRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = raw[eRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            var extraMeta: String?
            if !after.isEmpty {
                let nsAfter = after as NSString
                let stripped = localTimeOnlyRegex
                    .stringByReplacingMatches(in: after, range: NSRange(location: 0, length: nsAfter.length), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty { extraMeta = stripped }
            }
            return (text, extraMeta)
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    static func isSlashCommandOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        return slashCommandOnlyRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func cleanAgyToolArgs(_ args: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in args {
            if let s = v as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let looksJson =
                    (t.hasPrefix("\"") && t.hasSuffix("\"")) ||
                    (t.hasPrefix("{") && t.hasSuffix("}")) ||
                    (t.hasPrefix("[") && t.hasSuffix("]")) ||
                    t == "true" || t == "false"
                if looksJson,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]) {
                    out[k] = parsed
                    continue
                }
            }
            out[k] = v
        }
        return out
    }

    static func agyToolInputSummary(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        let keys = [
            "CommandLine", "command",
            "Path", "file_path", "path",
            "query", "Query",
            "url", "Url", "URL",
            "pattern", "Pattern",
            "toolSummary", "Role", "Description", "description",
            "Prompt", "prompt", "Message", "message",
        ]
        for key in keys {
            if let v = input[key] as? String {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return String(trimmed.split(separator: "\n", omittingEmptySubsequences: false)[0].prefix(100))
                }
            }
        }
        return ""
    }

    private static func agySessionFileMeta(_ file: URL, mtime: Double) -> FileMeta {
        metaLock.lock()
        if let cached = metaCache[file.path], cached.mtime == mtime {
            metaLock.unlock()
            return cached
        }
        metaLock.unlock()

        let meta: FileMeta = autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                return FileMeta(mtime: mtime, title: nil, firstPrompt: nil, firstTs: nil, cwd: nil)
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            var firstPrompt: String?
            var firstTs: String?
            for line in text.split(separator: "\n") {
                guard let row = parseLine(line) else { continue }
                if firstTs == nil { firstTs = row["created_at"] as? String }
                if firstPrompt == nil,
                   row["type"] as? String == "USER_INPUT",
                   let content = row["content"] as? String {
                    let parsed = parseAgyUserInput(content).text
                    if !parsed.isEmpty {
                        let collapsed = parsed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        firstPrompt = String(collapsed.prefix(120))
                    }
                }
                if firstPrompt != nil && firstTs != nil { break }
            }
            return FileMeta(mtime: mtime, title: nil, firstPrompt: firstPrompt, firstTs: firstTs, cwd: nil)
        }
        metaLock.lock()
        metaCache[file.path] = meta
        metaLock.unlock()
        return meta
    }

    static func resolveAgyTranscriptURL(_ brainSessionDir: URL) -> URL? {
        let logsDir = brainSessionDir.appendingPathComponent(".system_generated/logs")
        let full = logsDir.appendingPathComponent("transcript_full.jsonl")
        if FileManager.default.fileExists(atPath: full.path) { return full }
        let compact = logsDir.appendingPathComponent("transcript.jsonl")
        if FileManager.default.fileExists(atPath: compact.path) { return compact }
        return nil
    }

    static func collectAntigravitySessions() -> [String: SessionRecord] {
        let fm = FileManager.default
        let dirs = antigravityDirs()
        var dbMetaAll: [String: DbSummary] = [:]

        for baseDir in dirs {
            guard fm.fileExists(atPath: baseDir.path) else { continue }
            let dbMap = readSummariesDb(baseDir.appendingPathComponent("conversation_summaries.db"))
            for (id, meta) in dbMap {
                if var prev = dbMetaAll[id] {
                    if prev.title == nil { prev.title = meta.title }
                    if prev.preview == nil { prev.preview = meta.preview }
                    if prev.cwd == nil { prev.cwd = meta.cwd }
                    if prev.parentId == nil { prev.parentId = meta.parentId }
                    if prev.agentName == nil { prev.agentName = meta.agentName }
                    if prev.nestingDepth == 0 { prev.nestingDepth = meta.nestingDepth }
                    dbMetaAll[id] = prev
                } else {
                    dbMetaAll[id] = meta
                }
            }
        }

        var byId: [String: SessionRecord] = [:]
        for baseDir in dirs {
            let brainDir = baseDir.appendingPathComponent("brain")
            guard let entries = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                continue
            }
            let histMap = readHistoryWorkspaces(baseDir.appendingPathComponent("history.jsonl"))
            for dir in entries {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let id = dir.lastPathComponent
                guard let fileURL = resolveAgyTranscriptURL(dir) else { continue }
                let dbm = dbMetaAll[id]
                let cwd = dbm?.cwd ?? histMap[id]
                let mtime = mtimeMs(fileURL)
                let rec = SessionRecord(
                    id: id,
                    source: "antigravity",
                    fileURL: fileURL,
                    size: fileSize(fileURL),
                    mtime: mtime,
                    title: dbm?.title,
                    preview: dbm?.preview,
                    firstPrompt: nil,
                    firstTs: nil,
                    cwd: cwd,
                    project: encodeProject(cwd),
                    parentId: dbm?.parentId,
                    agentName: dbm?.agentName
                )
                if let existing = byId[id] {
                    if rec.mtime > existing.mtime { byId[id] = rec }
                } else {
                    byId[id] = rec
                }
            }
        }
        return byId
    }

    private static func extractSubagentId(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = subagentIdRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func parseAgyTranscriptInto(
        _ rec: SessionRecord,
        agyById: [String: SessionRecord],
        includeSidechain: Bool,
        outMessages: NSMutableArray,
        visited: inout Set<String>,
        isSidechain: Bool = false,
        overrideAgentName: String? = nil
    ) {
        guard !visited.contains(rec.id) else { return }
        visited.insert(rec.id)

        let agentName = overrideAgentName ?? rec.agentName
        let subId: Any = isSidechain ? rec.id : NSNull()

        var childRecs: [SessionRecord] = []
        if includeSidechain {
            childRecs = agyById.values.filter { $0.parentId == rec.id }.sorted { $0.mtime < $1.mtime }
        }
        var insertedChildren = Set<String>()
        var pendingTools: [NSMutableDictionary] = []

        autoreleasepool {
            guard let text = try? String(contentsOf: rec.fileURL, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard let row = parseLine(line) else { continue }
                let type = row["type"] as? String
                let ts = opt(row["created_at"] as? String)

                if type == "USER_INPUT" {
                    let parsed = parseAgyUserInput(row["content"] as? String ?? "")
                    if !parsed.text.isEmpty {
                        outMessages.add([
                            "kind": isSlashCommandOnly(parsed.text) ? "command" : "user",
                            "text": parsed.text,
                            "ts": ts,
                            "sidechain": isSidechain,
                            "agentName": opt(agentName),
                            "subId": subId,
                            "source": "antigravity",
                        ])
                    }
                    if let extraMeta = parsed.extraMeta {
                        outMessages.add([
                            "kind": "system",
                            "label": "metadata",
                            "text": truncate(extraMeta, 4000),
                            "ts": ts,
                            "sidechain": isSidechain,
                            "agentName": opt(agentName),
                            "subId": subId,
                            "source": "antigravity",
                        ])
                    }
                    continue
                }

                if type == "SYSTEM_MESSAGE" {
                    if let content = row["content"] as? String,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        outMessages.add([
                            "kind": "system",
                            "label": "system-message",
                            "text": truncate(content, 4000),
                            "ts": ts,
                            "sidechain": isSidechain,
                            "agentName": opt(agentName),
                            "subId": subId,
                            "source": "antigravity",
                        ])
                    }
                    continue
                }

                if type == "PLANNER_RESPONSE" {
                    if let thinking = row["thinking"] as? String {
                        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            outMessages.add([
                                "kind": "thinking",
                                "text": truncate(trimmed, 3000),
                                "ts": ts,
                                "sidechain": isSidechain,
                                "agentName": opt(agentName),
                                "subId": subId,
                                "source": "antigravity",
                            ])
                        }
                    }
                    if let content = row["content"] as? String,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        outMessages.add([
                            "kind": "assistant",
                            "text": content,
                            "ts": ts,
                            "model": opt(row["model"] as? String),
                            "sidechain": isSidechain,
                            "agentName": opt(agentName),
                            "subId": subId,
                            "source": "antigravity",
                        ])
                    }
                    if let toolCalls = row["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let name = tc["name"] as? String ?? "?"
                            let rawArgs = tc["args"] as? [String: Any] ?? [:]
                            let cleaned = cleanAgyToolArgs(rawArgs)
                            let inputJson = (try? JSONSerialization.data(
                                withJSONObject: cleaned,
                                options: [.prettyPrinted, .sortedKeys]
                            )).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                            let entry = NSMutableDictionary(dictionary: [
                                "kind": "tool",
                                "name": name,
                                "input": truncate(inputJson),
                                "inputSummary": agyToolInputSummary(cleaned),
                                "result": NSNull(),
                                "isError": false,
                                "ts": ts,
                                "sidechain": isSidechain,
                                "agentName": opt(agentName),
                                "subId": subId,
                                "source": "antigravity",
                            ])
                            pendingTools.append(entry)
                            outMessages.add(entry)
                        }
                    }
                    continue
                }

                if type == "GENERIC" {
                    let content = row["content"] as? String ?? ""
                    let errText = row["error"] as? String ?? ""
                    let combined: String
                    if !errText.isEmpty && !content.contains(errText) {
                        combined = content.isEmpty ? errText : "\(content)\n\n[Error]\n\(errText)"
                    } else {
                        combined = content
                    }
                    let isError = (row["status"] as? String == "ERROR") || !errText.isEmpty
                    if !pendingTools.isEmpty {
                        let entry = pendingTools.removeFirst()
                        entry["result"] = truncate(combined)
                        entry["isError"] = isError
                        if includeSidechain,
                           entry["name"] as? String == "invoke_subagent",
                           let cid = extractSubagentId(content),
                           let child = agyById[cid],
                           !insertedChildren.contains(cid) {
                            insertedChildren.insert(cid)
                            parseAgyTranscriptInto(
                                child,
                                agyById: agyById,
                                includeSidechain: true,
                                outMessages: outMessages,
                                visited: &visited,
                                isSidechain: true,
                                overrideAgentName: child.agentName ?? "subagent"
                            )
                        }
                    } else if !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        outMessages.add([
                            "kind": "tool",
                            "name": "(ツール結果)",
                            "input": "",
                            "inputSummary": "",
                            "result": truncate(combined),
                            "isError": isError,
                            "ts": ts,
                            "sidechain": isSidechain,
                            "agentName": opt(agentName),
                            "subId": subId,
                            "source": "antigravity",
                        ])
                    }
                }
            }
        }

        if includeSidechain {
            for child in childRecs where !insertedChildren.contains(child.id) {
                insertedChildren.insert(child.id)
                parseAgyTranscriptInto(
                    child,
                    agyById: agyById,
                    includeSidechain: true,
                    outMessages: outMessages,
                    visited: &visited,
                    isSidechain: true,
                    overrideAgentName: child.agentName ?? "subagent"
                )
            }
        }
    }

    // ============================================================
    // MARK: - 統合API
    // ============================================================

    static func collectAll(sourceFilter: String = "all") -> [SessionRecord] {
        var topLevel: [SessionRecord] = []
        if sourceFilter == "all" || sourceFilter == "claude" {
            topLevel.append(contentsOf: collectClaudeSessions())
        }
        if sourceFilter == "all" || sourceFilter == "antigravity" {
            let agyById = collectAntigravitySessions()
            for rec in agyById.values {
                if let pid = rec.parentId, !pid.isEmpty, agyById[pid] != nil { continue }
                topLevel.append(rec)
            }
        }
        return topLevel
    }

    private static func hydrateSessionSummary(_ rec: SessionRecord) -> [String: Any] {
        if rec.source == "claude" {
            return [
                "id": rec.id,
                "source": "claude",
                "project": rec.project,
                "size": rec.size,
                "mtime": rec.mtime,
                "title": opt(rec.title),
                "firstPrompt": opt(rec.firstPrompt),
                "firstTs": opt(rec.firstTs),
                "cwd": opt(rec.cwd),
            ]
        }
        let fmeta = agySessionFileMeta(rec.fileURL, mtime: rec.mtime)
        return [
            "id": rec.id,
            "source": "antigravity",
            "project": rec.project,
            "size": rec.size,
            "mtime": rec.mtime,
            "title": opt(rec.title),
            "firstPrompt": opt(fmeta.firstPrompt ?? rec.preview),
            "firstTs": opt(fmeta.firstTs),
            "cwd": opt(rec.cwd),
        ]
    }

    static func listProjects(sourceFilter: String = "all") -> [[String: Any]] {
        let topLevel = collectAll(sourceFilter: sourceFilter)
        var byProj: [String: (cwd: String?, count: Int, claudeCount: Int, agyCount: Int, lastModified: Double)] = [:]
        for rec in topLevel {
            var entry = byProj[rec.project] ?? (cwd: rec.cwd, count: 0, claudeCount: 0, agyCount: 0, lastModified: 0)
            entry.count += 1
            if rec.source == "claude" { entry.claudeCount += 1 } else { entry.agyCount += 1 }
            if rec.mtime > entry.lastModified { entry.lastModified = rec.mtime }
            if entry.cwd == nil, let cwd = rec.cwd { entry.cwd = cwd }
            byProj[rec.project] = entry
        }
        return byProj.map { (name, v) in
            [
                "name": name,
                "cwd": opt(v.cwd),
                "count": v.count,
                "claudeCount": v.claudeCount,
                "antigravityCount": v.agyCount,
                "lastModified": v.lastModified,
            ]
        }.sorted { ($0["lastModified"] as! Double) > ($1["lastModified"] as! Double) }
    }

    static func listSessions(project: String, sourceFilter: String = "all") -> [[String: Any]] {
        collectAll(sourceFilter: sourceFilter)
            .filter { $0.project == project }
            .map { hydrateSessionSummary($0) }
            .sorted { ($0["mtime"] as! Double) > ($1["mtime"] as! Double) }
    }

    static func parseSession(source: String, id: String, includeSidechain: Bool) -> Any {
        if source == "claude" {
            guard let rec = collectClaudeSessions().first(where: { $0.id == id }) else {
                return ["error": "not found"]
            }
            return parseClaudeSession(file: rec.fileURL, includeSidechain: includeSidechain)
        }
        if source == "antigravity" {
            let agyById = collectAntigravitySessions()
            guard let rec = agyById[id] else { return ["error": "not found"] }
            let messages = NSMutableArray()
            var visited = Set<String>()
            parseAgyTranscriptInto(rec, agyById: agyById, includeSidechain: includeSidechain, outMessages: messages, visited: &visited)
            return messages
        }
        return ["error": "bad source"]
    }

    // ============================================================
    // MARK: - 全セッション横断検索
    // ============================================================

    struct SearchText {
        let kind: String
        let ts: String?
        let text: String
        let lower: String
    }

    private struct CacheEntry {
        let mtime: Double
        let texts: [SearchText]
        let bytes: Int
        var used: Int
    }

    private static var searchCache: [String: CacheEntry] = [:]
    private static var cacheClock = 0
    private static let searchCacheMaxBytes = 200 * 1024 * 1024
    private static let cacheLock = NSLock()

    private static func pruneSearchCache(seenPaths: Set<String>?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var total = 0
        for (path, entry) in searchCache {
            if let seen = seenPaths, !seen.contains(path) {
                searchCache.removeValue(forKey: path)
            } else {
                total += entry.bytes
            }
        }
        guard total > searchCacheMaxBytes else { return }
        for (path, entry) in searchCache.sorted(by: { $0.value.used < $1.value.used }) {
            searchCache.removeValue(forKey: path)
            total -= entry.bytes
            if total <= searchCacheMaxBytes { break }
        }
    }

    static func cacheStats() -> (entries: Int, bytes: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (searchCache.count, searchCache.values.reduce(0) { $0 + $1.bytes })
    }

    static func extractSearchTexts(_ rec: SessionRecord) -> [SearchText] {
        cacheLock.lock()
        if var cached = searchCache[rec.fileURL.path], cached.mtime == rec.mtime {
            cacheClock += 1
            cached.used = cacheClock
            searchCache[rec.fileURL.path] = cached
            cacheLock.unlock()
            return cached.texts
        }
        cacheLock.unlock()

        let texts: [SearchText] = autoreleasepool {
            var texts: [SearchText] = []
            guard let content = try? String(contentsOf: rec.fileURL, encoding: .utf8) else { return texts }
            if rec.source == "claude" {
                for line in content.split(separator: "\n") {
                    guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") else { continue }
                    guard let row = parseLine(line) else { continue }
                    if row["isSidechain"] as? Bool == true { continue }
                    let type = row["type"] as? String
                    let ts = row["timestamp"] as? String
                    let message = row["message"] as? [String: Any]
                    if type == "user", let c = message?["content"] as? String {
                        if claudeInjectedTag(c) == nil && !c.hasPrefix("[Request interrupted")
                            && !c.hasPrefix("<command-name>") && !c.hasPrefix("<local-command-") {
                            texts.append(SearchText(kind: "user", ts: ts, text: c, lower: c.lowercased()))
                        }
                    } else if type == "assistant", let blocks = message?["content"] as? [[String: Any]] {
                        for block in blocks where block["type"] as? String == "text" {
                            if let t = block["text"] as? String {
                                texts.append(SearchText(kind: "assistant", ts: ts, text: t, lower: t.lowercased()))
                            }
                        }
                    }
                }
            } else {
                for line in content.split(separator: "\n") {
                    guard line.contains("\"USER_INPUT\"") || line.contains("\"PLANNER_RESPONSE\"") else { continue }
                    guard let row = parseLine(line) else { continue }
                    let type = row["type"] as? String
                    let ts = row["created_at"] as? String
                    if type == "USER_INPUT", let raw = row["content"] as? String {
                        let t = parseAgyUserInput(raw).text
                        if !t.isEmpty {
                            texts.append(SearchText(kind: "user", ts: ts, text: t, lower: t.lowercased()))
                        }
                    } else if type == "PLANNER_RESPONSE", let t = row["content"] as? String,
                              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        texts.append(SearchText(kind: "assistant", ts: ts, text: t, lower: t.lowercased()))
                    }
                }
            }
            return texts
        }
        let bytes = texts.reduce(64) { $0 + ($1.text.utf16.count + $1.lower.utf16.count) * 2 + 48 }
        cacheLock.lock()
        cacheClock += 1
        searchCache[rec.fileURL.path] = CacheEntry(mtime: rec.mtime, texts: texts, bytes: bytes, used: cacheClock)
        cacheLock.unlock()
        return texts
    }

    static func makeSnippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        let core = text[start..<end]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + core + (end < text.endIndex ? "…" : "")
    }

    static func search(query: String, sourceFilter: String = "all") -> [String: Any] {
        let t0 = Date()
        let needle = query.lowercased()
        let topLevel = collectAll(sourceFilter: sourceFilter)
        var sessions: [[String: Any]] = []
        var seenPaths = Set<String>()

        for rec in topLevel {
            seenPaths.insert(rec.fileURL.path)
            var matches: [[String: Any]] = []
            for t in extractSearchTexts(rec) {
                guard let lowerRange = t.lower.range(of: needle) else { continue }
                let offset = t.lower.distance(from: t.lower.startIndex, to: lowerRange.lowerBound)
                let start = t.text.index(t.text.startIndex, offsetBy: min(offset, t.text.count),
                                         limitedBy: t.text.endIndex) ?? t.text.startIndex
                let end = t.text.index(start, offsetBy: needle.count, limitedBy: t.text.endIndex) ?? t.text.endIndex
                matches.append([
                    "kind": t.kind,
                    "ts": opt(t.ts),
                    "snippet": makeSnippet(t.text, around: start..<end),
                ])
                if matches.count >= 50 { break }
            }
            if matches.isEmpty, let title = rec.title {
                let lowerTitle = title.lowercased()
                if let lowerRange = lowerTitle.range(of: needle) {
                    let offset = lowerTitle.distance(from: lowerTitle.startIndex, to: lowerRange.lowerBound)
                    let start = title.index(title.startIndex, offsetBy: min(offset, title.count),
                                            limitedBy: title.endIndex) ?? title.startIndex
                    let end = title.index(start, offsetBy: needle.count, limitedBy: title.endIndex) ?? title.endIndex
                    matches.append([
                        "kind": "title",
                        "ts": NSNull(),
                        "snippet": makeSnippet(title, around: start..<end),
                    ])
                }
            }
            if !matches.isEmpty {
                let summary = hydrateSessionSummary(rec)
                let titleVal = (summary["title"] as? String) ?? (summary["firstPrompt"] as? String)
                sessions.append([
                    "source": rec.source,
                    "project": rec.project,
                    "id": rec.id,
                    "title": opt(titleVal),
                    "mtime": rec.mtime,
                    "cwd": opt(rec.cwd),
                    "count": matches.count,
                    "matches": Array(matches.prefix(3)),
                ])
            }
            if sessions.count >= 200 { break }
        }
        pruneSearchCache(seenPaths: (sessions.count >= 200 || sourceFilter != "all") ? nil : seenPaths)
        sessions.sort { ($0["mtime"] as! Double) > ($1["mtime"] as! Double) }
        return ["sessions": sessions, "tookMs": Int(Date().timeIntervalSince(t0) * 1000)]
    }

    // ============================================================
    // MARK: - お気に入り
    // ============================================================

    static let favoritesFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai-session-viewer/favorites.json")

    static func readFavorites() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: favoritesFile),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list
    }

    static func writeFavorites(_ list: [[String: Any]]) {
        let fm = FileManager.default
        let dir = favoritesFile.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? data.write(to: favoritesFile, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: favoritesFile.path)
        }
    }

    static func enrichedFavorites() -> [[String: Any]] {
        let topLevel = collectAll(sourceFilter: "all")
        var byKey: [String: SessionRecord] = [:]
        for r in topLevel { byKey["\(r.source)/\(r.id)"] = r }
        return readFavorites().map { fav in
            var f = fav
            let rawSrc = (f["source"] as? String) ?? "claude"
            let src = validSources.contains(rawSrc) ? rawSrc : "claude"
            f["source"] = src
            guard let id = f["id"] as? String, let rec = byKey["\(src)/\(id)"] else {
                f["missing"] = true
                return f
            }
            let summary = hydrateSessionSummary(rec)
            let titleVal = (summary["title"] as? String) ?? (summary["firstPrompt"] as? String)
            f["project"] = rec.project
            f["title"] = opt(titleVal)
            f["mtime"] = rec.mtime
            f["cwd"] = opt(rec.cwd)
            return f
        }
    }

    static func toggleFavorite(source: String, project: String, id: String, on: Bool) -> [[String: Any]] {
        var favs = readFavorites().filter {
            !(($0["source"] as? String ?? "claude") == source && $0["id"] as? String == id)
        }
        if on {
            favs.insert([
                "source": source,
                "project": project,
                "id": id,
                "addedAt": Date().timeIntervalSince1970 * 1000,
            ], at: 0)
        }
        writeFavorites(favs)
        return favs
    }

    // MARK: - 統計

    static func rssMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
    }

    // MARK: - APIディスパッチ

    private static let safeNameRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
    private static let validSources: Set<String> = ["claude", "antigravity"]
    private static let validFilters: Set<String> = ["all", "claude", "antigravity"]

    static func handle(path: String) -> Any {
        guard let components = URLComponents(string: path) else { return ["error": "bad path"] }
        let query = { (name: String) in components.queryItems?.first { $0.name == name }?.value ?? "" }
        let isSafe = { (s: String) -> Bool in
            guard !s.isEmpty, s != ".", s != "..", !s.contains("..") else { return false }
            let ns = s as NSString
            return safeNameRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }
        let rawFilter = query("source")
        let sourceFilter = validFilters.contains(rawFilter) ? rawFilter : "all"

        switch components.path {
        case "/api/stats":
            let stats = cacheStats()
            return [
                "cacheEntries": stats.entries,
                "cacheMB": stats.bytes / 1_048_576,
                "cacheLimitMB": searchCacheMaxBytes / 1_048_576,
                "rssMB": rssMB(),
            ]
        case "/api/projects":
            return listProjects(sourceFilter: sourceFilter)
        case "/api/sessions":
            let project = query("project")
            guard isSafe(project) else { return ["error": "bad project"] }
            return listSessions(project: project, sourceFilter: sourceFilter)
        case "/api/session":
            let source = query("source"), id = query("id")
            guard validSources.contains(source), isSafe(id) else { return ["error": "bad params"] }
            return parseSession(source: source, id: id, includeSidechain: query("sidechain") == "1")
        case "/api/favorites":
            return enrichedFavorites()
        case "/api/favorite":
            let source = query("source"), project = query("project"), id = query("id")
            guard validSources.contains(source), isSafe(project), isSafe(id) else { return ["error": "bad params"] }
            return toggleFavorite(source: source, project: project, id: id, on: query("on") == "1")
        case "/api/search":
            let q = query("q").trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { return ["error": "検索語は2文字以上"] }
            return search(query: q, sourceFilter: sourceFilter)
        default:
            return ["error": "unknown endpoint"]
        }
    }
}
