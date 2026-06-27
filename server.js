const express = require('express');
const fs = require('fs');
const path = require('path');
const { exec, execSync, execFileSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Path Helper Constants
const HOME = process.env.HOME || '/Users/rubick';
const CODEX_HOME = path.join(HOME, '.codex');
const CONFIG_TOML = path.join(CODEX_HOME, 'config.toml');
const BRIDGE_HOME = path.join(CODEX_HOME, 'codex-deepseek-bridge');
const BRIDGE_BIN = path.join(BRIDGE_HOME, 'bin', 'codex-deepseek-bridge-macos');
const BRIDGE_KEY_FILE = path.join(BRIDGE_HOME, 'deepseek-key');
const SESSIONS_DIR = path.join(CODEX_HOME, 'sessions');
const ARCHIVED_SESSIONS_DIR = path.join(CODEX_HOME, 'archived_sessions');

// Simple log buffer for the UI
const serverLogs = [];
function log(msg) {
  const timestamp = new Date().toLocaleTimeString();
  const formatted = `[${timestamp}] ${msg}`;
  console.log(formatted);
  serverLogs.push(formatted);
  if (serverLogs.length > 100) serverLogs.shift();
}

function runProviderGuard(mode) {
  const candidates = [
    path.join(__dirname, 'scripts', 'provider-safe-guard.mjs'),
    path.join(HOME, 'codexswitch', 'scripts', 'provider-safe-guard.mjs')
  ];
  const script = candidates.find(candidate => fs.existsSync(candidate));
  if (!script) {
    log('Provider guard script not found; skipping session-copy preparation.');
    return;
  }
  try {
    const env = { ...process.env };
    
    // Inject standard search paths
    const additionalPaths = ['/opt/homebrew/bin', '/usr/local/bin'];
    const existingPath = env.PATH || '/usr/bin:/bin:/usr/sbin:/sbin';
    const pathComponents = existingPath.split(':');
    for (const addPath of additionalPaths) {
      if (!pathComponents.includes(addPath)) {
        pathComponents.push(addPath);
      }
    }
    env.PATH = pathComponents.join(':');
    
    const output = execFileSync(process.execPath, [script, mode], { env, encoding: 'utf8' }).trim();
    log(output || 'Provider guard completed.');
  } catch (e) {
    const detail = e.stderr ? String(e.stderr).trim() : e.message;
    log('Provider guard failed: ' + detail);
  }
}

// Helper: Check if Codex app is running
function isCodexRunning() {
  try {
    const stdout = execSync("osascript -e 'application \"Codex\" is running'", { encoding: 'utf8' });
    return stdout.trim() === 'true';
  } catch (e) {
    return false;
  }
}

// Helper: Quit Codex app
function quitCodex() {
  log("Requesting Codex to quit...");
  try {
    execSync("osascript -e 'tell application \"Codex\" to quit'", { timeout: 3000 });
  } catch (e) {
    // Ignore AppleScript timeout or error
  }
  // Sleep a moment, then force kill any remaining Codex processes
  try {
    execSync("sleep 1.5 && pkill -9 -f /Applications/Codex.app", { timeout: 3000 });
    log("Codex processes terminated.");
  } catch (e) {
    // Ignore if not running
  }
}

// Helper: Start Codex app
function startCodex() {
  log("Launching Codex app...");
  try {
    exec("open -a Codex");
  } catch (e) {
    log("Failed to launch Codex: " + e.message);
  }
}

// Helper: Count Codex sessions
function getSessionsCount() {
  let count = 0;
  try {
    if (fs.existsSync(SESSIONS_DIR)) {
      count += fs.readdirSync(SESSIONS_DIR).filter(f => !f.startsWith('.')).length;
    }
    if (fs.existsSync(ARCHIVED_SESSIONS_DIR)) {
      count += fs.readdirSync(ARCHIVED_SESSIONS_DIR).filter(f => !f.startsWith('.')).length;
    }
  } catch (e) {
    log("Error counting sessions: " + e.message);
  }
  return count;
}

// Helper: Read key-value fields from config.toml at the root level
function readTomlConfig() {
  const info = { model: 'unknown', provider: 'openai' };
  if (!fs.existsSync(CONFIG_TOML)) return info;

  try {
    const content = fs.readFileSync(CONFIG_TOML, 'utf8');
    const lines = content.split('\n');
    let inSection = false;

    for (let line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      
      // Stop reading root level keys once we enter any section
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inSection = true;
        continue;
      }
      
      if (!inSection) {
        const parts = trimmed.split('=');
        if (parts.length >= 2) {
          const key = parts[0].trim();
          let val = parts.slice(1).join('=').trim();
          if (val.startsWith('"') && val.endsWith('"')) {
            val = val.slice(1, -1);
          }
          if (key === 'model') info.model = val;
          if (key === 'model_provider') info.provider = val;
        }
      }
    }
  } catch (e) {
    log("Error parsing config.toml: " + e.message);
  }
  return info;
}

