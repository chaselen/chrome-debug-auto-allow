# 项目协作说明

## 项目目标

本项目为 macOS 上的 Chrome DevTools 远程调试确认弹窗与自动化控制横幅提供本地自动处理能力。

- 运行时：Swift + 原生 Accessibility API，按进程 PID 扫描 Google Chrome、Chrome Canary、Chromium（含独立 `--userDataDir` 多实例）。
- 授权弹窗：文案须同时命中远程调试关键词与确认语义，且找到名称精确匹配的允许按钮后才点击。
- 自动化横幅：须命中已知 info bar 标识、已知横幅文案，以及名称精确匹配的关闭按钮后才点击。
- 不替用户开启远程调试，不管理 MCP，不修改 Chrome。

源码入口：`scripts/debug-auto-allow.swift`。安装入口：`scripts/install.sh`。

## 安全约束

- 默认只点击匹配到的“允许 / Allow”或横幅“关闭 / Close”；不要加入盲按 Return、默认抢焦点或放宽关键词的行为。
- 只有用户明确配置 `DEBUG_AUTO_ALLOW_FOCUS_STEAL=1` 时，才允许启用激活 Chrome 的点击兜底。
- 不读取或修改 Chrome profile、Cookie、CDP 端口；不启动 MCP；不自动开启远程调试。
- 未经用户明确要求，不要运行安装、卸载，或修改辅助功能 / LaunchAgent 状态。
- 新增或调整弹窗文案、按钮别名时，只改 `scripts/debug-auto-allow.swift` 中的 `Matchers`，并按下文完成两种 Profile 场景的验证。

## 技术约束

- 仅使用 macOS 自带工具：`bash`、`swiftc`、`codesign`、`launchctl`、`plutil`；不引入运行时依赖（无 Homebrew / pip / npm 运行时）。
- 安装需要 Xcode Command Line Tools（提供 `swiftc`），不必安装完整 Xcode App。
- 面向用户的文档（尤其 `README.md`）使用简体中文。
- Git 提交使用英文 Conventional Commits 格式。

## 修改后的静态检查

代码或脚本变更后，至少运行：

```sh
bash -n scripts/install.sh scripts/uninstall.sh scripts/dry-run.sh
plutil -lint launchd/com.local.debug-auto-allow.plist
swiftc -O -o /tmp/DebugAutoAllowCheck scripts/debug-auto-allow.swift \
  -framework AppKit -framework ApplicationServices
```

可选：用编译产物快速核对匹配逻辑（不点击真实 UI）：

```sh
BIN=/tmp/DebugAutoAllowCheck
"$BIN" --match 'Google Chrome: Allow remote debugging? Another program is trying to connect. This external app may access saved data, cookies and site data. Allow Cancel'
# 期望输出：match
"$BIN" --match 'This page wants to show notifications'
# 期望输出：no-match
"$BIN" --allow-button '允许'
# 期望输出：match
"$BIN" --allow-button 'Bookmark'
# 期望输出：no-match
```

## 集成测试（必做，两种 Profile 场景）

真实 Chrome 辅助功能交互只能在 macOS 上手测。**默认用 dry-run**，避免误点；只有用户明确要求验证真实点击时，才用正式安装模式。

### 共用前置

1. 已安装并授权本工具（或本次任务用户已同意安装 / 重新授权）。
2. 日志中出现 `ax-trusted=true`：

   ```sh
   tail -f /tmp/debug-auto-allow.debug.log
   ```

3. 建议先开 dry-run，确认会匹配再考虑真实点击：

   ```sh
   ./scripts/dry-run.sh
   ```

4. 重新编译后若授权失效：按 README 从辅助功能列表移除旧 `Debug Auto Allow`，再添加 `~/Applications/Debug Auto Allow.app`。

### 场景 A：日常 Profile（不使用新 Profile）

覆盖「已有 Chrome + `chrome://inspect` 远程调试 + MCP/--autoConnect」路径。

1. 正常启动日常 Google Chrome（不要额外传 `--user-data-dir`）。
2. 打开 `chrome://inspect/#remote-debugging`，按界面启用远程调试（若尚未启用）。
3. 用会触发授权弹窗的客户端连接，例如配置了 `--autoConnect` 的 `chrome-devtools-mcp`，或等价的 CDP 连接请求。
4. **期望 — 授权弹窗：**
   - dry-run：日志出现 `Matched … would click Allow (dry-run)`
   - 正式模式：日志出现 `Clicked Allow …`，弹窗消失
5. **期望 — 自动化横幅：**
   - 连接成功后地址栏下方出现「Chrome 正受到自动测试软件的控制」或英文等价文案
   - dry-run：`Matched automation info bar … would click its Close button (dry-run)`
   - 正式模式：`Dismissed automation info bar …`，横幅收起
6. **负向抽查：** 普通网页 `alert`、扩展权限弹窗等不应被点击；日志不应出现对应的 Allow / Dismissed 记录。

### 场景 B：独立新 Profile（`--userDataDir` / `--user-data-dir`）

覆盖「单独用户数据目录启动的第二 Chrome 进程」路径。这是相对日常 Profile 更容易回归的场景：第二个进程对 System Events 不可见，必须走原生 AX。

1. 保持日常 Chrome 可继续运行（用于确认多实例并存）。
2. 用临时目录启动独立实例，例如：

   ```sh
   TMP_PROFILE="$(mktemp -d /tmp/debug-auto-allow-profile.XXXXXX)"
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --user-data-dir="$TMP_PROFILE" \
     --enable-automation \
     --no-first-run \
     --no-default-browser-check \
     about:blank
   ```

   也可用 MCP 的 `--userDataDir=…` 拉起的窗口代替上述命令。
3. **期望 — 自动化横幅：**
   - 新窗口出现「Chrome 正受到自动测试软件的控制」（或英文等价文案）
   - dry-run / 正式模式的日志期望同场景 A 第 5 步
   - 即使日常 Chrome 同时开着，新 Profile 窗口上的横幅也必须被处理到
4. 若该独立实例还会弹出远程调试授权框，按场景 A 第 4 步同样验证。
5. 测完可关闭该 Chrome 窗口，并删除临时目录：`rm -rf "$TMP_PROFILE"`。

### 通过标准

| 检查项 | 场景 A | 场景 B |
| --- | --- | --- |
| 日志 `ax-trusted=true` | 需要 | 需要 |
| 授权弹窗被匹配 / 点击（若出现） | 需要 | 若出现则需要 |
| 自动化横幅被匹配 / 关闭 | 需要 | **需要（重点）** |
| 日常 Chrome 与独立实例并存时仍能处理独立实例 | — | **需要** |
| 非目标弹窗不被误点 | 需要 | 需要 |

未完成上述两种场景验证时，不要声称「集成测试已通过」或「多实例问题已修复」。

### 测试时不要做的事

- 不要在未经用户同意时改 TCC、安装/卸载 LaunchAgent，或点击用户日常浏览器里未约定的真实弹窗。
- 不要为了“测过”而放宽 `Matchers` 或加入盲按键盘。
- 不要用修改 Chrome 二进制、关闭安全机制等方式消除横幅来代替本工具验证。

## 安装与集成验证入口

需要安装或真实点击验证时，先读：

- [README 安装与授权](README.md#安装与授权)
- [README 日志与排障](README.md#日志与排障)

用户明确要求安装时再执行 `./scripts/install.sh`。重新编译后提醒用户检查辅助功能授权。
