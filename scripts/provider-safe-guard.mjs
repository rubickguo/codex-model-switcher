#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const mode = process.argv[2] || "";
const home = os.homedir();
const codexHome = path.join(home, ".codex");
const sessionsRoot = path.join(codexHome, "sessions");
const archivedSessionsRoot = path.join(codexHome, "archived_sessions");
const stateDbCandidates = [
  path.join(codexHome, "sqlite", "state_5.sqlite"),
  path.join(codexHome, "state_5.sqlite"),
  path.join(codexHome, "state", "state_5.sqlite"),
];
const stateDb = stateDbCandidates.find((candidate) => fs.existsSync(candidate)) || stateDbCandidates[0];
const sessionIndexPath = path.join(codexHome, "session_index.jsonl");
const switcherDir = path.join(codexHome, "codex-model-switcher");
const mappingPath = path.join(switcherDir, "provider-safe-clones.json");
const globalStatePath = path.join(codexHome, ".codex-global-state.json");

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function sqlValue(value) {
  if (value === null || value === undefined) return "NULL";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "NULL";
  return `'${String(value).replaceAll("'", "''")}'`;
}

function sqliteJson(args) {
  if (!fs.existsSync(stateDb)) return [];
  try {
    const output = execFileSync("/usr/bin/sqlite3", ["-json", stateDb, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    return output ? JSON.parse(output) : [];
  } catch {
    return [];
  }
}

function sqliteExec(sql) {
  if (!fs.existsSync(stateDb)) return;
  execFileSync("/usr/bin/sqlite3", [stateDb, sql], { stdio: "ignore" });
}

function walkJsonlFiles(root) {
  const files = [];
  if (!fs.existsSync(root)) return files;
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        files.push(full);
      }
    }
  }
  return files;
}

function uuidV7() {
  const now = BigInt(Date.now());
  const random = crypto.randomBytes(10);
  const bytes = Buffer.alloc(16);
  bytes[0] = Number((now >> 40n) & 0xffn);
  bytes[1] = Number((now >> 32n) & 0xffn);
  bytes[2] = Number((now >> 24n) & 0xffn);
  bytes[3] = Number((now >> 16n) & 0xffn);
  bytes[4] = Number((now >> 8n) & 0xffn);
  bytes[5] = Number(now & 0xffn);
  bytes[6] = 0x70 | (random[0] & 0x0f);
  bytes[7] = random[1];
  bytes[8] = 0x80 | (random[2] & 0x3f);
  random.copy(bytes, 9, 3);
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function extractSessionId(file, lines) {
  const match = path.basename(file).match(/rollout-[^-]+T[^-]+-([0-9a-f-]{36})\.jsonl$/i);
  if (match) return match[1];
  for (const line of lines) {
    try {
      const item = JSON.parse(line);
      if (item?.type === "session_meta" && item?.payload?.id) return item.payload.id;
    } catch {
      continue;
    }
  }
  return null;
}

function updateProviderMetadata(value, provider, model) {
  if (Array.isArray(value)) {
    return value.map((item) => updateProviderMetadata(item, provider, model));
  }
  if (!value || typeof value !== "object") return value;

  for (const key of Object.keys(value)) {
    if (key === "model_provider") {
      value[key] = provider;
    } else if (key === "model") {
      value[key] = model;
    } else if (key === "encrypted_content" && typeof value[key] === "string" && value[key].startsWith("dscb")) {
      delete value[key];
    } else {
      value[key] = updateProviderMetadata(value[key], provider, model);
    }
  }
  return value;
}

function transformForGpt(lines, newId) {
  const output = [];
  let stripped = 0;
  for (const line of lines) {
    if (!line.trim()) continue;
    let item;
    try {
      item = JSON.parse(line);
    } catch {
      output.push(line);
      continue;
    }

    const payload = item?.payload;
    if (
      item?.type === "response_item" &&
      payload?.type === "reasoning" &&
      typeof payload?.encrypted_content === "string" &&
      payload.encrypted_content.startsWith("dscb")
    ) {
      stripped += 1;
      continue;
    }

    if (item?.type === "session_meta" && item.payload) {
      item.payload.id = newId;
    }
    updateProviderMetadata(item, "openai", "gpt-5.5");
    output.push(JSON.stringify(item));
  }
  return { lines: output, stripped };
}

function currentRolloutPath(newId) {
  const now = new Date();
  const year = String(now.getFullYear());
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const dir = path.join(sessionsRoot, year, month, day);
  ensureDir(dir);
  const stamp = now.toISOString().replace(/\.\d{3}Z$/, "").replaceAll(":", "-");
  return path.join(dir, `rollout-${stamp}-${newId}.jsonl`);
}

function getThreadRow(id) {
  const rows = sqliteJson([`SELECT * FROM threads WHERE id=${sqlValue(id)} LIMIT 1;`]);
  return rows[0] || null;
}

function getThreadColumns() {
  return sqliteJson(["PRAGMA table_info(threads);"]).map((row) => row.name);
}

function sessionIndexName(id) {
  if (!fs.existsSync(sessionIndexPath)) return null;
  const lines = fs.readFileSync(sessionIndexPath, "utf8").split(/\r?\n/);
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      if (row.id === id && row.thread_name) return row.thread_name;
    } catch {
      continue;
    }
  }
  return null;
}

