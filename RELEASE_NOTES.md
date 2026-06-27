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
