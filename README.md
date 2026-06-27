# Codex 模型切换器

一个 macOS 小工具，用来在 Codex Desktop 里一键切换官方 GPT 模式和 DeepSeek 模式。第一版只支持 DeepSeek，通过 [codex-deepseek-bridge](https://github.com/JetXu-LLM/codex-deepseek-bridge) 转发请求。

## 功能

- 一键切换 GPT / DeepSeek。
- 在 DeepSeek 模式下自动安装并启动 bridge。
- 支持保存和编辑 DeepSeek API 密钥。
- 切换时保留 Codex 本地会话列表。
- 首次打开 App 时保存一份个人配置备份。
- 点击「重置个人配置」时恢复首次备份的 Codex 配置和会话索引。
- 不修改 `/Applications/Codex.app` 本体，不影响 Codex 官方自动更新。

## 会话保留机制

Codex 的会话正文在 `~/.codex/sessions`，侧边栏索引在 `~/.codex/state_*.sqlite` 等本地状态库里。

本工具不会复制、扫描或删除会话正文。切换模型时会查找已有 Codex 状态库，并只同步 `threads` 表里的 `model_provider` 和 `model` 两个索引字段，让同一批会话在 GPT 和 DeepSeek 模式下都可见。

如果用户机器上没有兼容的 Codex 会话库，本工具不会创建数据库，也不会伪造会话表。需要先打开 Codex 创建会话，或者等待本工具适配新版 Codex 会话库结构。

## 重置个人配置

第一次打开 App 时，本工具会在下面的位置保存初始备份：

```text
~/.codex/codex-model-switcher/initial-backup/
```

备份内容包括：

- 当时的 `~/.codex/config.toml`
- 当时 Codex 会话索引里的 `model_provider` / `model`

点击「重置个人配置」会恢复这份备份，并停止 DeepSeek bridge。它不会删除 DeepSeek API 密钥，也不会删除 bridge 二进制文件。

注意：普通 `.app` 没有安装钩子，所以备份发生在第一次打开 App 时，而不是下载或复制到 Applications 的瞬间。

## 安装

从 Releases 下载 zip，解压后把 `Codex 模型切换器.app` 放到 `~/Applications` 或 `/Applications`。

当前 release 是本地签名版本，没有 Apple Developer ID 公证。首次打开时 macOS 可能提示无法验证开发者，可以在系统设置里允许打开，或右键选择打开。

## 从源码构建

要求：

- macOS 13 或更新版本
- Xcode Command Line Tools
- 已安装 Codex Desktop

构建：

```bash
./build_app.sh
```

构建脚本会生成并安装：

```text
~/Applications/Codex 模型切换器.app
```

## 测试

发布前测试清单见 [QA.md](QA.md)。

快速检查当前机器状态：

```bash
./scripts/qa_check.sh
```

测试会话索引在 GPT / DeepSeek 之间往返是否保留：

```bash
./scripts/qa_check.sh --roundtrip-index
```

## 限制

- 第一版只支持 DeepSeek。
- release 构建面向 Apple Silicon Mac。
- 会话列表可以在 GPT 和 DeepSeek 模式间共享，但不承诺同一条线程在两个 provider 间无缝续写。隐藏加密推理块可能不兼容。
- Codex 的本地会话库不是公开稳定 API。如果未来 Codex 修改 schema，需要适配本工具。