// GET /api/status
app.get('/api/status', async (req, res) => {
  const codexRunning = isCodexRunning();
  const config = readTomlConfig();
  const sessionsCount = getSessionsCount();
  const hasSavedKey = fs.existsSync(BRIDGE_KEY_FILE);

  let bridgeRunning = false;
  let bridgeConfig = null;

  try {
    // Attempt to query the bridge API if it's active
    const response = await fetch('http://localhost:8787/report/data', { signal: AbortSignal.timeout(1000) });
    if (response.ok) {
      const data = await response.json();
      bridgeRunning = true;
      bridgeConfig = {
        upstreamModel: data.config ? data.config.upstreamModel : 'unknown',
        baseUrl: data.config ? data.config.deepseekBaseUrl : 'unknown',
        apiKeyConfigured: data.config ? data.config.apiKeyConfigured : false
      };
    }
  } catch (e) {
    // Bridge is offline
  }

  res.json({
    codexRunning,
    bridgeRunning,
    currentConfig: config,
    bridgeConfig,
    sessionsCount,
    hasSavedKey
  });
});

// GET /api/backups
app.get('/api/backups', (req, res) => {
  const backupsList = [];
  try {
    if (fs.existsSync(CODEX_HOME)) {
      const files = fs.readdirSync(CODEX_HOME);
      for (const file of files) {
        if (file.startsWith('config.toml.') && file.endsWith('.bak')) {
          const filepath = path.join(CODEX_HOME, file);
          const stat = fs.statSync(filepath);
          backupsList.push({
            name: file,
            path: filepath,
            date: stat.mtime,
            size: stat.size
          });
        }
      }
    }
  } catch (e) {
    log("Error listing backups: " + e.message);
  }
  // Sort backups by date descending
  backupsList.sort((a, b) => b.date - a.date);
  res.json(backupsList);
});

// POST /api/switch
app.post('/api/switch', async (req, res) => {
  const { mode, provider, apiKey, baseUrl, modelPro, modelFlash } = req.body;
  log(`Switch request received: mode=${mode}`);

  if (mode === 'gpt') {
    try {
      quitCodex();
      log("Executing bridge restore...");
      
      let restored = false;
      if (fs.existsSync(BRIDGE_BIN)) {
        try {
          execSync(`"${BRIDGE_BIN}" restore`, { stdio: 'pipe' });
          log("Bridge restore command completed.");
          restored = true;
        } catch (restoreErr) {
          log("Bridge restore CLI failed, performing manual fallback restore...");
        }
      }
      
      if (!restored) {
        log("Performing manual fallback restore from backups...");
        const files = fs.readdirSync(CODEX_HOME);
        const backups = files
          .filter(f => f.startsWith('config.toml.') && f.endsWith('.bak'))
          .map(f => path.join(CODEX_HOME, f))
          .sort((a, b) => fs.statSync(b).mtime - fs.statSync(a).mtime);
        if (backups.length > 0) {
          fs.copyFileSync(backups[0], CONFIG_TOML);
          log(`Manually restored config from backup: ${path.basename(backups[0])}`);
        } else {
          log("No backup files found for manual restore.");
        }
      }

      // Explicitly make sure the bridge is stopped
      if (fs.existsSync(BRIDGE_BIN)) {
        try { execSync(`"${BRIDGE_BIN}" stop`, { stdio: 'pipe' }); } catch (e) {}
      }

      runProviderGuard('gpt');
      startCodex();
      return res.json({ success: true, message: "Switched to Codex Official (GPT)" });
    } catch (e) {
      log("Error switching to GPT: " + e.message);
      return res.status(500).json({ success: false, error: e.message });
    }
  }

  if (mode === 'deepseek') {
    try {
      if (!fs.existsSync(BRIDGE_BIN)) {
        return res.status(400).json({ success: false, error: "Bridge binary not found. Please install codex-deepseek-bridge." });
      }

      quitCodex();

      // Handle API Key
      let keyToUse = '';
      if (apiKey && apiKey !== '••••••••') {
        keyToUse = apiKey.trim();
        fs.writeFileSync(BRIDGE_KEY_FILE, keyToUse);
        log("Saved DeepSeek API Key to " + BRIDGE_KEY_FILE);
      } else if (fs.existsSync(BRIDGE_KEY_FILE)) {
        keyToUse = fs.readFileSync(BRIDGE_KEY_FILE, 'utf8').trim();
        log("Using previously saved API Key.");
      } else {
        return res.status(400).json({ success: false, error: "API Key is required for first-time DeepSeek setup." });
      }

      // Resolve variables based on provider preset
      let resolvedBaseUrl = 'https://api.deepseek.com';
      let resolvedModelPro = 'deepseek-reasoner';
      let resolvedModelFlash = 'deepseek-chat';

      if (provider === 'siliconflow') {
        resolvedBaseUrl = 'https://api.siliconflow.cn/v1';
        resolvedModelPro = modelPro || 'deepseek-ai/DeepSeek-R1';
        resolvedModelFlash = modelFlash || 'deepseek-ai/DeepSeek-V3';
      } else if (provider === 'custom') {
        resolvedBaseUrl = baseUrl || 'https://api.deepseek.com';
        resolvedModelPro = modelPro || 'deepseek-reasoner';
        resolvedModelFlash = modelFlash || 'deepseek-chat';
      } else {
        // official deepseek
        resolvedModelPro = modelPro || 'deepseek-reasoner';
        resolvedModelFlash = modelFlash || 'deepseek-chat';
      }

      log(`Setting up bridge with: url=${resolvedBaseUrl}, pro=${resolvedModelPro}, flash=${resolvedModelFlash}`);

      // Stop bridge if running before setup
      try { execSync(`"${BRIDGE_BIN}" stop`, { stdio: 'pipe' }); } catch (e) {}

      // Run bridge setup
      log("Running bridge setup command...");
      try {
        execSync(`"${BRIDGE_BIN}" setup --yes --no-start`, {
          env: { ...process.env, DEEPSEEK_API_KEY: keyToUse },
          stdio: 'pipe'
        });
        log("Bridge setup completed.");
      } catch (setupErr) {
        log("Bridge setup warning (e.g. desktop patch skipped): " + setupErr.message);
      }

      // Start bridge with custom environment variables
      log("Starting bridge with custom models/endpoints...");
      const startEnv = {
        ...process.env,
        DEEPSEEK_API_KEY: keyToUse,
        DEEPSEEK_BASE_URL: resolvedBaseUrl,
        DEEPSEEK_MODEL_PRO: resolvedModelPro,
        DEEPSEEK_MODEL_FLASH: resolvedModelFlash
      };

      execSync(`"${BRIDGE_BIN}" start`, { env: startEnv, stdio: 'pipe' });
      log("Bridge started successfully.");

      runProviderGuard('deepseek');
      startCodex();
      return res.json({ success: true, message: "Switched to DeepSeek Mode" });
    } catch (e) {
      log("Error switching to DeepSeek: " + e.message);
      return res.status(500).json({ success: false, error: e.message });
    }
  }

  res.status(400).json({ success: false, error: "Invalid mode specified" });
});

