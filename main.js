const { app, BrowserWindow } = require('electron');
const path = require('path');
const express = require('express');
const fs = require('fs');
const { exec, execSync, execFileSync } = require('child_process');

const serverApp = express();
const PORT = 18788; // Use a custom port to avoid conflicts

serverApp.use(express.json());
serverApp.use(express.static(path.join(__dirname, 'public')));

// Path Helper Constants
const HOME = process.env.HOME || '/Users/rubick';
const CODEX_HOME = path.join(HOME, '.codex');
const CONFIG_TOML = path.join(CODEX_HOME, 'config.toml');
const BRIDGE_HOME = path.join(CODEX_HOME, 'codex-deepseek-bridge');
const BRIDGE_BIN = path.join(BRIDGE_HOME, 'bin', 'codex-deepseek-bridge-macos');
const BRIDGE_KEY_FILE = path.join(BRIDGE_HOME, 'deepseek-key');
const SESSIONS_DIR = path.join(CODEX_HOME, 'sessions');
const ARCHIVED_SESSIONS_DIR = path.join(CODEX_HOME, 'archived_sessions');

const serverLogs = [];
function log(msg) {
  const timestamp = new Date().toLocaleTimeString();
  const formatted = `[${timestamp}] ${msg}`;
  console.log(formatted);
  serverLogs.push(formatted);
  if (serverLogs.length > 100) serverLogs.shift();
}

function findNodePath() {
  if (process.versions && process.versions.electron) {
    return process.execPath;
  }
  const candidates = [
    '/Applications/Codex.app/Contents/Resources/cua_node/bin/node',
    path.join(HOME, 'Applications/Codex.app/Contents/Resources/cua_node/bin/node'),
    '/opt/homebrew/bin/node',
    '/usr/local/bin/node',
    '/usr/bin/node'
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return 'node';
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
    const nodePath = findNodePath();
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
    
    if (nodePath === process.execPath) {
      env.ELECTRON_RUN_AS_NODE = '1';
    }
    
    const execPath = nodePath === 'node' ? '/usr/bin/env' : nodePath;
    const args = nodePath === 'node' ? ['node', script, mode] : [script, mode];
    
    const output = execFileSync(execPath, args, { env, encoding: 'utf8' }).trim();
    log(output || 'Provider guard completed.');
  } catch (e) {
    const detail = e.stderr ? String(e.stderr).trim() : e.message;
    log('Provider guard failed: ' + detail);
  }
}

function isCodexRunning() {
  try {
    const stdout = execSync("osascript -e 'application \"Codex\" is running'", { encoding: 'utf8' });
    return stdout.trim() === 'true';
  } catch (e) {
    return false;
  }
}

function quitCodex() {
  log("Requesting Codex to quit...");
  try {
    execSync("osascript -e 'tell application \"Codex\" to quit'", { timeout: 3000 });
  } catch (e) {}
  try {
    execSync("sleep 1.5 && pkill -9 -f /Applications/Codex.app", { timeout: 3000 });
    log("Codex processes terminated.");
  } catch (e) {}
}

function startCodex() {
  log("Launching Codex app...");
  try {
    exec("open -a Codex");
  } catch (e) {
    log("Failed to launch Codex: " + e.message);
  }
}

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

serverApp.get('/api/status', async (req, res) => {
  const codexRunning = isCodexRunning();
  const config = readTomlConfig();
  const sessionsCount = getSessionsCount();
  const hasSavedKey = fs.existsSync(BRIDGE_KEY_FILE);

  let bridgeRunning = false;
  let bridgeConfig = null;

  try {
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
  } catch (e) {}

  res.json({
    codexRunning,
    bridgeRunning,
    currentConfig: config,
    bridgeConfig,
    sessionsCount,
    hasSavedKey
  });
});

serverApp.get('/api/backups', (req, res) => {
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
  backupsList.sort((a, b) => b.date - a.date);
  res.json(backupsList);
});

serverApp.post('/api/switch', async (req, res) => {
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
          log(`Manually restored config: ${path.basename(backups[0])}`);
        } else {
          log("No backup files found for manual restore.");
        }
      }

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
        return res.status(400).json({ success: false, error: "Bridge binary not found." });
      }
      quitCodex();
      let keyToUse = '';
      if (apiKey && apiKey !== '••••••••') {
        keyToUse = apiKey.trim();
        fs.writeFileSync(BRIDGE_KEY_FILE, keyToUse);
        log("Saved DeepSeek API Key.");
      } else if (fs.existsSync(BRIDGE_KEY_FILE)) {
        keyToUse = fs.readFileSync(BRIDGE_KEY_FILE, 'utf8').trim();
      } else {
        return res.status(400).json({ success: false, error: "API Key is required." });
      }

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
        resolvedModelPro = modelPro || 'deepseek-reasoner';
        resolvedModelFlash = modelFlash || 'deepseek-chat';
      }

      log(`Setting up bridge with: url=${resolvedBaseUrl}, pro=${resolvedModelPro}, flash=${resolvedModelFlash}`);
      try { execSync(`"${BRIDGE_BIN}" stop`, { stdio: 'pipe' }); } catch (e) {}
      try {
        execSync(`"${BRIDGE_BIN}" setup --yes --no-start`, {
          env: { ...process.env, DEEPSEEK_API_KEY: keyToUse },
          stdio: 'pipe'
        });
      } catch (setupErr) {}

      const startEnv = {
        ...process.env,
        DEEPSEEK_API_KEY: keyToUse,
        DEEPSEEK_BASE_URL: resolvedBaseUrl,
        DEEPSEEK_MODEL_PRO: resolvedModelPro,
        DEEPSEEK_MODEL_FLASH: resolvedModelFlash
      };
      execSync(`"${BRIDGE_BIN}" start`, { env: startEnv, stdio: 'pipe' });
      runProviderGuard('deepseek');
      startCodex();
      return res.json({ success: true, message: "Switched to DeepSeek Mode" });
    } catch (e) {
      log("Error switching to DeepSeek: " + e.message);
      return res.status(500).json({ success: false, error: e.message });
    }
  }
});

serverApp.post('/api/restore-backup', (req, res) => {
  const { filepath } = req.body;
  if (!filepath || !fs.existsSync(filepath)) {
    return res.status(400).json({ success: false, error: "Backup file not found." });
  }
  try {
    quitCodex();
    if (fs.existsSync(BRIDGE_BIN)) {
      try { execSync(`"${BRIDGE_BIN}" stop`, { stdio: 'pipe' }); } catch (e) {}
    }
    fs.copyFileSync(filepath, CONFIG_TOML);
    startCodex();
    res.json({ success: true, message: `Successfully restored backup.` });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

serverApp.post('/api/restart-codex', (req, res) => {
  try {
    quitCodex();
    startCodex();
    res.json({ success: true, message: "Codex restarted." });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

serverApp.get('/api/logs', (req, res) => {
  let logs = [...serverLogs];
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
  } catch (e) {}
  res.json(logs.slice(-60));
});

const server = serverApp.listen(PORT, () => {
  log(`Switcher backend running internally on port ${PORT}`);
});

// Electron UI Window
let mainWindow;
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 800,
    title: "Codex Model Switcher",
    icon: path.join(__dirname, 'public', 'favicon.ico'),
    backgroundColor: '#0a0d16',
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true
    }
  });

  mainWindow.loadURL(`http://localhost:${PORT}`);

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  server.close();
  app.quit();
});
