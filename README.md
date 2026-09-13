# Chrome Debug Auto Allow

一个面向 macOS 的常驻小工具：当 Chrome 的远程调试连接弹出确认框时，通过辅助功能检查弹窗文案和按钮，并按配置自动点击允许。它与 `chrome-devtools-mcp`、Grok、Claude Code 等客户端解耦，只处理 Chrome UI。

> **安全提示：** 辅助功能权限可以读取并操作本机界面。允许 CDP 连接也意味着本机能够连接调试会话的程序可以读取该 Chrome profile 中的登录态、执行页面脚本并导航页面。请先阅读本文的[安全说明](#安全说明)，只在你理解并接受风险时启用。

## 适用范围

- macOS（Apple Silicon 与 Intel）；无需 Homebrew、Node.js 或 Python。
- Google Chrome、Chrome Canary 和 Chromium。
- Chrome 144 或更新版本，且用户已经在 `chrome://inspect/#remote-debugging` 手动开启远程调试。
- 只扫描辅助功能界面；不修改 Chrome、不转发 CDP 流量、不管理 MCP。

自动化项目会执行测试和编译检查，但不会替代真实 Chrome 弹窗的人工集成验证。

## 安装与授权

在仓库目录运行：

```sh
./scripts/install.sh
```

安装脚本会在 `~/Applications/Debug Auto Allow.app` 构建并 ad-hoc 签名应用，在 `~/Library/LaunchAgents/` 安装并启动 LaunchAgent。首次安装后，到“系统设置 → 隐私与安全性 → 辅助功能”中添加并启用该应用：

1. 点击添加按钮，按 `⌘⇧G` 输入 `~/Applications/Debug Auto Allow.app`。
2. 打开 `Debug Auto Allow` 的辅助功能开关。
3. 确认服务已启动：

   ```sh
   launchctl print "gui/$(id -u)/com.local.debug-auto-allow"
   ```

如果重新编译了应用，macOS 可能会要求重新授予辅助功能权限。请在辅助功能列表中移除旧条目，再添加新构建的应用。不要授权 `/usr/bin/osascript`。

## 验证与运行

前台 dry-run 会暂时停止 LaunchAgent，使用 dry-run 模式扫描并记录“将会点击”的弹窗；退出时会恢复原有服务状态：

```sh
./scripts/dry-run.sh
```

另开一个终端查看日志：

```sh
tail -f /tmp/debug-auto-allow.debug.log
```

日志不会记录完整弹窗内容。dry-run 不会点击按钮。实际点击依赖已授予辅助功能权限，并建议先在自己能观察到的测试窗口中验证。

卸载 LaunchAgent 并停止应用，但保留构建好的 `.app`：

```sh
./scripts/uninstall.sh
```

同时删除应用：

```sh
./scripts/uninstall.sh --remove-app
```

卸载不会代替用户清理 macOS 辅助功能授权；如不再使用，请自行从系统设置中移除该授权。

## 配置

可在运行安装脚本前设置环境变量；安装脚本会把配置转换为应用启动参数并写入 LaunchAgent：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `DEBUG_AUTO_ALLOW_DRY_RUN` | `0` | 设为 `1` 时只记录将点击的按钮，不执行点击 |
| `DEBUG_AUTO_ALLOW_FOCUS_STEAL` | `0` | 设为 `1` 时，只有无焦点直接点击失败后才激活 Chrome 并重试明确匹配到的允许按钮 |
| `DEBUG_AUTO_ALLOW_INTERVAL` | `0.4` | 轮询间隔，范围为 0.2–5 秒 |
| `DEBUG_AUTO_ALLOW_APP_PATH` | `~/Applications/Debug Auto Allow.app` | 自定义安装绝对路径；应用名需保持 `Debug Auto Allow.app` |

例如，启用常驻 dry-run：

```sh
DEBUG_AUTO_ALLOW_DRY_RUN=1 ./scripts/install.sh
```

改回实际点击模式：

```sh
DEBUG_AUTO_ALLOW_DRY_RUN=0 ./scripts/install.sh
```

## 自动处理的 Chrome 界面

Chrome 144 及以上版本在收到远程调试连接请求时会显示授权弹窗；连接建立后，浏览器还会显示自动化控制横幅。下图来自 Chrome 官方文档，展示了开启远程调试、确认连接和显示横幅的真实界面流程。本工具只处理其中的授权弹窗和连接后的横幅；不会替用户开启远程调试。

![Chrome DevTools 远程调试流程：连接授权弹窗与连接后的自动化控制横幅](docs/images/chrome-devtools-mcp-remote-debugging-flow.png)

*图片来源：[Chrome for Developers：Let your Coding Agent debug your browser session with Chrome DevTools MCP](https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session)，CC BY 4.0。*

### 远程调试授权弹窗

- 只识别文案同时包含远程调试关键词和授权语义的弹窗，例如提到外部应用请求控制浏览器会话、访问保存的数据或 Cookie，并前往任意网址。
- 必须找到名称精确匹配的“Allow/允许”等按钮才会点击。若授权弹窗出现在未命名的独立窗口中，还要求同时找到名称精确匹配的“Cancel/取消”按钮。
- 普通网页提示、通知或扩展权限弹窗不属于处理目标；只有“Allow/允许”按钮或只有远程调试字样都不足以触发点击。

### 自动化控制横幅

- 只处理 Chrome、Chrome Canary 或 Chromium 的 info bar 辅助功能节点；同一节点中还必须出现已知提示文案，例如“Chrome is being controlled by automated test software”或“Chrome 正受到自动测试软件的控制”。
- 必须在该节点内找到名称精确匹配的“Close/关闭”按钮（通常显示为横幅右侧的叉号）才会收起横幅。
- 不会点击“Turn off in settings/在设置中关闭”。横幅文案、info bar 标识或精确关闭按钮任一不匹配时，脚本都不会操作。

两类操作的重复触发间隔至少 3 秒。

## 与 Grok / Chrome DevTools MCP 配合

先启动并授权本工具，再在 Chrome 中手动开启远程调试。Grok 配置示例：

```toml
[mcp_servers.chrome-devtools]
command = "npx"
args = ["-y", "chrome-devtools-mcp@latest", "--autoConnect"]
```

MCP 仍直接连接正在运行的 Chrome；本工具不应包装或替代 MCP 的 `command`。Claude Code 等其他客户端也按各自方式配置 `--autoConnect` 即可。

## 安全说明

自动允许远程调试会将 Chrome 的控制权交给能够访问本机调试会话的程序。该程序可以访问当前 profile 的 Cookie 和页面数据、执行页面 JavaScript 并导航到任意 URL。辅助功能授权的系统权限范围也大于本工具的单一用途。

不建议长期对装有网银、邮箱或密码管理器登录态的日常 profile 无条件开启。更安全的替代方式是为 `chrome-devtools-mcp` 使用独立 `--userDataDir`，只在该 profile 登录开发所需的网站；这不会复用日常 Chrome 登录态，也无需自动允许日常 profile 的调试连接。

例如，将 MCP 参数改为独立 profile：

```toml
[mcp_servers.chrome-devtools]
command = "npx"
args = ["-y", "chrome-devtools-mcp@latest", "--userDataDir=/Users/<你>/Library/Application Support/Chrome DevTools MCP"]
```

本工具不会关闭 Chrome 安全机制、修改 Chrome 二进制、关闭 SIP、开放非 localhost 调试端口，或在不匹配文案时盲按键盘。

## 日志与排障

- 日志：`/tmp/debug-auto-allow.debug.log`
- 服务状态：`launchctl print "gui/$(id -u)/com.local.debug-auto-allow"`
- 监听测试：`./scripts/dry-run.sh`
- 授权失效：确认辅助功能中启用的是当前的 `Debug Auto Allow.app`；应用重新编译后可能需要移除旧条目并重新添加。
- 弹窗未被识别：确认浏览器进程受支持，并检查弹窗是否在当前 fixtures 覆盖的关键词和按钮语言中。可提交不包含个人数据的文案样例以扩展匹配规则。

## 开发验证

```sh
bash test/matcher_test.sh
bash -n scripts/install.sh scripts/uninstall.sh scripts/dry-run.sh test/matcher_test.sh
plutil -lint launchd/com.local.debug-auto-allow.plist
```

AppleScript 编译与真实 Chrome 辅助功能测试仅能在 macOS 上完成；请按 `AGENTS.md` 执行安全边界内的验证。
