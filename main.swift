import Cocoa

// MARK: - Log Manager
class LogManager {
    static var logs: [String] = []
    
    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        print(formatted)
        logs.append(formatted)
        if logs.count > 100 {
            logs.removeFirst()
        }
    }
}

// MARK: - Models
struct BackupFileInfo {
    let name: String
    let path: String
    let date: Date
    let size: Int64
}

// MARK: - Custom Card View
class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

// MARK: - Custom Status Badge
class CustomBadge: NSView {
    var text: String = "" {
        didSet {
            textLabel.stringValue = text
            updateColors()
        }
    }
    
    var isOn: Bool = false {
        didSet {
            updateColors()
        }
    }
    
    private let textLabel = NSTextField(labelWithString: "")
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 4
        
        textLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        textLabel.alignment = .center
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
    
    private func updateColors() {
        if isOn {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            textLabel.textColor = NSColor.systemGreen
        } else {
            layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
            textLabel.textColor = NSColor.systemGray
        }
    }
}

// MARK: - Backup Row Item View
class BackupRowView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    let restoreButton = NSButton()
    
    var onRestore: (() -> Void)?
    
    init(name: String, dateStr: String, sizeStr: String, onRestore: @escaping () -> Void) {
        super.init(frame: .zero)
        self.onRestore = onRestore
        
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = NSColor.labelColor
        nameLabel.stringValue = name
        
        dateLabel.font = NSFont.systemFont(ofSize: 9)
        dateLabel.textColor = NSColor.secondaryLabelColor
        dateLabel.stringValue = dateStr
        
        let textStack = NSStackView(views: [nameLabel, dateLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        
        sizeLabel.font = NSFont.systemFont(ofSize: 10)
        sizeLabel.textColor = NSColor.secondaryLabelColor
        sizeLabel.stringValue = sizeStr
        sizeLabel.alignment = .right
        
        restoreButton.title = "还原"
        restoreButton.bezelStyle = .rounded
        restoreButton.font = NSFont.systemFont(ofSize: 10)
        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked)
        
        let mainStack = NSStackView(views: [textStack, sizeLabel, restoreButton])
        mainStack.orientation = .horizontal
        mainStack.spacing = 8
        mainStack.alignment = .centerY
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            
            textStack.widthAnchor.constraint(equalToConstant: 180),
            sizeLabel.widthAnchor.constraint(equalToConstant: 60),
            restoreButton.widthAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
    
    @objc private func restoreClicked() {
        onRestore?()
    }
}

// MARK: - Config & Process Manager
class ConfigManager {
    static let shared = ConfigManager()
    
    let home = NSHomeDirectory()
    var codexHome: String { return "\(home)/.codex" }
    var configToml: String { return "\(codexHome)/config.toml" }
    var bridgeHome: String { return "\(codexHome)/codex-deepseek-bridge" }
    var bridgeBin: String { return "\(bridgeHome)/bin/codex-deepseek-bridge-macos" }
    var bridgeKeyFile: String { return "\(bridgeHome)/deepseek-key" }
    var sessionsDir: String { return "\(codexHome)/sessions" }
    var archivedSessionsDir: String { return "\(codexHome)/archived_sessions" }
    
    // Check active model provider
    func getActiveConfig() -> (model: String, provider: String) {
        guard FileManager.default.fileExists(atPath: configToml) else { return ("unknown", "openai") }
        var activeModel = "unknown"
        var activeProvider = "openai"
        do {
            let content = try String(contentsOfFile: configToml, encoding: .utf8)
            let lines = content.split(separator: "\n")
            var inSection = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    inSection = true
                    continue
                }
                if !inSection {
                    let parts = trimmed.split(separator: "=")
                    if parts.count >= 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        var val = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
                        if val.hasPrefix("\"") && val.hasSuffix("\"") {
                            val = String(val.dropFirst().dropLast())
                        }
                        if key == "model" { activeModel = val }
                        if key == "model_provider" { activeProvider = val }
                    }
                }
            }
        } catch {
            print("Failed to read config: \(error)")
        }
        return (activeModel, activeProvider)
    }
    
    // Read saved API key
    func getSavedApiKey() -> String {
        guard FileManager.default.fileExists(atPath: bridgeKeyFile) else { return "" }
        do {
            return try String(contentsOfFile: bridgeKeyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
    
    // Save API key
    func saveApiKey(_ key: String) {
        let dir = (bridgeKeyFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? key.write(toFile: bridgeKeyFile, atomically: true, encoding: .utf8)
    }
    
    // Shell execute helper
    @discardableResult
    func runCommand(launchPath: String, arguments: [String], env: [String: String]? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        
        var currentEnv = ProcessInfo.processInfo.environment
        if let env = env {
            for (k, v) in env {
                currentEnv[k] = v
            }
        }
        
        // Append typical search paths to PATH if they are not already there
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
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // Helper to find node binary in common paths
    func findNodePath() -> String {
        let fm = FileManager.default
        let homeDir = NSHomeDirectory()
        
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
            "\(homeDir)/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        
        for path in candidates {
            if fm.fileExists(atPath: path) {
                LogManager.log("找到 Node 路径: \(path)")
                return path
            }
        }
        
        LogManager.log("未找到预设 Node 路径，将尝试从环境变量中查找 node")
        return "node"
    }
    
    // Force quit Codex application
    func quitCodex() {
        let appleScript = NSAppleScript(source: "tell application \"Codex\" to quit")
        appleScript?.executeAndReturnError(nil)
        
        Thread.sleep(forTimeInterval: 1.5)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", "/Applications/Codex.app"]
        try? process.run()
        process.waitUntilExit()
    }
    
    // Open Codex application
    func launchCodex() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Codex"]
        try? process.run()
    }
    
    // Check if Codex is running
    func isCodexRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "application \"Codex\" is running"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        return false
    }
    
    // Get total session count
    func getSessionsCount() -> Int {
        let fm = FileManager.default
        var count = 0
        if fm.fileExists(atPath: sessionsDir) {
            if let files = try? fm.contentsOfDirectory(atPath: sessionsDir) {
                count += files.filter { !$0.hasPrefix(".") }.count
            }
        }
        if fm.fileExists(atPath: archivedSessionsDir) {
            if let files = try? fm.contentsOfDirectory(atPath: archivedSessionsDir) {
                count += files.filter { !$0.hasPrefix(".") }.count
            }
        }
        return count
    }
    
    // Get backups list
    func getBackups() -> [BackupFileInfo] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexHome) else { return [] }
        do {
            let files = try fm.contentsOfDirectory(atPath: codexHome)
            var backups: [BackupFileInfo] = []
            for file in files {
                if file.hasPrefix("config.toml.") && file.hasSuffix(".bak") {
                    let fullPath = "\(codexHome)/\(file)"
                    let attrs = try fm.attributesOfItem(atPath: fullPath)
                    let date = attrs[.modificationDate] as? Date ?? Date()
                    let size = attrs[.size] as? Int64 ?? 0
                    backups.append(BackupFileInfo(name: file, path: fullPath, date: date, size: size))
                }
            }
            return backups.sorted(by: { $0.date > $1.date })
        } catch {
            print("Error getting backups: \(error)")
            return []
        }
    }
    
    // Read bridge logs
    func readBridgeLogs() -> String {
        let stdoutPath = "\(bridgeHome)/bridge.stdout.log"
        let stderrPath = "\(bridgeHome)/bridge.stderr.log"
        
        var outputLines: [String] = []
        
        // Read stdout
        if FileManager.default.fileExists(atPath: stdoutPath) {
            if let content = try? String(contentsOfFile: stdoutPath, encoding: .utf8) {
                let lines = content.split(separator: "\n").suffix(25).map { "[Bridge] \($0)" }
                outputLines.append("--- Bridge stdout ---")
                outputLines.append(contentsOf: lines)
            }
        }
        // Read stderr
        if FileManager.default.fileExists(atPath: stderrPath) {
            if let content = try? String(contentsOfFile: stderrPath, encoding: .utf8) {
                let lines = content.split(separator: "\n").suffix(25).map { "[Bridge Error] \($0)" }
                outputLines.append("--- Bridge stderr ---")
                outputLines.append(contentsOf: lines)
            }
        }
        
        let allLogs = LogManager.logs + outputLines
        return allLogs.suffix(60).joined(separator: "\n")
    }
    
    // Query bridge online and get active configuration
    func getBridgeStatus(completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: "http://localhost:8787/report/data") else {
            completion(false, nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(false, nil)
                return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                completion(false, nil)
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let config = json["config"] as? [String: Any],
               let upstream = config["upstreamModel"] as? String {
                completion(true, upstream)
            } else {
                completion(true, "unknown")
            }
        }
        task.resume()
    }
    
    // Switch to DeepSeek Bridge
    func enableDeepSeekMode(
        apiKey: String,
        provider: String,
        baseUrl: String,
        modelPro: String,
        modelFlash: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: bridgeBin) else {
            completion(false, "找不到网桥二进制程序，请先安装 bridge。")
            return
        }
        
        saveApiKey(apiKey)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            LogManager.log("正在切换至 DeepSeek 模式 (服务商: \(provider))...")
            self.quitCodex()
            
            // Stop any running bridge daemon
            self.runCommand(launchPath: self.bridgeBin, arguments: ["stop"])
            
            // Run setup configuration
            let setupResult = self.runCommand(launchPath: self.bridgeBin, arguments: ["setup", "--yes", "--no-start"], env: ["DEEPSEEK_API_KEY": apiKey])
            LogManager.log("Setup output: \(setupResult.trimmingCharacters(in: .whitespacesAndNewlines))")
            
            // Resolve variables based on provider preset
            var resolvedBaseUrl = "https://api.deepseek.com"
            var resolvedModelPro = "deepseek-reasoner"
            var resolvedModelFlash = "deepseek-chat"
            
            if provider == "siliconflow" {
                resolvedBaseUrl = "https://api.siliconflow.cn/v1"
                resolvedModelPro = modelPro.isEmpty ? "deepseek-ai/DeepSeek-R1" : modelPro
                resolvedModelFlash = modelFlash.isEmpty ? "deepseek-ai/DeepSeek-V3" : modelFlash
            } else if provider == "custom" {
                resolvedBaseUrl = baseUrl.isEmpty ? "https://api.deepseek.com" : baseUrl
                resolvedModelPro = modelPro.isEmpty ? "deepseek-reasoner" : modelPro
                resolvedModelFlash = modelFlash.isEmpty ? "deepseek-chat" : modelFlash
            } else {
                resolvedModelPro = modelPro.isEmpty ? "deepseek-reasoner" : modelPro
                resolvedModelFlash = modelFlash.isEmpty ? "deepseek-chat" : modelFlash
            }
            
            LogManager.log("正在以指定参数启动网桥: url=\(resolvedBaseUrl), pro=\(resolvedModelPro), flash=\(resolvedModelFlash)")
            
            // Start the bridge daemon with environments
            let startEnv = [
                "DEEPSEEK_API_KEY": apiKey,
                "DEEPSEEK_BASE_URL": resolvedBaseUrl,
                "DEEPSEEK_MODEL_PRO": resolvedModelPro,
                "DEEPSEEK_MODEL_FLASH": resolvedModelFlash
            ]
            
            let startResult = self.runCommand(launchPath: self.bridgeBin, arguments: ["start"], env: startEnv)
            LogManager.log("Start output: \(startResult.trimmingCharacters(in: .whitespacesAndNewlines))")
            
            // Keep historical sessions on their original provider. Provider-specific
            // encrypted reasoning state is not portable between DeepSeek and GPT.
            self.runProviderGuard(mode: "deepseek")
            
            self.launchCodex()
            
            DispatchQueue.main.async {
                completion(true, "成功切换至 DeepSeek 模式")
            }
        }
    }
    
    // Clean a specific block by header tag
    func cleanConfigToml(tag: String) -> Bool {
        guard FileManager.default.fileExists(atPath: configToml) else { return true }
        do {
            let content = try String(contentsOfFile: configToml, encoding: .utf8)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var newLines: [String] = []
            var insideBlock = false
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(">>> \(tag)") {
                    insideBlock = true
                    continue
                }
                if trimmed.contains("<<< \(tag)") {
                    insideBlock = false
                    continue
                }
                if insideBlock {
                    continue
                }
                newLines.append(String(line))
            }
            
            let newContent = newLines.joined(separator: "\n")
            try newContent.write(toFile: configToml, atomically: true, encoding: .utf8)
            return true
        } catch {
            LogManager.log("清除 config.toml 标记块 \(tag) 失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // Clean bridge configurations from config.toml manually
    func cleanConfigTomlOfBridgeSettings() -> Bool {
        _ = cleanConfigToml(tag: "codex-deepseek-bridge-dummy")
        let result = cleanConfigToml(tag: "codex-deepseek-bridge")
        if result {
            LogManager.log("成功清除 config.toml 中的网桥配置及 dummy 标记块。")
        }
        return result
    }
    
    // Prepare provider-safe session copies without mutating the original history.
    func runProviderGuard(mode: String) {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append((resourcePath as NSString).appendingPathComponent("provider-safe-guard.mjs"))
        }
        candidates.append("\(home)/codexswitch/scripts/provider-safe-guard.mjs")
        
        guard let scriptPath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            LogManager.log("Provider 保护脚本未找到，跳过会话副本准备。")
            return
        }
        
        let nodePath = findNodePath()
        let result: String
        if nodePath == "node" {
            result = runCommand(launchPath: "/usr/bin/env", arguments: ["node", scriptPath, mode])
        } else {
            result = runCommand(launchPath: nodePath, arguments: [scriptPath, mode])
        }
        
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            LogManager.log("Provider 保护完成。")
        } else {
            LogManager.log(trimmed)
        }
    }
    
    // Legacy no-op: older builds rewrote rollout files in-place, which made the
    // same thread move between providers and broke encrypted reasoning checks.
    func sanitizeSessions(from: String, to: String) {
        LogManager.log("安全模式：跳过历史会话 provider 改写（\(from) -> \(to)）。")
    }
    
    private func readFirstChunk(ofPath path: String, length: Int) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { file.closeFile() }
        let data = file.readData(ofLength: length)
        return String(data: data, encoding: .utf8)
    }
    
    // Switch back to GPT Official (Restore Config)
    func disableDeepSeekMode(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            LogManager.log("正在恢复官方 OpenAI (GPT) 模式...")
            self.quitCodex()
            
            var restored = false
            
            // 1. Try restoring via bridge CLI
            if FileManager.default.fileExists(atPath: self.bridgeBin) {
                LogManager.log("正在通过网桥命令行恢复配置...")
                let restoreRes = self.runCommand(launchPath: self.bridgeBin, arguments: ["restore"])
                let trimmedRes = restoreRes.trimmingCharacters(in: .whitespacesAndNewlines)
                LogManager.log("Restore output: \(trimmedRes)")
                if !trimmedRes.isEmpty && !trimmedRes.contains("Error") && !trimmedRes.contains("failed") {
                    restored = true
                }
            }
            
            // 2. If CLI restore failed or wasn't available, perform manual fallback restore from backups
            if !restored {
                LogManager.log("网桥恢复未成功或未执行，尝试手动从备份文件还原...")
                let backups = self.getBackups()
                if let latestBackup = backups.first {
                    do {
                        if FileManager.default.fileExists(atPath: self.configToml) {
                            try FileManager.default.removeItem(atPath: self.configToml)
                        }
                        try FileManager.default.copyItem(atPath: latestBackup.path, toPath: self.configToml)
                        LogManager.log("已成功手动从备份还原: \(latestBackup.name)")
                        restored = true
                    } catch {
                        LogManager.log("手动备份还原失败: \(error.localizedDescription)")
                    }
                }
            }
            
            // 3. Final fallback: if no backup was restored, just clean the active settings
            if !restored {
                LogManager.log("未找到任何备份，直接清理现有 config.toml 中的网桥配置...")
                _ = self.cleanConfigTomlOfBridgeSettings()
            } else {
                // If restored, clean any dummy block to make sure it is not duplicated
                _ = self.cleanConfigToml(tag: "codex-deepseek-bridge-dummy")
            }
            
            // Append dummy block to define custom provider so Codex doesn't crash on startup due to legacy custom sessions
            let dummyBlock = """
            
            # >>> codex-deepseek-bridge-dummy
            [model_providers.custom]
            name = "DeepSeek (Bridge Inactive)"
            base_url = "http://127.0.0.1:8787/v1"
            wire_api = "responses"
            supports_websockets = false
            requires_openai_auth = false
            # <<< codex-deepseek-bridge-dummy
            """
            
            if let fileHandle = FileHandle(forWritingAtPath: self.configToml) {
                fileHandle.seekToEndOfFile()
                if let data = dummyBlock.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
            
            // Prepare GPT-safe copies for DeepSeek sessions that contain dscb
            // encrypted reasoning blocks. Originals are left intact.
            self.runProviderGuard(mode: "gpt")
            
            if FileManager.default.fileExists(atPath: self.bridgeBin) {
                // Stop bridge daemon
                let stopRes = self.runCommand(launchPath: self.bridgeBin, arguments: ["stop"])
                LogManager.log("Stop output: \(stopRes.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            
            self.launchCodex()
            
            DispatchQueue.main.async {
                completion(true, "成功还原官方 GPT 模式")
            }
        }
    }
    
    // Restore specific backup file
    func restoreBackup(atPath backupPath: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            LogManager.log("正在从备份还原: \(URL(fileURLWithPath: backupPath).lastPathComponent)...")
            self.quitCodex()
            
            if FileManager.default.fileExists(atPath: self.bridgeBin) {
                self.runCommand(launchPath: self.bridgeBin, arguments: ["stop"])
            }
            
            do {
                if FileManager.default.fileExists(atPath: self.configToml) {
                    try FileManager.default.removeItem(atPath: self.configToml)
                }
                try FileManager.default.copyItem(atPath: backupPath, toPath: self.configToml)
                LogManager.log("备份还原成功: \(URL(fileURLWithPath: backupPath).lastPathComponent)")
                
                self.launchCodex()
                DispatchQueue.main.async {
                    completion(true, "成功还原备份文件")
                }
            } catch {
                LogManager.log("备份还原失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(false, "还原失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // Restart Codex application
    func restartCodex(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            LogManager.log("正在重新启动 Codex 客户端...")
            self.quitCodex()
            self.launchCodex()
            LogManager.log("Codex 客户端重启成功")
            DispatchQueue.main.async {
                completion(true)
            }
        }
    }
}

// MARK: - View Controller
class SwitcherViewController: NSViewController, NSTextFieldDelegate {
    
    // LEFT COLUMN: Header, System Status, Backups list
    private let titleLabel = NSTextField(labelWithString: "Codex Switcher")
    private let subtitleLabel = NSTextField(labelWithString: "一键无损切换 OpenAI 官方与 DeepSeek 后端")
    
    // Loading overlay / Spinner
    private let activityIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    
    // System Status views
    private let statusCard = CardView()
    private let codexStatusBadge = CustomBadge()
    private let bridgeStatusBadge = CustomBadge()
    private let activeModelLabel = NSTextField(labelWithString: "检测中...")
    private let sessionsLabel = NSTextField(labelWithString: "检测中...")
    private let btnRestartCodex = NSButton()
    
    // Backups views
    private let backupsCard = CardView()
    private let backupsScrollView = NSScrollView()
    private let backupsStackView = NSStackView()
    
    // RIGHT COLUMN: Mode selector, config card views, logs card views
    private let modeSegmented = NSSegmentedControl(labels: ["官方 OpenAI 模式", "DeepSeek 桥接配置"], trackingMode: .selectOne, target: nil, action: nil)
    
    // Configuration Container
    private let configCard = CardView()
    private let gptConfigView = NSStackView()
    private let deepseekConfigView = NSStackView()
    
    // GPT config subviews
    private let btnApplyGpt = NSButton()
    
    // DeepSeek config subviews
    private let providerPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseUrlField = NSTextField()
    private let secureKeyField = NSSecureTextField()
    private let plainKeyField = NSTextField()
    private let toggleKeyButton = NSButton()
    
    private let modelProPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelProCustomField = NSTextField()
    private let modelFlashPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelFlashCustomField = NSTextField()
    
    private let btnApplyDeepseek = NSButton()
    
    // Conditional form row stack containers (for hiding/showing)
    private var baseUrlRow = NSStackView()
    private var proCustomRow = NSStackView()
    private var flashCustomRow = NSStackView()
    
    // Logs views
    private let logsCard = CardView()
    private let logTextView = NSTextView()
    private let logsScrollView = NSScrollView()
    private let btnClearLogs = NSButton()
    private let btnRefreshLogs = NSButton()
    
    // Background polling timer
    private var statusTimer: Timer?
    
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 680))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupEvents()
        
        LogManager.log("Codex Switcher 启动成功。")
        
        loadCurrentState()
        
        startStatusTimer()
    }
    
    deinit {
        statusTimer?.invalidate()
    }
    
    private func setupLayout() {
        // Build Left Column (Width: 360)
        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.spacing = 12
        leftColumn.alignment = .leading
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.widthAnchor.constraint(equalToConstant: 360).isActive = true
        
        // 1. Header
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        
        let headerTextStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 2
        
        activityIndicator.style = .spinning
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.controlSize = .small
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        activityIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        
        loadingLabel.font = NSFont.systemFont(ofSize: 10)
        loadingLabel.textColor = NSColor.secondaryLabelColor
        loadingLabel.stringValue = ""
        
        let loadingStack = NSStackView(views: [activityIndicator, loadingLabel])
        loadingStack.orientation = .horizontal
        loadingStack.spacing = 6
        loadingStack.alignment = .centerY
        
        let headerRow = NSStackView(views: [headerTextStack, loadingStack])
        headerRow.orientation = .horizontal
        headerRow.spacing = 16
        headerRow.alignment = .centerY
        
        leftColumn.addArrangedSubview(headerRow)
        
        // 2. System Status Card
        setupStatusCard()
        leftColumn.addArrangedSubview(statusCard)
        
        // 3. Backups Card
        setupBackupsCard()
        leftColumn.addArrangedSubview(backupsCard)
        
        // Build Right Column (Width: 512)
        let rightColumn = NSStackView()
        rightColumn.orientation = .vertical
        rightColumn.spacing = 12
        rightColumn.alignment = .centerX
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        rightColumn.widthAnchor.constraint(equalToConstant: 512).isActive = true
        
        // 1. Mode Segmented Selector
        modeSegmented.segmentStyle = .texturedSquare
        modeSegmented.selectedSegment = 0
        modeSegmented.translatesAutoresizingMaskIntoConstraints = false
        modeSegmented.heightAnchor.constraint(equalToConstant: 28).isActive = true
        modeSegmented.widthAnchor.constraint(equalToConstant: 320).isActive = true
        rightColumn.addArrangedSubview(modeSegmented)
        
        // 2. Config Card Container
        setupConfigCard()
        rightColumn.addArrangedSubview(configCard)
        
        // 3. Console Logs Card
        setupLogsCard()
        rightColumn.addArrangedSubview(logsCard)
        
        // Combine into Main Stack
        let mainStack = NSStackView(views: [leftColumn, rightColumn])
        mainStack.orientation = .horizontal
        mainStack.spacing = 16
        mainStack.alignment = .top
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            statusCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            backupsCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            configCard.widthAnchor.constraint(equalTo: rightColumn.widthAnchor),
            logsCard.widthAnchor.constraint(equalTo: rightColumn.widthAnchor)
        ])
    }
    
    private func setupStatusCard() {
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        
        let headerLabel = NSTextField(labelWithString: "系统状态")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        headerLabel.textColor = NSColor.labelColor
        
        // Status Row Badges / Values
        codexStatusBadge.text = "检测中..."
        bridgeStatusBadge.text = "检测中..."
        
        let row1 = createStatusRow(label: "Codex 客户端", view: codexStatusBadge)
        let row2 = createStatusRow(label: "DeepSeek 桥接服务", view: bridgeStatusBadge)
        
        activeModelLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        activeModelLabel.textColor = NSColor.labelColor
        activeModelLabel.lineBreakMode = .byTruncatingTail
        let row3 = createStatusRow(label: "当前生效模型", view: activeModelLabel)
        
        sessionsLabel.font = NSFont.systemFont(ofSize: 11)
        sessionsLabel.textColor = NSColor.secondaryLabelColor
        let row4 = createStatusRow(label: "历史会话数据", view: sessionsLabel)
        
        btnRestartCodex.title = "重启 Codex 客户端"
        btnRestartCodex.bezelStyle = .rounded
        btnRestartCodex.font = NSFont.systemFont(ofSize: 11)
        btnRestartCodex.target = self
        btnRestartCodex.action = #selector(handleRestartCodex)
        
        // Alignment Stack
        let infoStack = NSStackView(views: [row1, row2, row3, row4])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        
        let contentStack = NSStackView(views: [
            headerLabel,
            infoStack,
            btnRestartCodex
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        
        statusCard.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),
            
            infoStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24)
        ])
    }
    
    private func createStatusRow(label: String, view: NSView) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 11)
        lbl.textColor = NSColor.secondaryLabelColor
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 120).isActive = true
        
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let row = NSStackView(views: [lbl, view])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
    
    private func createFormRow(label: String, view: NSView) -> NSStackView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = NSColor.labelColor
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 120).isActive = true
        
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let row = NSStackView(views: [lbl, view])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
    
    private func setupBackupsCard() {
        backupsCard.translatesAutoresizingMaskIntoConstraints = false
        
        let headerLabel = NSTextField(labelWithString: "备份历史 (可随时还原)")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        headerLabel.textColor = NSColor.labelColor
        
        let descLabel = NSTextField(labelWithString: "修改配置前会自动保存原有的配置文件，点击还原即可退回。")
        descLabel.font = NSFont.systemFont(ofSize: 10)
        descLabel.textColor = NSColor.secondaryLabelColor
        descLabel.cell?.wraps = true
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.widthAnchor.constraint(equalToConstant: 336).isActive = true
        
        backupsScrollView.borderType = .noBorder
        backupsScrollView.drawsBackground = false
        backupsScrollView.hasVerticalScroller = true
        backupsScrollView.translatesAutoresizingMaskIntoConstraints = false
        backupsScrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true
        
        backupsStackView.orientation = .vertical
        backupsStackView.spacing = 6
        backupsStackView.alignment = .leading
        backupsStackView.translatesAutoresizingMaskIntoConstraints = false
        
        backupsScrollView.documentView = backupsStackView
        
        let contentStack = NSStackView(views: [
            headerLabel,
            descLabel,
            backupsScrollView
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        
        backupsCard.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: backupsCard.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: backupsCard.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: backupsCard.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: backupsCard.bottomAnchor),
            
            backupsScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            backupsStackView.leadingAnchor.constraint(equalTo: backupsScrollView.contentView.leadingAnchor),
            backupsStackView.trailingAnchor.constraint(equalTo: backupsScrollView.contentView.trailingAnchor),
            backupsStackView.topAnchor.constraint(equalTo: backupsScrollView.contentView.topAnchor),
            backupsStackView.widthAnchor.constraint(equalTo: backupsScrollView.contentView.widthAnchor)
        ])
    }
    
    private func setupConfigCard() {
        configCard.translatesAutoresizingMaskIntoConstraints = false
        configCard.heightAnchor.constraint(equalToConstant: 330).isActive = true
        
        // 1. GPT Config Panel
        let gptHeaderLabel = NSTextField(labelWithString: "Codex 官方 OpenAI 模式")
        gptHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        gptHeaderLabel.textColor = NSColor.labelColor
        
        let gptDesc = NSTextField(labelWithString: "使用 OpenAI 官方通道，直接连接官方服务端。\n您的历史 ChatGPT 登录状态将立即生效，且聊天记录完全保留。")
        gptDesc.font = NSFont.systemFont(ofSize: 11)
        gptDesc.textColor = NSColor.secondaryLabelColor
        gptDesc.cell?.wraps = true
        gptDesc.translatesAutoresizingMaskIntoConstraints = false
        gptDesc.widthAnchor.constraint(equalToConstant: 488).isActive = true
        
        btnApplyGpt.title = "启用官方 OpenAI 模式"
        btnApplyGpt.bezelStyle = .rounded
        btnApplyGpt.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btnApplyGpt.target = self
        btnApplyGpt.action = #selector(handleApplyGpt)
        btnApplyGpt.translatesAutoresizingMaskIntoConstraints = false
        btnApplyGpt.widthAnchor.constraint(equalToConstant: 200).isActive = true
        btnApplyGpt.heightAnchor.constraint(equalToConstant: 32).isActive = true
        
        gptConfigView.orientation = .vertical
        gptConfigView.alignment = .leading
        gptConfigView.spacing = 16
        gptConfigView.translatesAutoresizingMaskIntoConstraints = false
        gptConfigView.addArrangedSubview(gptHeaderLabel)
        gptConfigView.addArrangedSubview(gptDesc)
        gptConfigView.addArrangedSubview(btnApplyGpt)
        
        // 2. DeepSeek Config Panel
        let dsHeaderLabel = NSTextField(labelWithString: "DeepSeek 桥接配置")
        dsHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        dsHeaderLabel.textColor = NSColor.labelColor
        
        // Provider Select PopUp
        providerPopUp.addItems(withTitles: [
            "DeepSeek 官方 API (api.deepseek.com)",
            "硅基流动 SiliconFlow (性价比高，免翻墙)",
            "自定义 OpenAI 兼容端 (第三方中转/自建)"
        ])
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged(_:))
        providerPopUp.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let providerRow = createFormRow(label: "API 服务商预设", view: providerPopUp)
        
        // Base URL Row
        baseUrlField.placeholderString = "https://api.deepseek.com"
        baseUrlField.bezelStyle = .roundedBezel
        baseUrlField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        baseUrlRow = createFormRow(label: "API Base URL", view: baseUrlField)
        baseUrlRow.isHidden = true
        
        // API Key Field with toggle
        let keyFieldContainer = NSView()
        keyFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        keyFieldContainer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        keyFieldContainer.widthAnchor.constraint(equalToConstant: 320).isActive = true
        
        secureKeyField.bezelStyle = .roundedBezel
        secureKeyField.translatesAutoresizingMaskIntoConstraints = false
        secureKeyField.delegate = self
        
        plainKeyField.bezelStyle = .roundedBezel
        plainKeyField.translatesAutoresizingMaskIntoConstraints = false
        plainKeyField.isHidden = true
        plainKeyField.delegate = self
        
        toggleKeyButton.title = "👁️"
        toggleKeyButton.bezelStyle = .rounded
        toggleKeyButton.font = NSFont.systemFont(ofSize: 11)
        toggleKeyButton.target = self
        toggleKeyButton.action = #selector(toggleKeyVisibility)
        toggleKeyButton.translatesAutoresizingMaskIntoConstraints = false
        toggleKeyButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        
        keyFieldContainer.addSubview(secureKeyField)
        keyFieldContainer.addSubview(plainKeyField)
        keyFieldContainer.addSubview(toggleKeyButton)
        
        NSLayoutConstraint.activate([
            secureKeyField.leadingAnchor.constraint(equalTo: keyFieldContainer.leadingAnchor),
            secureKeyField.topAnchor.constraint(equalTo: keyFieldContainer.topAnchor),
            secureKeyField.bottomAnchor.constraint(equalTo: keyFieldContainer.bottomAnchor),
            secureKeyField.trailingAnchor.constraint(equalTo: toggleKeyButton.leadingAnchor, constant: -6),
            
            plainKeyField.leadingAnchor.constraint(equalTo: keyFieldContainer.leadingAnchor),
            plainKeyField.topAnchor.constraint(equalTo: keyFieldContainer.topAnchor),
            plainKeyField.bottomAnchor.constraint(equalTo: keyFieldContainer.bottomAnchor),
            plainKeyField.trailingAnchor.constraint(equalTo: toggleKeyButton.leadingAnchor, constant: -6),
            
            toggleKeyButton.trailingAnchor.constraint(equalTo: keyFieldContainer.trailingAnchor),
            toggleKeyButton.centerYAnchor.constraint(equalTo: keyFieldContainer.centerYAnchor)
        ])
        
        let apiKeyRow = createFormRow(label: "API Key", view: keyFieldContainer)
        
        // Pro Model
        modelProPopUp.addItems(withTitles: [
            "deepseek-reasoner",
            "deepseek-chat",
            "deepseek-ai/DeepSeek-R1",
            "deepseek-ai/DeepSeek-V3",
            "-- 自定义模型名称 --"
        ])
        modelProPopUp.target = self
        modelProPopUp.action = #selector(modelProChanged(_:))
        modelProPopUp.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let proRow = createFormRow(label: "主力编码 (Pro)", view: modelProPopUp)
        
        modelProCustomField.placeholderString = "例如: deepseek-reasoner"
        modelProCustomField.bezelStyle = .roundedBezel
        modelProCustomField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        proCustomRow = createFormRow(label: "自定义 Pro", view: modelProCustomField)
        proCustomRow.isHidden = true
        
        // Flash Model
        modelFlashPopUp.addItems(withTitles: [
            "deepseek-chat",
            "deepseek-reasoner",
            "deepseek-ai/DeepSeek-V3",
            "deepseek-ai/DeepSeek-R1",
            "-- 自定义模型名称 --"
        ])
        modelFlashPopUp.target = self
        modelFlashPopUp.action = #selector(modelFlashChanged(_:))
        modelFlashPopUp.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let flashRow = createFormRow(label: "快速诊断 (Flash)", view: modelFlashPopUp)
        
        modelFlashCustomField.placeholderString = "例如: deepseek-chat"
        modelFlashCustomField.bezelStyle = .roundedBezel
        modelFlashCustomField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        flashCustomRow = createFormRow(label: "自定义 Flash", view: modelFlashCustomField)
        flashCustomRow.isHidden = true
        
        // Apply button
        btnApplyDeepseek.title = "保存配置并应用"
        btnApplyDeepseek.bezelStyle = .rounded
        btnApplyDeepseek.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btnApplyDeepseek.target = self
        btnApplyDeepseek.action = #selector(handleApplyDeepseek)
        btnApplyDeepseek.translatesAutoresizingMaskIntoConstraints = false
        btnApplyDeepseek.widthAnchor.constraint(equalToConstant: 160).isActive = true
        btnApplyDeepseek.heightAnchor.constraint(equalToConstant: 28).isActive = true
        
        let buttonAlignStack = NSStackView(views: [btnApplyDeepseek])
        buttonAlignStack.orientation = .horizontal
        buttonAlignStack.edgeInsets = NSEdgeInsets(top: 0, left: 128, bottom: 0, right: 0)
        buttonAlignStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Form Stack
        let dsFormStack = NSStackView(views: [
            providerRow,
            baseUrlRow,
            apiKeyRow,
            proRow,
            proCustomRow,
            flashRow,
            flashCustomRow,
            buttonAlignStack
        ])
        dsFormStack.orientation = .vertical
        dsFormStack.alignment = .leading
        dsFormStack.spacing = 8
        dsFormStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Wrap form in Scroll View
        let dsScrollView = NSScrollView()
        dsScrollView.borderType = .noBorder
        dsScrollView.drawsBackground = false
        dsScrollView.hasVerticalScroller = true
        dsScrollView.translatesAutoresizingMaskIntoConstraints = false
        dsScrollView.documentView = dsFormStack
        
        deepseekConfigView.orientation = .vertical
        deepseekConfigView.alignment = .leading
        deepseekConfigView.spacing = 10
        deepseekConfigView.translatesAutoresizingMaskIntoConstraints = false
        deepseekConfigView.addArrangedSubview(dsHeaderLabel)
        deepseekConfigView.addArrangedSubview(dsScrollView)
        
        NSLayoutConstraint.activate([
            dsScrollView.leadingAnchor.constraint(equalTo: deepseekConfigView.leadingAnchor),
            dsScrollView.trailingAnchor.constraint(equalTo: deepseekConfigView.trailingAnchor),
            dsScrollView.topAnchor.constraint(equalTo: dsHeaderLabel.bottomAnchor, constant: 6),
            dsScrollView.bottomAnchor.constraint(equalTo: deepseekConfigView.bottomAnchor),
            
            dsFormStack.leadingAnchor.constraint(equalTo: dsScrollView.contentView.leadingAnchor),
            dsFormStack.trailingAnchor.constraint(equalTo: dsScrollView.contentView.trailingAnchor),
            dsFormStack.topAnchor.constraint(equalTo: dsScrollView.contentView.topAnchor),
            dsFormStack.widthAnchor.constraint(equalTo: dsScrollView.contentView.widthAnchor)
        ])
        
        configCard.addSubview(gptConfigView)
        configCard.addSubview(deepseekConfigView)
        
        NSLayoutConstraint.activate([
            gptConfigView.leadingAnchor.constraint(equalTo: configCard.leadingAnchor, constant: 12),
            gptConfigView.trailingAnchor.constraint(equalTo: configCard.trailingAnchor, constant: -12),
            gptConfigView.topAnchor.constraint(equalTo: configCard.topAnchor, constant: 12),
            gptConfigView.bottomAnchor.constraint(equalTo: configCard.bottomAnchor, constant: -12),
            
            deepseekConfigView.leadingAnchor.constraint(equalTo: configCard.leadingAnchor, constant: 12),
            deepseekConfigView.trailingAnchor.constraint(equalTo: configCard.trailingAnchor, constant: -12),
            deepseekConfigView.topAnchor.constraint(equalTo: configCard.topAnchor, constant: 12),
            deepseekConfigView.bottomAnchor.constraint(equalTo: configCard.bottomAnchor, constant: -12)
        ])
        
        gptConfigView.isHidden = false
        deepseekConfigView.isHidden = true
    }
    
    private func setupLogsCard() {
        logsCard.translatesAutoresizingMaskIntoConstraints = false
        logsCard.heightAnchor.constraint(equalToConstant: 220).isActive = true
        
        let headerLabel = NSTextField(labelWithString: "控制台日志")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        headerLabel.textColor = NSColor.labelColor
        
        btnRefreshLogs.title = "🔄 刷新"
        btnRefreshLogs.bezelStyle = .rounded
        btnRefreshLogs.font = NSFont.systemFont(ofSize: 10)
        btnRefreshLogs.target = self
        btnRefreshLogs.action = #selector(handleRefreshLogs)
        btnRefreshLogs.translatesAutoresizingMaskIntoConstraints = false
        btnRefreshLogs.widthAnchor.constraint(equalToConstant: 60).isActive = true
        
        btnClearLogs.title = "🧹 清空"
        btnClearLogs.bezelStyle = .rounded
        btnClearLogs.font = NSFont.systemFont(ofSize: 10)
        btnClearLogs.target = self
        btnClearLogs.action = #selector(handleClearLogs)
        btnClearLogs.translatesAutoresizingMaskIntoConstraints = false
        btnClearLogs.widthAnchor.constraint(equalToConstant: 60).isActive = true
        
        let headerStack = NSStackView(views: [headerLabel, btnRefreshLogs, btnClearLogs])
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        
        logsScrollView.borderType = .noBorder
        logsScrollView.hasVerticalScroller = true
        logsScrollView.hasHorizontalScroller = false
        logsScrollView.translatesAutoresizingMaskIntoConstraints = false
        
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = NSColor.labelColor
        logTextView.backgroundColor = NSColor.textBackgroundColor
        logTextView.autoresizingMask = [.width]
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = true
        
        logsScrollView.documentView = logTextView
        
        let contentStack = NSStackView(views: [
            headerStack,
            logsScrollView
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        
        logsCard.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: logsCard.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: logsCard.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: logsCard.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: logsCard.bottomAnchor),
            
            headerStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            logsScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            logsScrollView.heightAnchor.constraint(equalToConstant: 160)
        ])
    }
    
    private func setupEvents() {
        modeSegmented.target = self
        modeSegmented.action = #selector(modeSegmentChanged(_:))
    }
    
    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(statusTimer!, forMode: .common)
    }
    
    private func loadCurrentState() {
        let config = ConfigManager.shared.getActiveConfig()
        let isDeepSeek = (config.provider == "deepseek_bridge")
        
        modeSegmented.selectedSegment = isDeepSeek ? 1 : 0
        gptConfigView.isHidden = isDeepSeek
        deepseekConfigView.isHidden = !isDeepSeek
        
        let savedKey = ConfigManager.shared.getSavedApiKey()
        secureKeyField.stringValue = savedKey
        plainKeyField.stringValue = savedKey
        
        refreshStatus()
    }
    
    private func refreshStatus() {
        let isRunning = ConfigManager.shared.isCodexRunning()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.codexStatusBadge.text = isRunning ? "运行中" : "已停止"
            self.codexStatusBadge.isOn = isRunning
        }
        
        ConfigManager.shared.getBridgeStatus { [weak self] (isBridgeRunning, upstreamModel) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.bridgeStatusBadge.text = isBridgeRunning ? "运行中 (8787)" : "已停止"
                self.bridgeStatusBadge.isOn = isBridgeRunning
                
                let config = ConfigManager.shared.getActiveConfig()
                if config.provider == "deepseek_bridge" {
                    let upstream = upstreamModel ?? "deepseek-pro"
                    self.activeModelLabel.stringValue = "DeepSeek (\(upstream))"
                } else {
                    self.activeModelLabel.stringValue = "官方 (\(config.model))"
                }
            }
        }
        
        let sessionCount = ConfigManager.shared.getSessionsCount()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionsLabel.stringValue = "\(sessionCount) 聊天 (100% 安全)"
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateLogsDisplay()
        }
        
        refreshBackupsList()
    }
    
    private func refreshBackupsList() {
        let backups = ConfigManager.shared.getBackups()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.backupsStackView.subviews.forEach { $0.removeFromSuperview() }
            
            if backups.isEmpty {
                let lbl = NSTextField(labelWithString: "暂无备份文件")
                lbl.font = NSFont.systemFont(ofSize: 11)
                lbl.textColor = NSColor.secondaryLabelColor
                self.backupsStackView.addArrangedSubview(lbl)
                return
            }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            
            for backup in backups {
                let dateStr = dateFormatter.string(from: backup.date)
                let sizeStr = String(format: "%.2f KB", Double(backup.size) / 1024.0)
                
                var desc = backup.name
                if backup.name.contains("pre-restore") {
                    desc = "还原前自动备份"
                } else if backup.name.contains("setup") || backup.name.contains("pre-patch") {
                    desc = "设置前自动备份"
                } else {
                    desc = "系统备份"
                }
                
                let row = BackupRowView(name: desc, dateStr: dateStr, sizeStr: sizeStr) { [weak self] in
                    self?.confirmAndRestoreBackup(backup)
                }
                row.translatesAutoresizingMaskIntoConstraints = false
                self.backupsStackView.addArrangedSubview(row)
                
                row.widthAnchor.constraint(equalTo: self.backupsStackView.widthAnchor).isActive = true
            }
        }
    }
    
    private func confirmAndRestoreBackup(_ backup: BackupFileInfo) {
        let alert = NSAlert()
        alert.messageText = "确认还原此备份吗？"
        alert.informativeText = "此操作会覆盖当前的 config.toml，关闭 DeepSeek 桥接服务并重启 Codex。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定还原")
        alert.addButton(withTitle: "取消")
        
        alert.beginSheetModal(for: self.view.window!) { [weak self] response in
            guard let self = self else { return }
            if response == .alertFirstButtonReturn {
                self.setUILocked(true, message: "正在还原备份...")
                ConfigManager.shared.restoreBackup(atPath: backup.path) { [weak self] (success, message) in
                    guard let self = self else { return }
                    self.setUILocked(false)
                    if success {
                        self.loadCurrentState()
                        let infoAlert = NSAlert()
                        infoAlert.messageText = "还原成功"
                        infoAlert.informativeText = "配置文件已还原，Codex 客户端已重启。"
                        infoAlert.runModal()
                    } else {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "还原失败"
                        errorAlert.informativeText = message
                        errorAlert.alertStyle = .critical
                        errorAlert.runModal()
                    }
                }
            }
        }
    }
    
    @objc private func handleApplyGpt() {
        setUILocked(true, message: "正在启用官方模式...")
        ConfigManager.shared.disableDeepSeekMode { [weak self] (success, message) in
            guard let self = self else { return }
            self.setUILocked(false)
            if success {
                self.loadCurrentState()
                let alert = NSAlert()
                alert.messageText = "启用官方模式成功"
                alert.informativeText = "Codex 官方 OpenAI 模式启用成功，Codex 客户端已重新启动。"
                alert.runModal()
            } else {
                let alert = NSAlert()
                alert.messageText = "切换官方模式失败"
                alert.informativeText = message
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }
    
    @objc private func handleApplyDeepseek() {
        let key = secureKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let alert = NSAlert()
            alert.messageText = "请输入 API Key"
            alert.informativeText = "启用 DeepSeek 模式前，必须配置 API Key。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        
        let providerIndex = providerPopUp.indexOfSelectedItem
        var provider = "official"
        if providerIndex == 1 { provider = "siliconflow" }
        else if providerIndex == 2 { provider = "custom" }
        
        let baseUrl = baseUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var modelPro = ""
        if modelProPopUp.indexOfSelectedItem == 4 {
            modelPro = modelProCustomField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            modelPro = modelProPopUp.titleOfSelectedItem ?? ""
        }
        
        var modelFlash = ""
        if modelFlashPopUp.indexOfSelectedItem == 4 {
            modelFlash = modelFlashCustomField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            modelFlash = modelFlashPopUp.titleOfSelectedItem ?? ""
        }
        
        setUILocked(true, message: "正在应用 DeepSeek 桥接配置...")
        ConfigManager.shared.enableDeepSeekMode(
            apiKey: key,
            provider: provider,
            baseUrl: baseUrl,
            modelPro: modelPro,
            modelFlash: modelFlash
        ) { [weak self] (success, message) in
            guard let self = self else { return }
            self.setUILocked(false)
            if success {
                self.loadCurrentState()
                let alert = NSAlert()
                alert.messageText = "配置应用成功"
                alert.informativeText = "成功切换至 DeepSeek 模式，Codex 客户端已重新启动。"
                alert.runModal()
            } else {
                let alert = NSAlert()
                alert.messageText = "配置应用失败"
                alert.informativeText = message
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }
    
    @objc private func handleRestartCodex() {
        setUILocked(true, message: "正在重启 Codex...")
        ConfigManager.shared.restartCodex { [weak self] _ in
            self?.setUILocked(false)
            self?.refreshStatus()
        }
    }
    
    private func setUILocked(_ locked: Bool, message: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.providerPopUp.isEnabled = !locked
            self.baseUrlField.isEnabled = !locked
            self.secureKeyField.isEnabled = !locked
            self.plainKeyField.isEnabled = !locked
            self.toggleKeyButton.isEnabled = !locked
            self.modelProPopUp.isEnabled = !locked
            self.modelProCustomField.isEnabled = !locked
            self.modelFlashPopUp.isEnabled = !locked
            self.modelFlashCustomField.isEnabled = !locked
            self.btnApplyDeepseek.isEnabled = !locked
            self.btnApplyGpt.isEnabled = !locked
            self.btnRestartCodex.isEnabled = !locked
            self.modeSegmented.isEnabled = !locked
            
            if locked {
                self.activityIndicator.startAnimation(nil)
                self.loadingLabel.stringValue = message
                LogManager.log("锁定界面: \(message)")
            } else {
                self.activityIndicator.stopAnimation(nil)
                self.loadingLabel.stringValue = ""
                LogManager.log("解除界面锁定")
            }
            self.refreshStatus()
        }
    }
    
    @objc private func handleClearLogs() {
        LogManager.logs.removeAll()
        updateLogsDisplay()
    }
    
    @objc private func handleRefreshLogs() {
        updateLogsDisplay()
    }
    
    private func updateLogsDisplay() {
        let text = ConfigManager.shared.readBridgeLogs()
        logTextView.string = text
        logTextView.scrollRangeToVisible(NSRange(location: text.count, length: 0))
    }
    
    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        if index == 0 {
            gptConfigView.isHidden = false
            deepseekConfigView.isHidden = true
        } else {
            gptConfigView.isHidden = true
            deepseekConfigView.isHidden = false
        }
    }
    
    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == 0 {
            // Official DeepSeek
            baseUrlRow.isHidden = true
            modelProPopUp.selectItem(at: 0) // deepseek-reasoner
            modelFlashPopUp.selectItem(at: 0) // deepseek-chat
        } else if index == 1 {
            // SiliconFlow
            baseUrlRow.isHidden = true
            modelProPopUp.selectItem(at: 2) // deepseek-ai/DeepSeek-R1
            modelFlashPopUp.selectItem(at: 2) // deepseek-ai/DeepSeek-V3
        } else if index == 2 {
            // Custom
            baseUrlRow.isHidden = false
        }
        updateModelCustomFieldsVisibility()
    }
    
    @objc private func modelProChanged(_ sender: NSPopUpButton) {
        updateModelCustomFieldsVisibility()
    }
    
    @objc private func modelFlashChanged(_ sender: NSPopUpButton) {
        updateModelCustomFieldsVisibility()
    }
    
    private func updateModelCustomFieldsVisibility() {
        proCustomRow.isHidden = (modelProPopUp.indexOfSelectedItem != 4)
        flashCustomRow.isHidden = (modelFlashPopUp.indexOfSelectedItem != 4)
    }
    
    @objc private func toggleKeyVisibility() {
        let isSecureVisible = !secureKeyField.isHidden
        if isSecureVisible {
            secureKeyField.isHidden = true
            plainKeyField.isHidden = false
            plainKeyField.stringValue = secureKeyField.stringValue
            toggleKeyButton.title = "🙈"
            view.window?.makeFirstResponder(plainKeyField)
        } else {
            plainKeyField.isHidden = true
            secureKeyField.isHidden = false
            secureKeyField.stringValue = plainKeyField.stringValue
            toggleKeyButton.title = "👁️"
            view.window?.makeFirstResponder(secureKeyField)
        }
    }
    
    func controlTextDidChange(_ obj: Notification) {
        if let textField = obj.object as? NSTextField {
            if textField == secureKeyField {
                plainKeyField.stringValue = secureKeyField.stringValue
            } else if textField == plainKeyField {
                secureKeyField.stringValue = plainKeyField.stringValue
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Codex Switcher"
        window.center()
        
        let vc = SwitcherViewController()
        window.contentViewController = vc
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Start Application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