// POST /api/restore-backup
app.post('/api/restore-backup', (req, res) => {
  const { filepath } = req.body;
  log(`Request to restore backup: ${filepath}`);

  if (!filepath || !fs.existsSync(filepath)) {
    return res.status(400).json({ success: false, error: "Backup file not found." });
  }

  try {
    quitCodex();
    // Stop the bridge
    if (fs.existsSync(BRIDGE_BIN)) {
      try { execSync(`"${BRIDGE_BIN}" stop`, { stdio: 'pipe' }); } catch (e) {}
    }

    // Copy backup back to config.toml
    fs.copyFileSync(filepath, CONFIG_TOML);
    log("Successfully restored config.toml from " + path.basename(filepath));

    startCodex();
    res.json({ success: true, message: `Successfully restored backup: ${path.basename(filepath)}` });
  } catch (e) {
    log("Error restoring backup: " + e.message);
    res.status(500).json({ success: false, error: e.message });
  }
});

// POST /api/restart-codex
app.post('/api/restart-codex', (req, res) => {
  try {
    quitCodex();
    startCodex();
    res.json({ success: true, message: "Codex restarted." });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// GET /api/logs
app.get('/api/logs', (req, res) => {
  let logs = [...serverLogs];
  
  // Also try to read bridge output logs if they exist
  const stdoutPath = path.join(BRIDGE_HOME, 'bridge.stdout.log');
  const stderrPath = path.join(BRIDGE_HOME, 'bridge.stderr.log');

  try {
    if (fs.existsSync(stdoutPath)) {
      const stdout = fs.readFileSync(stdoutPath, 'utf8').trim().split('\n').slice(-30);
      logs.push("--- Bridge stdout ---", ...stdout.map(l => `[Bridge] ${l}`));
    }
    if (fs.existsSync(stderrPath)) {
      const stderr = fs.readFileSync(stderrPath, 'utf8').trim().split('\n').slice(-30);
      logs.push("--- Bridge stderr ---", ...stderr.map(l => `[Bridge Error] ${l}`));
    }
  } catch (e) {
    logs.push("[Server] Error reading bridge logs: " + e.message);
  }

  res.json(logs.slice(-60));
});

app.listen(PORT, () => {
  log(`Codex Model Switcher backend running on http://localhost:${PORT}`);
});
