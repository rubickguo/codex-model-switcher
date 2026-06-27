import SwiftUI
import AppKit

enum CodexMode: String {
    case gpt
    case deepseek
    case unknown
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct HistoryMigrationState: Codable {
    var sessionProviders: [String: String] = [:]
    var threadProviders: [String: String] = [:]
}

struct InitialBackupManifest: Codable {
    var version: Int
    var createdAt: String
    var configExisted: Bool
    var configBackupPath: String?
    var threads: [ThreadInventoryBackup]
}

struct ThreadInventoryBackup: Codable {
    var dbPath: String
    var id: String
    var modelProvider: String
    var model: String?
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else {
            return [self]
        }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var mode: CodexMode = .unknown
    @Published var helperInstalled = false
    @Published var keyConfigured = false
    @Published var bridgeRunning = false
    @Published var apiKey = ""
    @Published var status = "准备就绪"
    @Published var detail = ""
    @Published var isBusy = false
    @Published var showDeepSeekSettings = false
    @Published var keyEditorSwitchesAfterSave = false

    private let home = ProcessInfo.processInfo.environment["MOCK_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path

    private var codexHome: String { "\(home)/.codex" }
    private var bridgeHome: String { "\(codexHome)/codex-deepseek-bridge" }
    private var appStateHome: String { "\(codexHome)/codex-model-switcher" }
    private var binDir: String { "\(bridgeHome)/bin" }
    private var configPath: String { "\(codexHome)/config.toml" }
    private var keyPath: String { "\(bridgeHome)/deepseek-key" }
    private var catalogPath: String { "\(bridgeHome)/models.json" }
    private var historyMigrationPath: String { "\(appStateHome)/history-migration.json" }
    private var initialBackupDir: String { "\(appStateHome)/initial-backup" }
    private var initialBackupManifestPath: String { "\(initialBackupDir)/manifest.json" }
    private var initialConfigBackupPath: String { "\(initialBackupDir)/config.toml" }
    private var helperPath: String {
        let arch = shellOutput("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(binDir)/\(arch == "x86_64" ? "codex-deepseek-bridge-macos-x64" : "codex-deepseek-bridge-macos")"
    }

    func refresh() {
        try? ensureInitialBackup()
        helperInstalled = FileManager.default.isExecutableFile(atPath: helperPath)
        keyConfigured = !readFileNormalized(atPath: keyPath).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        let config = readConfig()
        mode = detectedMode(from: config)

        bridgeRunning = false
        if helperInstalled {
            let result = runQuiet(helperPath, ["status"])
            bridgeRunning = result.status == 0 && result.stdout.contains("Bridge running")
        }

        if mode == .deepseek {
            status = bridgeRunning ? "DeepSeek 模式已启用" : "DeepSeek 模式已选择"
            detail = bridgeRunning ? "" : "桥接服务未运行"
        } else {
            status = "GPT 模式已启用"
            detail = ""
        }
    }

    func saveKey() {
        do {
            try saveEnteredKey(requireValue: true)
            let shouldSwitch = keyEditorSwitchesAfterSave
            showDeepSeekSettings = false
            keyEditorSwitchesAfterSave = false
            detail = "DeepSeek 密钥已保存"
            if shouldSwitch {
                switchToDeepSeek()
            }
        } catch {
            showDeepSeekSettings = true
            detail = error.localizedDescription
        }
    }

    func revealDeepSeekSettings(switchAfterSave: Bool = false) {
        showDeepSeekSettings = true
        keyEditorSwitchesAfterSave = switchAfterSave
        detail = ""
    }

    func cancelKeyEdit() {
        apiKey = ""
        showDeepSeekSettings = false
        keyEditorSwitchesAfterSave = false
        refresh()
    }

    func toggleMode() {
        switch mode {
        case .deepseek:
            switchToGPT()
        default:
            switchToDeepSeek()
        }
    }

    func switchToDeepSeek() {
        do {
            try saveEnteredKey(requireValue: false)
        } catch {
            showDeepSeekSettings = true
            keyEditorSwitchesAfterSave = true
            detail = error.localizedDescription
            return
        }

        guard keyConfigured || FileManager.default.fileExists(atPath: keyPath) else {
            showDeepSeekSettings = true
            keyEditorSwitchesAfterSave = true
            status = "需要 DeepSeek API 密钥"
            detail = ""
            return
        }

        runTask("正在切换到 DeepSeek") {
            try self.ensureInitialBackup()
            self.stopCodex()
            if !FileManager.default.isExecutableFile(atPath: self.helperPath) {
                try self.installHelper()
            }

            try self.writeDeepSeekModelCatalog()
            try self.applyDeepSeekProvider()
            try self.syncThreadInventoryForMode(.deepseek)
            try self.ensureBridgeRunningOnDefaultPort()
            self.restartCodex()
        }
    }

    func switchToGPT() {
        runTask("正在切换到 GPT") {
            try self.ensureInitialBackup()
            self.stopCodex()
            if FileManager.default.isExecutableFile(atPath: self.helperPath) {
                _ = self.runQuiet(self.helperPath, ["stop"])
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for p in ["\(home)/.codex/logs_2.sqlite", "\(home)/.codex/sqlite/logs_2.sqlite"] {
                try? FileManager.default.removeItem(atPath: p)
                try? FileManager.default.removeItem(atPath: "\(p)-wal")
                try? FileManager.default.removeItem(atPath: "\(p)-shm")
            }
            try self.applyUnifiedOfficialProvider()
            try self.syncThreadInventoryForMode(.gpt)
            self.restartCodex()
        }
    }

    private func runProviderGuard(mode: String) {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("provider-safe-guard.mjs"))
        }
        
        guard let scriptPath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return
        }
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let nodeCandidates = [
            "/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
            "\(homeDir)/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        
        let nodePath = nodeCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) ?? "node"
        
        if nodePath != "node" {
            _ = runQuiet(nodePath, [scriptPath, mode])
        } else {
            _ = runQuiet("/usr/bin/env", ["node", scriptPath, mode])
        }
    }

