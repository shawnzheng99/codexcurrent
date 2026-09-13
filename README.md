# Codex Current

> 在 MacBook 刘海或 macOS 菜单栏里，一眼查看 Codex 5 小时/每周剩余额度、重置时间和 RESET 次数。

<p align="center">
  <img src="app_icon.png" width="160" alt="Codex Current macOS Codex 额度监控应用图标">
</p>

Codex Current 是一个轻量、原生的 **Codex 用量监控 macOS 应用**。它专为想随时知道
Codex 剩余额度的 Mac 用户设计：MacBook 有刘海时贴合刘海显示，其他 Mac 则使用标准菜单栏。

它不是 OpenAI 官方产品，与 OpenAI 无隶属、赞助或背书关系。Codex 是 OpenAI 的产品名称。

## 为什么用它？

- 同时显示 Codex 5 小时和每周额度，不用反复打开其他页面。
- 显示额度重置倒计时、可用 RESET 数量与有效期。
- 任务运行时更频繁地刷新，闲置时降低刷新频率。
- 无广告、无分析 SDK、无额外账号，不要求你提供 API Key。
- 原生 SwiftUI 界面，无第三方运行时依赖。

## 安装（适合小白）

### 方式一：下载 DMG

1. 确认 Mac 已安装 **macOS 14 Sonoma 或更高版本**。
2. 安装 [Codex CLI](https://github.com/openai/codex#quickstart)，然后在“终端”运行 `codex login` 完成登录。
3. 在[Releases](https://github.com/shawnzheng99/codexcurrent/releases) 页面下载最新 `.dmg` 文件。
4. 双击 DMG，把 **Codex Current** 拖到 **Applications（应用程序）**。
5. 在“应用程序”中打开 Codex Current。它不会出现在 Dock，请查看屏幕顶部。

> 当前 Release 为 Apple Silicon (`arm64`) 构建。Intel Mac 尚未提供经验证的预编译安装包。

### 方式二：从源码运行

适合想学习 Swift，或者想先审查代码再运行的用户。请先从 Mac App Store 安装 Xcode，
并确认终端中的 `swift --version` 可以正常运行。

```sh
git clone https://github.com/shawnzheng99/codexcurrent.git
cd codexcurrent
zsh scripts/run-debug.sh
```

`run-debug.sh` 会构建并打开调试版。如果已经运行了另一个版本，请先退出，避免两个面板重叠。

## 怎么用？

- **有刘海的 MacBook**：点击刘海区域展开面板，点击外部收起。
- **无刘海的 Mac**：点击菜单栏百分比，再选择“展开面板”。
- **自动刷新**：默认开启。本地 Codex 任务运行时每 10 秒查询，闲置时每 15 分钟查询。
- **手动刷新**：可选 30 秒、1、5、10、15 或 30 分钟，设置会自动保存。

颜色会帮你快速判断状态：绿色表示余量较充足，橙色表示较低，红色表示接近用完。

## 隐私与数据访问

Codex Current 的自身代码不读取或保存 Codex 登录 Token，也没有自己的网络请求或遥测代码。它会：

1. 启动你本机已安装的 `codex app-server --stdio`，请求 `account/rateLimits/read`。
2. 在自动模式下，只读 `CODEX_HOME/thread_history_1.sqlite`（默认位于 `~/.codex/`）中的
   任务生命周期字段，用于判断任务是否正在运行。

它不请求任务标题、提示词或回答内容。不过，Codex CLI 本身可能为获取账号额度而与 OpenAI 服务通信；
这部分行为由 Codex CLI 及其登录状态决定。

## 常见问题

### 为什么打开后 Dock 里没有图标？

这是正常现象。Codex Current 是刘海/菜单栏工具，不会常驻 Dock。

### 为什么显示“需要登录 Codex CLI”？

打开“终端”，运行 `codex login`，按提示登录后回到应用重新检查。

### 为什么显示“任务状态未知”？

任务状态来自 Codex 桌面端的本地内部数据库。如果数据库不存在或结构发生变化，应用会退回较低频率刷新，
不会伪造任务状态。仅本机 Codex 桌面任务可被检测，云端、远程主机和独立 CLI 任务不在此范围。

### 会不会读取我的对话？

按当前实现，不会。源码中的 SQL 只查询任务状态、开始/结束时间和顺序字段，不查询任务内容表。

### 额度突然读取失败怎么办？

请先确认 Codex CLI 已登录并更新到新版。本项目使用的 App Server 接口可能随 Codex CLI 变化，
不能保证每个未来版本始终兼容。

## 开发与测试

```sh
swift test
zsh scripts/build-app.sh
```

`build-app.sh` 生成临时签名的本地 App，不会执行 Developer ID 签名或 Apple 公证。调试构建还可生成带示例数据的 UI 检查图：

```sh
.build/debug/CodexCurrent --render-preview
```

图片会保存到 `/tmp/codex-current-ui-qa/`。

## 维护者：生成签名 DMG

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="codex-current-notary" \
zsh scripts/release-dmg.sh
```

首次发布前，运行 `xcrun notarytool store-credentials codex-current-notary` 将公证凭据保存到 macOS 钥匙串。
不要把证书、密码、API 私钥、`.env` 文件或公证凭据提交到 Git。

## 项目结构

```text
Sources/CodexCurrent/       应用源码
Tests/CodexCurrentTests/    自动化测试
Packaging/Info.plist       macOS App 元数据
scripts/                   调试、构建和发布脚本
```

## 贡献

欢迎提交 Issue 和 Pull Request。提交代码前请先运行 `swift test`，并确保没有把本机路径、登录凭据或签名文件加入提交。

## 开源许可

本项目使用 [MIT License](LICENSE)。
