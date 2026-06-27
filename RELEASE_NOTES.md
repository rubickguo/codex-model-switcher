# v0.2.3

Bug 修复版本。

- 修复 DeepSeek 模式仍看不到全部会话的问题：切换时现在同时同步 SQLite 线程索引和 JSONL `session_meta.model_provider`，不再只改 `threads` 表。
- 新增切换日志：`~/.codex/codex-model-switcher/switcher.log`，记录每次切换扫描和更新了多少 SQLite / JSONL 项。
- 重置个人配置时会恢复首次备份的 JSONL `session_meta.model_provider`。

# v0.2.2

Bug 修复版本。

- 修复切换到 DeepSeek 后，在部分新机器上看不到历史会话的问题：会话索引同步现在由 App 本体执行，并动态识别 `~/.codex` 下的 `state_*.sqlite`，不再依赖 Node 脚本或固定 `state_5.sqlite` 路径。
- 修复切回 GPT 后 App UI 仍显示 DeepSeek 的问题：GPT 配置块不再被误判为 DeepSeek。
- GPT 模式不再写入 inactive 的 custom provider，避免 Codex 模型选择器继续显示“自定义”。

# v0.2.1

- 修复切换回 GPT 时，注释标志子串匹配冲突导致的 UI 状态未及时切回的问题。
- 修复他人电脑上因缺 Node.js 或 GUI 启动缺 PATH 导致的切换模型时会话丢失问题（智能扫描多路径并动态补齐 PATH 环境变量）。
- 集成高清应用图标并增加 Ad-hoc 代码签名，规避他人打开时出现“已损坏”的安全警告。

# v0.1.0

首个公开版本。

- 支持 GPT / DeepSeek 一键切换。
- 自动安装并启动 codex-deepseek-bridge。
- 支持保存和编辑 DeepSeek API 密钥。
- 切换时保留 Codex 本地会话列表。
- 首次打开 App 时备份用户原始配置。
- 支持一键重置个人配置，不删除 DeepSeek API 密钥。
- 不修改 Codex.app 本体，避免破坏官方自动更新。

已知限制：

- 只支持 DeepSeek。
- release 包是未公证的本地签名 macOS App。
- 共享的是会话列表，不保证同一线程跨 provider 无缝续写。
