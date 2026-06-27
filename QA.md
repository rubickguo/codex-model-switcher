# QA 测试清单

这份清单用于验证 release 版 App 是否满足四个核心要求。

## 先说明核心依赖

本项目没有复制 `codex-deepseek-bridge` 的源码。App 在需要 DeepSeek 模式时，会从 `JetXu-LLM/codex-deepseek-bridge` 的 GitHub Release 下载对应平台的二进制，并通过它在本地启动 bridge。

本项目自己负责：

- macOS UI。
- DeepSeek API Key 保存。
- 写入 Codex 的 `~/.codex/config.toml`。
- 生成 DeepSeek 模型 catalog。
- 同步 Codex 会话侧边栏索引。
- 首次打开时备份用户原始配置。
- 重置时恢复用户原始配置和会话索引。

bridge 负责：

- 接收 Codex 发到本地 `http://127.0.0.1:8787/v1` 的请求。
- 转发到 DeepSeek。
- 返回 Codex 兼容的响应。

## 0. 基础检查

运行：

```bash
./scripts/qa_check.sh
```

应该看到：

- Codex.app 是 OpenAI 官方签名。
- Codex 模型切换器 App 存在且签名可验证。
- 会话库能读到 `threads` 表统计。
- 如果已经打开过切换器，应能看到 initial backup。
- DeepSeek key 只显示是否存在和权限，不显示内容。

## 1. UI 切换和会话保留

准备：

1. 打开 Codex，确认侧边栏里已有至少两条会话。
2. 打开「Codex 模型切换器」。
3. 如果是第一次打开，确认 `~/.codex/codex-model-switcher/initial-backup/manifest.json` 被创建。

测试 GPT 到 DeepSeek：

1. 点击切换到 DeepSeek。
2. 如果没有 key，App 应显示需要 DeepSeek API 密钥。
3. 输入 key 后保存并切换。
4. App UI 应显示 DeepSeek 模式已启用或已选择。
5. Codex 重启后，侧边栏会话仍然存在。
6. 在 Codex 模型选择器中应看到 DeepSeek Pro / Flash，默认应是 DeepSeek Pro。

用脚本验证会话索引：

```bash
./scripts/qa_check.sh --roundtrip-index
```

这个脚本会只测试会话索引同步，不测试 UI，也不发送模型请求。它会执行：

- GPT 索引切到 DeepSeek。
- 验证主会话库数量不变。
- DeepSeek 索引切回 GPT。
- 验证主会话库数量不变。

测试 DeepSeek 到 GPT：

1. 在 App 中点击切换到 GPT。
2. App UI 应显示 GPT 模式已启用。
3. Codex 重启后，侧边栏会话仍然存在。
4. Codex 默认模型应回到 GPT-5.5。

## 2. DeepSeek API Key 读取

无 key 测试：

1. 删除或临时移走 `~/.codex/codex-deepseek-bridge/deepseek-key`。
2. 打开 App，点击切到 DeepSeek。
3. UI 应要求输入 DeepSeek API 密钥，不能静默切换成功。

保存 key 测试：

1. 在 UI 中输入 DeepSeek API Key。
2. 点击保存或保存并切换。
3. 运行：

```bash
./scripts/qa_check.sh
```

应该看到 `DeepSeek key: present`，并且权限应为 `600` 或更严格。

bridge 读取测试：

1. 切到 DeepSeek。
2. 运行：

```bash
~/.codex/codex-deepseek-bridge/bin/codex-deepseek-bridge-macos status
```

Apple Silicon 上应显示 bridge 正在运行，且监听 `:8787`。Intel Mac 上二进制名是 `codex-deepseek-bridge-macos-x64`。

最终请求测试：

1. 在 Codex 新开一个会话。
2. 选择 DeepSeek Pro。
3. 问一句短问题，例如：`用一句话回答你现在使用的模型。`
4. 如果配置生效，回答应体现 DeepSeek Pro，而不是 GPT。

## 3. 不影响 Codex 正常更新

运行：

```bash
codesign --verify --deep --strict /Applications/Codex.app
spctl -a -vv /Applications/Codex.app
```

应显示 Codex.app 被系统接受，来源是 OpenAI 的 Developer ID。

再运行：

```bash
/Applications/Codex.app/Contents/Resources/codex doctor
```

在 `/tmp` 目录运行时，配置和 Updates 区块应为正常状态。

关键判断：

- 本工具不修改 `/Applications/Codex.app`。
- 不改 `app.asar`。
- 不重签 Codex.app。
- 只改 `~/.codex` 下的个人配置和本工具自己的状态目录。

## 4. 重置个人配置

准备：

1. 确认第一次打开 App 后已经有：

```text
~/.codex/codex-model-switcher/initial-backup/manifest.json
~/.codex/codex-model-switcher/initial-backup/config.toml
```

2. 切到 DeepSeek。
3. 确认 Codex 侧边栏会话仍然存在。

执行重置：

1. 点击「重置个人配置」。
2. Codex 应重启。
3. `~/.codex/config.toml` 应恢复到首次打开 App 时保存的版本。
4. 会话侧边栏应回到首次备份中的索引状态。
5. `~/.codex/codex-deepseek-bridge/deepseek-key` 不应被删除。

验证：

```bash
./scripts/qa_check.sh
cmp ~/.codex/config.toml ~/.codex/codex-model-switcher/initial-backup/config.toml
```

如果 `cmp` 没有输出，说明配置内容和初始备份一致。

