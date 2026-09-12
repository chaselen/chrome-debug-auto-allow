# 项目协作说明

## 项目目标

本项目为 macOS 上的 Chrome DevTools 远程调试确认弹窗提供本地自动允许能力。它使用 AppleScript 辅助功能读取 Chrome、Chrome Canary 和 Chromium 的界面，只在弹窗文案同时命中远程调试关键词与确认语义、且找到名称精确匹配的允许按钮时才操作。

## 安全约束

- 默认只对匹配到的“允许”按钮调用辅助功能点击；不要加入盲按 Return、自动激活 Chrome 或放宽关键词规则的默认行为。
- 只有用户明确配置 `CDP_AUTO_ALLOW_FOCUS_STEAL=1` 时，才允许启用会激活 Chrome 的点击兜底。
- 不读取或修改 Chrome profile、Cookie、CDP 端口设置，不启动 MCP，也不自动开启远程调试。
- 不要在未经用户要求时运行安装、卸载或修改辅助功能 / LaunchAgent 状态的操作。
- 新增弹窗文案和按钮别名时，同时补充正例或负例 fixture 与 matcher 测试。

## 开发与验证

- 使用 macOS 自带的 `bash`、`osascript`、`osacompile`、`codesign`、`launchctl` 和 `plutil`；不引入运行时依赖。
- 修改后运行 `bash test/matcher_test.sh`、Shell 语法检查、plist 检查，并在 macOS 上编译 AppleScript。
- 真实 Chrome 辅助功能交互需要手工集成验证；测试不得点击真实弹窗或变更当前机器的 TCC 授权。
- 面向用户的文档（尤其 `README.md`）使用简体中文。
- Git 提交使用英文 Conventional Commits 格式。