function compactText(text, limit = 180) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}

function inferThreadMetadata(originalId, lines) {
  const metadata = {
    source: "codex",
    cwd: home,
    title: sessionIndexName(originalId) || "DeepSeek 会话",
    sandbox_policy: "{\"type\":\"dangerFullAccess\"}",
    approval_mode: "never",
    cli_version: "",
    first_user_message: "",
    thread_source: null,
    preview: "",
  };

  for (const line of lines) {
    let item;
    try {
      item = JSON.parse(line);
    } catch {
      continue;
    }

    if (item?.type === "session_meta" && item.payload) {
      metadata.source = item.payload.source || metadata.source;
      metadata.thread_source = item.payload.thread_source || metadata.thread_source;
      metadata.cli_version = item.payload.cli_version || metadata.cli_version;
    }

    if (item?.type === "turn_context" && item.payload) {
      metadata.cwd = item.payload.cwd || metadata.cwd;
      if (item.payload.sandbox_policy) metadata.sandbox_policy = JSON.stringify(item.payload.sandbox_policy);
      metadata.approval_mode = item.payload.approval_policy || metadata.approval_mode;
    }

    if (!metadata.first_user_message && item?.type === "response_item" && item.payload?.role === "user") {
      const parts = item.payload.content || [];
      const text = parts
        .map((part) => part?.text || "")
        .filter(Boolean)
        .join("\n");
      metadata.first_user_message = compactText(text, 1000);
      metadata.preview = compactText(text, 500);
      if (!sessionIndexName(originalId)) metadata.title = compactText(text, 120) || metadata.title;
    }
  }

  metadata.title = `${compactText(metadata.title, 120)}（GPT 续写）`;
  return metadata;
}

function insertCloneThread(originalId, newId, clonePath, originalLines) {
  const original = getThreadRow(originalId);
  if (!original) return false;
  const columns = getThreadColumns();
  if (!columns.length) return false;

  const nowMs = Date.now();
  const nowSeconds = Math.floor(nowMs / 1000);
  const clone = { ...original };
  clone.id = newId;
  clone.rollout_path = clonePath;
  clone.model_provider = "openai";
  clone.model = "gpt-5.5";
  clone.reasoning_effort = clone.reasoning_effort || "xhigh";
  clone.title = `${original.title || "DeepSeek 会话"}（GPT 续写）`;
  clone.created_at = nowSeconds;
  clone.updated_at = nowSeconds;
  clone.last_updated_at = nowSeconds;
  clone.recency_at = nowSeconds;
  clone.created_at_ms = nowMs;
  clone.updated_at_ms = nowMs;
  clone.has_user_event = 1;
  clone.archived = 0;

  const writableColumns = columns.filter((name) => Object.prototype.hasOwnProperty.call(clone, name));
  const sql = `INSERT OR REPLACE INTO threads (${writableColumns.map((name) => `"${name}"`).join(",")}) VALUES (${writableColumns.map((name) => sqlValue(clone[name])).join(",")});`;
  sqliteExec(sql);
  return true;
}