    private func detectedMode(from config: String) -> CodexMode {
        if config.contains("# >>> codex-deepseek-bridge-dummy") {
            return .gpt
        }
        if config.contains("# >>> codex-deepseek-bridge") ||
            config.contains("model_provider = \"deepseek_bridge\"") ||
            (config.contains("model_provider = \"custom\"") && config.contains("127.0.0.1:8787")) {
            return .deepseek
        }
        if config.contains("model =") {
            return .gpt
        }
        return .unknown
    }

    func resetAll() {
        runTask("正在重置个人配置") {
            try self.ensureInitialBackup()
            self.stopCodex()
            if FileManager.default.isExecutableFile(atPath: self.helperPath) {
                _ = self.runQuiet(self.helperPath, ["stop"])
            }
            try self.syncThreadInventoryForMode(.gpt)
            try self.restoreInitialConfig()
            try self.restoreInitialThreadInventory()
            self.restartCodex()
        }
    }

    private func runTask(_ label: String, work: @escaping () throws -> Void) {
        isBusy = true
        status = label
        detail = ""

        Task.detached {
            do {
                try work()
                await MainActor.run {
                    self.isBusy = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.refresh()
                    self.detail = error.localizedDescription
                }
            }
        }
    }

    private func saveEnteredKey(requireValue: Bool) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if requireValue {
                throw AppError.message("请先粘贴 DeepSeek API 密钥")
            }
            return
        }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw AppError.message("API 密钥里包含空格或不支持的字符")
        }

        try FileManager.default.createDirectory(atPath: bridgeHome, withIntermediateDirectories: true)
        try "\(trimmed)\n".write(toFile: keyPath, atomically: true, encoding: .utf8)
        chmod(keyPath, 0o600)
        apiKey = ""
        keyConfigured = true
    }

    private func ensureInitialBackup() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: initialBackupManifestPath) {
            return
        }

        try fm.createDirectory(atPath: initialBackupDir, withIntermediateDirectories: true)

        let configExisted = fm.fileExists(atPath: configPath)
        var configBackupPath: String? = nil
        if configExisted {
            var config = readConfig()
            if config.contains("# >>> codex-deepseek-bridge") || config.contains("# >>> codex-deepseek-bridge-dummy") {
                config = removingManagedConfigBlock(from: config)
            }
            try config.write(toFile: initialConfigBackupPath, atomically: true, encoding: .utf8)
            configBackupPath = initialConfigBackupPath
        }

        let manifest = InitialBackupManifest(
            version: 1,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            configExisted: configExisted,
            configBackupPath: configBackupPath,
            threads: try captureThreadInventory()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: URL(fileURLWithPath: initialBackupManifestPath), options: .atomic)
    }

    private func loadInitialBackupManifest() throws -> InitialBackupManifest {
        guard FileManager.default.fileExists(atPath: initialBackupManifestPath) else {
            throw AppError.message("没有找到初始备份，无法重置个人配置")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: initialBackupManifestPath))
        return try JSONDecoder().decode(InitialBackupManifest.self, from: data)
    }

    private func restoreInitialConfig() throws {
        let manifest = try loadInitialBackupManifest()
        if manifest.configExisted {
            guard let backupPath = manifest.configBackupPath,
                  FileManager.default.fileExists(atPath: backupPath) else {
                throw AppError.message("初始配置备份缺失，无法恢复 config.toml")
            }
            try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: configPath) {
                try FileManager.default.removeItem(atPath: configPath)
            }
            try FileManager.default.copyItem(atPath: backupPath, toPath: configPath)
        } else if FileManager.default.fileExists(atPath: configPath) {
            try FileManager.default.removeItem(atPath: configPath)
        }
    }

    private func captureThreadInventory() throws -> [ThreadInventoryBackup] {
        var backups: [ThreadInventoryBackup] = []
        for dbPath in stateDbPaths() where try hasThreadInventorySchema(dbPath) {
            let rows = try sqliteJSON(dbPath, "SELECT id, model_provider, model FROM threads;")
            for row in rows {
                guard let id = row["id"] as? String,
                      let provider = row["model_provider"] as? String else {
                    continue
                }
                backups.append(ThreadInventoryBackup(
                    dbPath: dbPath,
                    id: id,
                    modelProvider: provider,
                    model: row["model"] as? String
                ))
            }
        }
        return backups
    }

    private func restoreInitialThreadInventory() throws {
        let manifest = try loadInitialBackupManifest()
        guard !manifest.threads.isEmpty else {
            return
        }

        let grouped = Dictionary(grouping: manifest.threads, by: { $0.dbPath })
        for (dbPath, rows) in grouped {
            guard FileManager.default.fileExists(atPath: dbPath),
                  try hasThreadInventorySchema(dbPath) else {
                continue
            }
            var statements: [String] = ["BEGIN IMMEDIATE;"]
            for row in rows {
                statements.append(
                    "UPDATE threads SET model_provider = \(sqlQuote(row.modelProvider)), model = \(sqlNullableString(row.model)) WHERE id = \(sqlQuote(row.id));"
                )
            }
            statements.append("COMMIT;")
            statements.append("PRAGMA wal_checkpoint(TRUNCATE);")
            _ = try run("/usr/bin/sqlite3", [dbPath, statements.joined(separator: "\n")])
        }
    }

    private func syncThreadInventoryForMode(_ targetMode: CodexMode) throws {
        let provider: String
        let model: String
        switch targetMode {
        case .deepseek:
            provider = "custom"
            model = "deepseek-pro"
        case .gpt:
            provider = "openai"
            model = "gpt-5.5"
        case .unknown:
            return
        }

        for dbPath in stateDbPaths() where try hasThreadInventorySchema(dbPath) {
            let sql = [
                "PRAGMA wal_checkpoint(TRUNCATE);",
                "BEGIN IMMEDIATE;",
                "UPDATE threads SET model_provider = \(sqlQuote(provider)), model = \(sqlQuote(model));",
                "COMMIT;",
                "PRAGMA wal_checkpoint(TRUNCATE);"
            ].joined(separator: "\n")
            _ = try run("/usr/bin/sqlite3", [dbPath, sql])
        }
    }

    private func stateDbPaths() -> [String] {
        let fm = FileManager.default
        var candidates = [
            "\(codexHome)/state_5.sqlite",
            "\(codexHome)/sqlite/state_5.sqlite",
            "\(codexHome)/state/state_5.sqlite"
        ]

        for dir in [codexHome, "\(codexHome)/sqlite", "\(codexHome)/state"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for name in names where name.hasPrefix("state_") && name.hasSuffix(".sqlite") {
                candidates.append((dir as NSString).appendingPathComponent(name))
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { path in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard fm.fileExists(atPath: normalized), !seen.contains(normalized) else {
                return nil
            }
            seen.insert(normalized)
            return normalized
        }
    }

    private func hasThreadInventorySchema(_ dbPath: String) throws -> Bool {
        let rows = try sqliteJSON(dbPath, "PRAGMA table_info(threads);")
        let names = Set(rows.compactMap { $0["name"] as? String })
        return names.contains("model_provider") && names.contains("model")
    }

    private func writeDeepSeekModelCatalog() throws {
        try FileManager.default.createDirectory(atPath: bridgeHome, withIntermediateDirectories: true)
        let catalog: [String: Any] = [
            "models": [
                deepSeekCatalogModel(slug: "deepseek-pro", displayName: "DeepSeek Pro", priority: 1),
                deepSeekCatalogModel(slug: "deepseek-flash", displayName: "DeepSeek Flash", priority: 2)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: catalogPath), options: .atomic)
    }

    private func deepSeekCatalogModel(slug: String, displayName: String, priority: Int) -> [String: Any] {
        let efforts: [[String: String]] = [
            ["effort": "none", "description": "No thinking (fastest)"],
            ["effort": "high", "description": "DeepSeek thinking"],
            ["effort": "xhigh", "description": "DeepSeek maximum thinking"]
        ]
        let desktopEfforts: [[String: String]] = [
            ["reasoningEffort": "none", "description": "No thinking (fastest)"],
            ["reasoningEffort": "high", "description": "DeepSeek thinking"],
            ["reasoningEffort": "xhigh", "description": "DeepSeek maximum thinking"]
        ]
        let instructions = "You are Codex, a coding agent working in the user's local workspace. Help with software tasks end to end: inspect the project before changing it, use tools when useful, keep edits scoped, avoid reverting user changes, verify your work, and report the result clearly."
        let selfId = "Current model: DeepSeek \(displayName). Answer model-identity questions from this statement."
        let combinedBase = "\(selfId)\n\n\(instructions)"

        return [
            "model": slug,
            "slug": slug,
            "id": slug,
            "display_name": displayName,
            "displayName": displayName,
            "description": "\(displayName) via the local Codex DeepSeek Bridge.",
            "base_instructions": combinedBase,
            "default_reasoning_level": "xhigh",
            "supported_reasoning_levels": efforts,
            "default_reasoning_summary": "auto",
            "supports_reasoning_summaries": true,
            "defaultReasoningEffort": "xhigh",
            "supportedReasoningEfforts": desktopEfforts,
            "context_window": 1_000_000,
            "max_context_window": 1_000_000,
            "max_output_tokens": 384_000,
            "effective_context_window_percent": 95,
            "shell_type": "shell_command",
            "apply_patch_tool_type": "freeform",
            "web_search_tool_type": "text",
            "supports_parallel_tool_calls": true,
            "supports_search_tool": false,
            "supports_image_detail_original": false,
            "support_verbosity": false,
            "default_verbosity": "low",
            "truncation_policy": ["mode": "tokens", "limit": 20_000],
            "input_modalities": ["text"],
            "inputModalities": ["text"],
            "experimental_supported_tools": [],
            "additional_speed_tiers": [],
            "additionalSpeedTiers": [],
            "service_tiers": [],
            "serviceTiers": [],
            "defaultServiceTier": NSNull(),
            "availability_nux": NSNull(),
            "availabilityNux": NSNull(),
            "upgrade": NSNull(),
            "upgradeInfo": NSNull(),
            "model_messages": [
                "instructions_template": "{{ personality }}\n\n\(selfId)\n\n\(instructions)",
                "instructions_variables": [
                    "personality_default": "",
                    "personality_friendly": "",
                    "personality_pragmatic": ""
                ]
            ],
            "visibility": "list",
            "hidden": false,
            "isDefault": slug == "deepseek-pro",
            "supportsPersonality": false,
            "supported_in_api": true,
            "priority": priority
        ]
    }

    private func applyDeepSeekProvider() throws {
        let existing = readConfig()
        let cleaned = cleanedConfigForManagedProvider(existing)
        let block = [
            "# >>> codex-deepseek-bridge",
            "# Managed by Codex 模型切换器.",
            "model = \"deepseek-pro\"",
            "model_provider = \"custom\"",
            "model_catalog_json = \(tomlString(catalogPath))",
            "model_reasoning_effort = \"xhigh\"",
            "",
            "[model_providers.custom]",
            "name = \"DeepSeek (via Codex DeepSeek Bridge)\"",
            "base_url = \"http://127.0.0.1:8787/v1\"",
            "wire_api = \"responses\"",
            "supports_websockets = false",
            "requires_openai_auth = false",
            "# <<< codex-deepseek-bridge",
            ""
        ].joined(separator: "\n")
        try placeManagedBlockFirst(existing: cleaned, block: block)
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func applyUnifiedOfficialProvider() throws {
        let existing = readConfig()
        let cleaned = cleanedConfigForOpenAIProvider(existing)
        let block = [
            "# >>> codex-deepseek-bridge-dummy",
            "# Managed by Codex 模型切换器.",
            "model = \"gpt-5.5\"",
            "model_reasoning_effort = \"xhigh\"",
            "# <<< codex-deepseek-bridge-dummy",
            ""
        ].joined(separator: "\n")

        try placeManagedBlockFirst(existing: cleaned, block: block)
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func cleanedConfigForOpenAIProvider(_ text: String) -> String {
        var cleaned = removingManagedConfigBlock(from: text)
        cleaned = removingRootKeys(
            from: cleaned,
            keys: ["model", "model_provider", "model_catalog_json", "model_reasoning_effort", "openai_base_url"]
        )
        cleaned = removingProviderTable(from: cleaned, provider: "custom")
        cleaned = removingProviderTable(from: cleaned, provider: "deepseek_bridge")
        return cleaned
    }

    private func cleanedConfigForManagedProvider(_ text: String) -> String {
        var cleaned = removingManagedConfigBlock(from: text)
        cleaned = removingRootKeys(
            from: cleaned,
            keys: ["model", "model_provider", "model_catalog_json", "model_reasoning_effort", "openai_base_url"]
        )
        cleaned = removingProviderTable(from: cleaned, provider: "custom")
        cleaned = removingProviderTable(from: cleaned, provider: "deepseek_bridge")
        return cleaned
    }

    private func placeManagedBlockFirst(existing: String, block: String) -> String {
        let split = splitRootAndTables(existing)
        var output = ""
        let root = split.root.trimmingCharacters(in: .whitespacesAndNewlines)
        let tables = split.tables.trimmingCharacters(in: .whitespacesAndNewlines)
        if !root.isEmpty {
            output += "\(root)\n\n"
        }
        output += block.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tables.isEmpty {
            output += "\n\n\(tables)"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n")
    }

    private func splitRootAndTables(_ text: String) -> (root: String, tables: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let tableStart = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) else {
            return (text, "")
        }
        return (
            lines[..<tableStart].joined(separator: "\n"),
            lines[tableStart...].joined(separator: "\n")
        )
    }

    private func removingRootKeys(from text: String, keys: Set<String>) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inRoot = true
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inRoot = false
            }
            guard inRoot, let equals = trimmed.firstIndex(of: "=") else {
                return true
            }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            return !keys.contains(key)
        }
        return filtered.joined(separator: "\n")
    }

    private func removingProviderTable(from text: String, provider: String) -> String {
        let target = "model_providers.\(provider)"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let tableName = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .trimmingCharacters(in: .whitespaces)
                skipping = tableName == target || tableName.hasPrefix("\(target).")
                if skipping {
                    continue
                }
            }
            if !skipping {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private func readConfig() -> String {
        readFileNormalized(atPath: configPath)
    }

    private func readFileNormalized(atPath path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func removingManagedConfigBlock(from text: String) -> String {
        var updated = text
        if let start = updated.range(of: "# >>> codex-deepseek-bridge"),
           let end = updated.range(of: "# <<< codex-deepseek-bridge"),
           end.lowerBound > start.lowerBound {
            updated.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = updated.range(of: "# >>> codex-deepseek-bridge-dummy"),
           let end = updated.range(of: "# <<< codex-deepseek-bridge-dummy"),
           end.lowerBound > start.lowerBound {
            updated.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = updated.range(of: "# >>> codex-deepseek-dummy"),
           let end = updated.range(of: "# <<< codex-deepseek-dummy"),
           end.lowerBound > start.lowerBound {
            updated.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return updated.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n")
    }

    private func tomlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func ensureBridgeRunningOnDefaultPort() throws {
        let status = runQuiet(helperPath, ["status"])
        if status.status == 0 && status.stdout.contains(":8787") {
            return
        }
        _ = runQuiet(helperPath, ["stop"])
        _ = try run(helperPath, ["start", "--port", "8787"])
    }

    private func stripUnifiedOfficialProvider() throws {
        let lines = readConfig()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var output: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "model_provider = \"custom\"" {
                index += 1
                continue
            }

            if trimmed == "[model_providers.custom]" {
                var section: [String] = [lines[index]]
                var next = index + 1
                while next < lines.count {
                    let nextTrimmed = lines[next].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("[") && nextTrimmed.hasSuffix("]") {
                        break
                    }
                    section.append(lines[next])
                    next += 1
                }

                let sectionText = section.joined(separator: "\n")
                let isManagedOfficialProvider =
                    sectionText.contains("name = \"OpenAI\"") &&
                    sectionText.contains("requires_openai_auth = true") &&
                    sectionText.contains("wire_api = \"responses\"")

                if isManagedOfficialProvider {
                    index = next
                    continue
                }
            }

            output.append(lines[index])
            index += 1
        }

        try output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func migrateCodexHistoryToSharedProvider() throws {
        let sourceProviders: Set<String> = ["openai", "deepseek_bridge"]
        guard try hasLegacyThreadRows(sourceProviders: sourceProviders) else {
            return
        }

        var state = loadHistoryMigrationState()
        let backupRoot = "\(appStateHome)/backups/unified-history-\(timestampForPath())"
        var didBackupJson = false

        let historyDirs = ["\(codexHome)/sessions", "\(codexHome)/archived_sessions"]
        for dir in historyDirs {
            guard let enumerator = FileManager.default.enumerator(atPath: dir) else {
                continue
            }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else {
                    continue
                }
                let path = "\(dir)/\(relativePath)"
                let original = readFileNormalized(atPath: path)
                let (updated, changed, sessionProviders) = rewriteSessionMetaProviders(
                    in: original,
                    sourceProviders: sourceProviders,
                    targetProvider: "custom"
                )
                guard changed else {
                    continue
                }
                if !didBackupJson {
                    try FileManager.default.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
                    didBackupJson = true
                }
                let backupPath = "\(backupRoot)/jsonl/\((dir as NSString).lastPathComponent)/\(relativePath)"
                try copyFileCreatingParents(from: path, to: backupPath)
                for (id, provider) in sessionProviders where state.sessionProviders[id] == nil {
                    state.sessionProviders[id] = provider
                }
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        try migrateThreadRowsToSharedProvider(state: &state, backupRoot: backupRoot, sourceProviders: sourceProviders)
        try saveHistoryMigrationState(state)
    }

    private func migrateHistoryToOpenAIProvider() throws {
        let dbPath = "\(codexHome)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        let count = try sqliteCount(dbPath, "SELECT count(*) FROM threads WHERE model_provider = 'custom'")
        guard count > 0 else { return }
        let backupRoot = "\(appStateHome)/backups/gpt-restore-\(timestampForPath())"
        try FileManager.default.createDirectory(atPath: "\(backupRoot)/state", withIntermediateDirectories: true)
        _ = try run("/usr/bin/sqlite3", [dbPath, ".backup \(sqlQuote("\(backupRoot)/state/state_5.sqlite"))"])
        _ = try run("/usr/bin/sqlite3", [dbPath, "PRAGMA wal_checkpoint(TRUNCATE); BEGIN IMMEDIATE; UPDATE threads SET model_provider = 'openai' WHERE model_provider = 'custom'; COMMIT;"])
    }

    private func sqliteCount(_ dbPath: String, _ sql: String) throws -> Int {
        let result = try run("/usr/bin/sqlite3", [dbPath, sql])
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func hasLegacyThreadRows(sourceProviders: Set<String>) throws -> Bool {
        let dbPath = "\(codexHome)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }
        let providerList = sourceProviders.map(sqlQuote).joined(separator: ",")
        let rows = try sqliteJSON(dbPath, "SELECT id FROM threads WHERE model_provider IN (\(providerList)) LIMIT 1;")
        return !rows.isEmpty
    }

    private func restoreMigratedCodexHistory() throws {
        let state = loadHistoryMigrationState()
        guard !state.sessionProviders.isEmpty || !state.threadProviders.isEmpty else {
            return
        }

        let backupRoot = "\(appStateHome)/backups/restore-history-\(timestampForPath())"
        var didBackupJson = false
        let historyDirs = ["\(codexHome)/sessions", "\(codexHome)/archived_sessions"]
        for dir in historyDirs {
            guard let enumerator = FileManager.default.enumerator(atPath: dir) else {
                continue
            }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else {
                    continue
                }
                let path = "\(dir)/\(relativePath)"
                let original = readFileNormalized(atPath: path)
                let (updated, changed) = restoreSessionMetaProviders(in: original, providersBySessionId: state.sessionProviders)
                guard changed else {
                    continue
                }
                if !didBackupJson {
                    try FileManager.default.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
                    didBackupJson = true
                }
                let backupPath = "\(backupRoot)/jsonl/\((dir as NSString).lastPathComponent)/\(relativePath)"
                try copyFileCreatingParents(from: path, to: backupPath)
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }

        try restoreThreadRows(state: state, backupRoot: backupRoot)
        try? FileManager.default.removeItem(atPath: historyMigrationPath)
    }

    private func rewriteSessionMetaProviders(in text: String, sourceProviders: Set<String>, targetProvider: String) -> (String, Bool, [String: String]) {
        var changed = false
        var sessionProviders: [String: String] = [:]
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rewritten = lines.map { line -> String in
            guard line.contains("\"session_meta\""), line.contains("\"model_provider\""),
                  let data = line.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  var payload = object["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String,
                  let provider = payload["model_provider"] as? String,
                  sourceProviders.contains(provider) else {
                return line
            }

            payload["model_provider"] = targetProvider
            object["payload"] = payload
            guard let outputData = try? JSONSerialization.data(withJSONObject: object),
                  let outputLine = String(data: outputData, encoding: .utf8) else {
                return line
            }
            changed = true
            sessionProviders[sessionId] = provider
            return outputLine
        }
        var output = rewritten.joined(separator: "\n")
        if hadTrailingNewline && !output.hasSuffix("\n") {
            output.append("\n")
        }
        return (output, changed, sessionProviders)
    }

    private func restoreSessionMetaProviders(in text: String, providersBySessionId: [String: String]) -> (String, Bool) {
        var changed = false
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rewritten = lines.map { line -> String in
            guard line.contains("\"session_meta\""), line.contains("\"model_provider\""),
                  let data = line.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  var payload = object["payload"] as? [String: Any],
                  let sessionId = payload["id"] as? String,
                  payload["model_provider"] as? String == "custom",
                  let originalProvider = providersBySessionId[sessionId] else {
                return line
            }

            payload["model_provider"] = originalProvider
            object["payload"] = payload
            guard let outputData = try? JSONSerialization.data(withJSONObject: object),
                  let outputLine = String(data: outputData, encoding: .utf8) else {
                return line
            }
            changed = true
            return outputLine
        }
        var output = rewritten.joined(separator: "\n")
        if hadTrailingNewline && !output.hasSuffix("\n") {
            output.append("\n")
        }
        return (output, changed)
    }

    private func migrateThreadRowsToSharedProvider(state: inout HistoryMigrationState, backupRoot: String, sourceProviders: Set<String>) throws {
        let dbPath = "\(codexHome)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return
        }

        let rows = try sqliteJSON(dbPath, "SELECT id, model_provider FROM threads WHERE model_provider IN ('openai','deepseek_bridge');")
        guard !rows.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: "\(backupRoot)/state", withIntermediateDirectories: true)
        _ = try run("/usr/bin/sqlite3", [dbPath, ".backup \(sqlQuote("\(backupRoot)/state/state_5.sqlite"))"])
        for row in rows {
            guard let id = row["id"] as? String,
                  let provider = row["model_provider"] as? String,
                  sourceProviders.contains(provider),
                  state.threadProviders[id] == nil else {
                continue
            }
            state.threadProviders[id] = provider
        }
        _ = try run("/usr/bin/sqlite3", [dbPath, "UPDATE threads SET model_provider = 'custom' WHERE model_provider IN ('openai','deepseek_bridge');"])
        _ = try run("/usr/bin/sqlite3", [dbPath, "PRAGMA wal_checkpoint(TRUNCATE)"])
    }

    private func restoreThreadRows(state: HistoryMigrationState, backupRoot: String) throws {
        let dbPath = "\(codexHome)/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath), !state.threadProviders.isEmpty else {
            return
        }
        try FileManager.default.createDirectory(atPath: "\(backupRoot)/state", withIntermediateDirectories: true)
        _ = try run("/usr/bin/sqlite3", [dbPath, ".backup \(sqlQuote("\(backupRoot)/state/state_5.sqlite"))"])

        let grouped = Dictionary(grouping: state.threadProviders.keys) { id in
            state.threadProviders[id] ?? "openai"
        }
        for (provider, ids) in grouped {
            for chunk in ids.chunked(into: 300) {
                let idList = chunk.map(sqlQuote).joined(separator: ",")
                let sql = "UPDATE threads SET model_provider = \(sqlQuote(provider)) WHERE model_provider = 'custom' AND id IN (\(idList));"
                _ = try run("/usr/bin/sqlite3", [dbPath, sql])
            }
        }
    }

    private func sqliteJSON(_ dbPath: String, _ sql: String) throws -> [[String: Any]] {
        let result = try run("/usr/bin/sqlite3", ["-json", dbPath, sql])
        let data = Data(result.stdout.utf8)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    private func loadHistoryMigrationState() -> HistoryMigrationState {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: historyMigrationPath)),
              let state = try? JSONDecoder().decode(HistoryMigrationState.self, from: data) else {
            return HistoryMigrationState()
        }
        return state
    }

    private func saveHistoryMigrationState(_ state: HistoryMigrationState) throws {
        try FileManager.default.createDirectory(atPath: appStateHome, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: historyMigrationPath), options: .atomic)
    }

    private func copyFileCreatingParents(from source: String, to destination: String) throws {
        let parent = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    private func timestampForPath() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func sqlNullableString(_ value: String?) -> String {
        guard let value else {
            return "NULL"
        }
        return sqlQuote(value)
    }

    private func installHelper() throws {
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let arch = shellOutput("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = arch == "x86_64" ? "codex-deepseek-bridge-macos-x64" : "codex-deepseek-bridge-macos"
        let base = "https://github.com/JetXu-LLM/codex-deepseek-bridge/releases/latest/download"
        let binary = "\(binDir)/\(asset)"
        let checksum = "\(binary).sha256"

        _ = try run("/usr/bin/curl", ["-fL", "-o", binary, "\(base)/\(asset)"])
        _ = try run("/usr/bin/curl", ["-fL", "-o", checksum, "\(base)/\(asset).sha256"])
        let expected = ((try? String(contentsOfFile: checksum, encoding: .utf8)) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let actual = shellOutput("/usr/bin/shasum", ["-a", "256", binary]).split(separator: " ").first.map(String.init) ?? ""
        guard !expected.isEmpty && expected == actual else {
            throw AppError.message("下载的桥接工具校验失败")
        }
        _ = runQuiet("/usr/bin/xattr", ["-d", "com.apple.quarantine", binary])
        chmod(binary, 0o755)
    }

    private func removeManagedConfigBlock() throws {
        let config = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let updated = removingManagedConfigBlock(from: config)
        guard updated != config else { return }
        try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func restartCodex() {
        _ = runQuiet("/usr/bin/open", ["-a", "Codex"])
    }

    private func stopCodex() {
        _ = runQuiet("/usr/bin/osascript", ["-e", "tell application \"Codex\" to quit"])
        Thread.sleep(forTimeInterval: 2.0)
    }

    private func cleanStaleEncryptedErrors() {
        let statePath = "\(codexHome)/.codex-global-state.json"
        guard FileManager.default.fileExists(atPath: statePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let text = String(data: data, encoding: .utf8),
              text.contains("dscb") else {
            return
        }
        _ = text.replacingOccurrences(
            of: "dscb...4ifQ could not be verified. Reason: Encrypted content could not be decrypted or parsed",
            with: ""
        )
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let result = runCommand(launchPath, arguments)
        if result.status != 0 {
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AppError.message(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "操作失败" : text)
        }
        return result
    }

    private func runQuiet(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        runCommand(launchPath, arguments)
    }

    private func shellOutput(_ launchPath: String, _ arguments: [String]) -> String {
        runCommand(launchPath, arguments).stdout
    }

    private func runCommand(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var currentEnv = ProcessInfo.processInfo.environment
        let additionalPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = currentEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var pathComponents = existingPath.split(separator: ":").map(String.init)
        for addPath in additionalPaths {
            if !pathComponents.contains(addPath) {
                pathComponents.append(addPath)
            }
        }
        currentEnv["PATH"] = pathComponents.joined(separator: ":")
        process.environment = currentEnv

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
struct ModeSwitch: View {
    let mode: CodexMode
    let busy: Bool
    let action: () -> Void

    var isDeepSeek: Bool { mode == .deepseek }
    private let selectedColor = Color(red: 0.13, green: 0.24, blue: 0.55)
    private let deepSeekColor = Color(red: 0.0, green: 0.42, blue: 0.34)

    var body: some View {
        Button(action: action) {
            GeometryReader { geometry in
                let inset: CGFloat = 6
                let segmentWidth = (geometry.size.width - inset * 2) / 2

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.94, green: 0.97, blue: 1.0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )

                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
                        .frame(width: segmentWidth, height: 44)
                        .offset(x: inset + (isDeepSeek ? segmentWidth : 0), y: 0)

                    HStack(spacing: 0) {
                        modeLabel(
                            title: "GPT",
                            systemImage: "sparkles",
                            selected: !isDeepSeek,
                            color: selectedColor
                        )
                        .frame(width: segmentWidth, height: 44)

                        modeLabel(
                            title: "DeepSeek",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            selected: isDeepSeek,
                            color: deepSeekColor
                        )
                        .frame(width: segmentWidth, height: 44)
                    }
                    .padding(.horizontal, inset)

                    if busy {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.72))
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isDeepSeek)
            }
            .frame(height: 56)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func modeLabel(title: String, systemImage: String, selected: Bool, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(selected ? color : Color.secondary)
        .opacity(selected ? 1 : 0.72)
    }
}

struct ContentView: View {
    @StateObject private var model = SwitcherModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 模型切换器")
                        .font(.system(size: 24, weight: .semibold))
                    Text(model.status)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新状态")
            }

            ModeSwitch(mode: model.mode, busy: model.isBusy) {
                model.toggleMode()
            }

            if model.showDeepSeekSettings {
                keyEditor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(24)
        .frame(width: 540, height: windowHeight)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.99, blue: 1.0),
                    Color(red: 0.95, green: 0.98, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            model.refresh()
        }
        .animation(.easeInOut(duration: 0.18), value: model.showDeepSeekSettings)
        .animation(.easeInOut(duration: 0.18), value: model.mode)
    }

    private var windowHeight: CGFloat {
        var height: CGFloat = 318
        if model.showDeepSeekSettings {
            height += 76
        }
        return height
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .font(.system(size: 13, weight: .semibold))
                Text("DeepSeek API 密钥")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.keyConfigured ? "已保存" : "未设置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                SecureField(model.keyConfigured ? "输入新密钥以替换当前密钥" : "输入 DeepSeek API 密钥", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)

                Button(model.keyEditorSwitchesAfterSave ? "保存并切换" : "保存") {
                    model.saveKey()
                }
                .disabled(model.isBusy || model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("取消") {
                    model.cancelKeyEdit()
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.07), lineWidth: 1))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button {
                    model.revealDeepSeekSettings()
                } label: {
                    Text(model.keyConfigured ? "编辑 DeepSeek 密钥" : "添加 DeepSeek 密钥")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isBusy)

                Spacer()

                Button(role: .destructive) {
                    model.resetAll()
                } label: {
                    Text("重置个人配置")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.70, green: 0.18, blue: 0.14))
                .disabled(model.isBusy)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}

@main
struct CodexModelSwitcherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
