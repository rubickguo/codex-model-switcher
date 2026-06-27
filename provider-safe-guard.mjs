#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const mode = process.argv[2] || "";
const home = os.homedir();
const codexHome = path.join(home, ".codex");

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
  if (result.dbs === 0) {
    console.log(`${label} 模式同步跳过：未找到兼容的 Codex 会话库。没有创建数据库；请先打开 Codex 创建会话，或适配新版会话库结构。`);
    return;
  }

  const skippedText = result.skipped.length > 0
    ? `，跳过 ${result.skipped.length} 个结构不兼容的库`
    : "";
  console.log(`${label} 模式同步完成：provider=${result.provider} model=${result.model}，同步 ${result.dbs} 个线程库，覆盖 ${result.rows} 条线程${skippedText}。未扫描或复制会话正文。`);
}

if (mode === "gpt") {
  printSyncResult("GPT", syncThreadInventoryForMode("gpt"));
} else if (mode === "deepseek") {
  printSyncResult("DeepSeek", syncThreadInventoryForMode("deepseek"));
} else {
  console.log("用法：provider-safe-guard.mjs gpt|deepseek");
}