function insertMinimalCloneThread(originalId, newId, clonePath, originalLines) {
  const columns = getThreadColumns();
  if (!columns.length) return false;
  const nowMs = Date.now();
  const nowSeconds = Math.floor(nowMs / 1000);
  const metadata = inferThreadMetadata(originalId, originalLines);
  const clone = {
    id: newId,
    rollout_path: clonePath,
    created_at: nowSeconds,
    updated_at: nowSeconds,
    source: metadata.source,
    model_provider: "openai",
    cwd: metadata.cwd,
    title: metadata.title,
    sandbox_policy: metadata.sandbox_policy,
    approval_mode: metadata.approval_mode,
    tokens_used: 0,
    has_user_event: 1,
    archived: 0,
    archived_at: null,
    git_sha: null,
    git_branch: null,
    git_origin_url: null,
    cli_version: metadata.cli_version,
    first_user_message: metadata.first_user_message,
    agent_nickname: null,
    agent_role: null,
    memory_mode: "enabled",
    model: "gpt-5.5",
    reasoning_effort: "xhigh",
    agent_path: null,
    created_at_ms: nowMs,
    updated_at_ms: nowMs,
    thread_source: metadata.thread_source,
    preview: metadata.preview,
  };
  const writableColumns = columns.filter((name) => Object.prototype.hasOwnProperty.call(clone, name));
  const sql = `INSERT OR REPLACE INTO threads (${writableColumns.map((name) => `"${name}"`).join(",")}) VALUES (${writableColumns.map((name) => sqlValue(clone[name])).join(",")});`;
  sqliteExec(sql);
  return true;
}

function markOriginalAsDeepSeek(id) {
  if (!fs.existsSync(stateDb)) return;
  sqliteExec(`UPDATE threads SET model_provider='custom' WHERE id=${sqlValue(id)};`);
}

function appendSessionIndex(newId, clonePath) {
  let existing = "";
  if (fs.existsSync(sessionIndexPath)) {
    existing = fs.readFileSync(sessionIndexPath, "utf8");
    if (existing.includes(newId)) return;
  }
  const row = {
    id: newId,
    thread_name: `GPT 安全副本 ${newId}`,
    updated_at: new Date().toISOString(),
    path: clonePath,
  };
  fs.appendFileSync(sessionIndexPath, `${JSON.stringify(row)}\n`);
}

function copyWorkspaceHint(originalId, newId) {
  const state = readJson(globalStatePath, {});
  const hints = state["thread-workspace-root-hints"];
  if (!hints || typeof hints !== "object") return;
  hints[newId] = hints[originalId] || hints[newId] || process.cwd();
  writeJson(globalStatePath, state);
}

function createGptClone(file, originalId, map) {
  const existing = map.gpt?.[originalId];
  if (existing?.path && fs.existsSync(existing.path)) {
    return { skipped: true };
  }

  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
  const newId = uuidV7();
  const clonePath = currentRolloutPath(newId);
  const transformed = transformForGpt(lines, newId);
  fs.writeFileSync(clonePath, `${transformed.lines.join("\n")}\n`);

  const dbInserted =
    insertCloneThread(originalId, newId, clonePath, lines) ||
    insertMinimalCloneThread(originalId, newId, clonePath, lines);
  appendSessionIndex(newId, clonePath);
  copyWorkspaceHint(originalId, newId);
  markOriginalAsDeepSeek(originalId);

  map.gpt ||= {};
  map.gpt[originalId] = {
    id: newId,
    path: clonePath,
    source: file,
    stripped_reasoning_items: transformed.stripped,
    created_at: new Date().toISOString(),
    db_inserted: dbInserted,
  };
  return { cloned: true, stripped: transformed.stripped, id: newId };
}

function guardGptMode() {
  ensureDir(switcherDir);
  const map = readJson(mappingPath, {});
  const files = [...walkJsonlFiles(sessionsRoot), ...walkJsonlFiles(archivedSessionsRoot)];
  let found = 0;
  let cloned = 0;
  let skipped = 0;
  let errors = 0;

  for (const file of files) {
    let content = "";
    try {
      content = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    if (!content.includes('"encrypted_content":"dscb')) continue;
    const lines = content.split(/\r?\n/).filter(Boolean);
    const originalId = extractSessionId(file, lines);
    if (!originalId) continue;
    found += 1;

    try {
      const result = createGptClone(file, originalId, map);
      if (result.cloned) cloned += 1;
      if (result.skipped) skipped += 1;
    } catch (error) {
      errors += 1;
      console.error(`provider-safe-guard: ${path.basename(file)}: ${error.message}`);
    }
  }

  writeJson(mappingPath, map);
  console.log(`GPT 保护完成：发现 ${found} 个 DeepSeek 加密会话，新增 GPT 副本 ${cloned} 个，已存在 ${skipped} 个，失败 ${errors} 个。`);
}

if (mode === "gpt") {
  guardGptMode();
} else if (mode === "deepseek") {
  console.log("DeepSeek 模式保护完成：不改写历史会话。");
} else {
  console.log("用法：provider-safe-guard.mjs gpt|deepseek");
}
