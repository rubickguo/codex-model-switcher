#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const mode = process.argv[2] || "";
const home = os.homedir();
const codexHome = process.env.CODEX_HOME && process.env.CODEX_HOME.trim().length > 0
  ? process.env.CODEX_HOME.replace(/^~(?=$|\/)/, home)
  : path.join(home, ".codex");

function stateDbCandidates() {
  const candidates = [
    path.join(codexHome, "state_5.sqlite"),
    path.join(codexHome, "sqlite", "state_5.sqlite"),
    path.join(codexHome, "state", "state_5.sqlite"),
  ];

  for (const dir of [codexHome, path.join(codexHome, "sqlite"), path.join(codexHome, "state")]) {
    let names = [];
    try {
      names = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      if (name.startsWith("state_") && name.endsWith(".sqlite")) {
        candidates.push(path.join(dir, name));
      }
    }
  }

  return candidates;
}

function sqlValue(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replaceAll("'", "''")}'`;
}

function sqliteScalar(db, sql) {
  return execFileSync("/usr/bin/sqlite3", [db, sql], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function sqliteJson(db, sql) {
  const output = execFileSync("/usr/bin/sqlite3", ["-json", db, sql], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
  return output ? JSON.parse(output) : [];
}

function existingStateDbs() {
  const seen = new Set();
  return stateDbCandidates().filter((candidate) => {
    const normalized = path.resolve(candidate);
    if (!fs.existsSync(normalized) || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

function dbHasThreadInventorySchema(db) {
  try {
    const columns = new Set(sqliteJson(db, "PRAGMA table_info(threads);").map((column) => column.name));
    return columns.has("model_provider") && columns.has("model");
  } catch {
    return false;
  }
}

function modelForMode(targetMode) {
  return targetMode === "deepseek"
    ? { provider: "custom", model: "deepseek-pro" }
    : { provider: "openai", model: "gpt-5.5" };
}

function walkJsonl(dir) {
  const output = [];
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return output;
  }
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) output.push(...walkJsonl(fullPath));
    if (entry.isFile() && entry.name.endsWith(".jsonl")) output.push(fullPath);
  }
  return output;
}

function sessionJsonlPaths() {
  return [
    ...walkJsonl(path.join(codexHome, "sessions")),
    ...walkJsonl(path.join(codexHome, "archived_sessions")),
  ].sort();
}

function rewriteSessionMetaProvider(text, targetProvider) {
  const hadTrailingNewline = text.endsWith("\n");
  const lines = text.split(/\n/);
  let changed = false;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.includes("\"session_meta\"") || !line.includes("\"model_provider\"")) continue;
    let object;
    try {
      object = JSON.parse(line);
    } catch {
      continue;
    }
    if (object?.type !== "session_meta") continue;
    const currentProvider = object?.payload?.model_provider;
    if (typeof currentProvider !== "string" || currentProvider === targetProvider) continue;

    const compactOld = `"model_provider":"${currentProvider}"`;
    const compactNew = `"model_provider":"${targetProvider}"`;
    if (line.includes(compactOld)) {
      lines[index] = line.replace(compactOld, compactNew);
    } else {
      object.payload.model_provider = targetProvider;
      lines[index] = JSON.stringify(object);
    }
    changed = true;
    break;
  }

  let output = lines.join("\n");
  if (hadTrailingNewline && !output.endsWith("\n")) output += "\n";
  return { output, changed };
}

function syncSessionMetaForMode(targetMode) {
  const { provider } = modelForMode(targetMode);
  let scanned = 0;
  let rows = 0;
  for (const file of sessionJsonlPaths()) {
    scanned += 1;
    const original = fs.readFileSync(file, "utf8").replaceAll("\r\n", "\n");
    const { output, changed } = rewriteSessionMetaProvider(original, provider);
    if (!changed) continue;
    fs.writeFileSync(file, output, "utf8");
    rows += 1;
  }
  return { scanned, rows };
}

function syncThreadInventoryForMode(targetMode) {
  const { provider, model } = modelForMode(targetMode);
  let dbs = 0;
  let rows = 0;
  const skipped = [];

  for (const db of existingStateDbs()) {
    if (!dbHasThreadInventorySchema(db)) {
      skipped.push(db);
      continue;
    }
    const changed = sqliteScalar(
      db,
      `PRAGMA wal_checkpoint(TRUNCATE); BEGIN IMMEDIATE; UPDATE threads SET model_provider = ${sqlValue(provider)}, model = ${sqlValue(model)}; SELECT changes(); COMMIT; PRAGMA wal_checkpoint(TRUNCATE);`,
    );
    dbs += 1;
    const numericLine = changed.split(/\r?\n/).find((line) => /^\d+$/.test(line.trim()));
    rows += Number(numericLine || 0);
  }

  return { provider, model, dbs, rows, skipped };
}

function printSyncResult(label, result) {
  const sessions = syncSessionMetaForMode(mode);
  if (result.dbs === 0) {
    console.log(`${label} 模式同步跳过：未找到兼容的 Codex 会话库。已扫描 ${sessions.scanned} 个 JSONL 会话文件，更新 ${sessions.rows} 个 session_meta。没有创建数据库；请先打开 Codex 创建会话，或适配新版会话库结构。`);
    return;
  }

  const skippedText = result.skipped.length > 0
    ? `，跳过 ${result.skipped.length} 个结构不兼容的库`
    : "";
  console.log(`${label} 模式同步完成：provider=${result.provider} model=${result.model}，同步 ${result.dbs} 个线程库，覆盖 ${result.rows} 条线程${skippedText}；扫描 ${sessions.scanned} 个 JSONL 会话文件，更新 ${sessions.rows} 个 session_meta。未改写消息正文。`);
}

if (mode === "gpt") {
  printSyncResult("GPT", syncThreadInventoryForMode("gpt"));
} else if (mode === "deepseek") {
  printSyncResult("DeepSeek", syncThreadInventoryForMode("deepseek"));
} else {
  console.log("用法：provider-safe-guard.mjs gpt|deepseek");
}
