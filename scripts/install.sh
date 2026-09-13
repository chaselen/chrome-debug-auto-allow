#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_PATH="$ROOT_DIR/scripts/debug-auto-allow.swift"
PLIST_TEMPLATE="$ROOT_DIR/launchd/com.local.debug-auto-allow.plist"
LABEL="com.local.debug-auto-allow"
APP_PATH="${DEBUG_AUTO_ALLOW_APP_PATH:-$HOME/Applications/Debug Auto Allow.app}"
STATE_DIR="$HOME/Library/Application Support/Debug Auto Allow"
HASH_PATH="$STATE_DIR/.script-hash"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
DOMAIN="gui/$(/usr/bin/id -u)"
SERVICE_TARGET="$DOMAIN/$LABEL"
DRY_RUN="${DEBUG_AUTO_ALLOW_DRY_RUN:-0}"
FOCUS_STEAL="${DEBUG_AUTO_ALLOW_FOCUS_STEAL:-0}"
INTERVAL="${DEBUG_AUTO_ALLOW_INTERVAL:-0.4}"

fail() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "缺少系统命令：$1"
}

case "$(/usr/bin/uname -s)" in
	Darwin) ;;
	*) fail "本项目只支持 macOS。"
esac

for required_command in swiftc codesign open launchctl plutil shasum awk; do
	require_command "$required_command"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "找不到 /usr/libexec/PlistBuddy。"
[[ -f "$SWIFT_PATH" ]] || fail "找不到 Swift 源码：$SWIFT_PATH"
[[ -f "$PLIST_TEMPLATE" ]] || fail "找不到 LaunchAgent 模板：$PLIST_TEMPLATE"

case "$APP_PATH" in
	/*/Debug\ Auto\ Allow.app) ;;
	*) fail "应用路径必须是以 / 开头、以 Debug Auto Allow.app 结尾的绝对路径：$APP_PATH"
esac
case "$APP_PATH" in
	*"'"*) fail "应用路径不能包含单引号：$APP_PATH" ;;
esac
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || fail "DEBUG_AUTO_ALLOW_DRY_RUN 只能是 0 或 1。"
[[ "$FOCUS_STEAL" == 0 || "$FOCUS_STEAL" == 1 ]] || fail "DEBUG_AUTO_ALLOW_FOCUS_STEAL 只能是 0 或 1。"
[[ "$INTERVAL" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || fail "DEBUG_AUTO_ALLOW_INTERVAL 必须是数字。"
/usr/bin/awk -v interval="$INTERVAL" 'BEGIN { exit !(interval >= 0.2 && interval <= 5) }' || fail "DEBUG_AUTO_ALLOW_INTERVAL 必须在 0.2–5 秒之间。"

APP_PARENT="$(/usr/bin/dirname "$APP_PATH")"
BUILD_APP_PATH="${APP_PATH%.app}.build.$$.app"
BUILD_APP_INFO="$BUILD_APP_PATH/Contents/Info.plist"
BUILD_APP_EXECUTABLE="$BUILD_APP_PATH/Contents/MacOS/DebugAutoAllow"
PLIST_TMP=""
AGENT_WAS_LOADED=0

cleanup_install() {
	local exit_code=$?
	trap - EXIT
	if [[ -n "$PLIST_TMP" && -f "$PLIST_TMP" ]]; then /bin/rm -f "$PLIST_TMP"; fi
	if [[ -f "$HASH_PATH.tmp" ]]; then /bin/rm -f "$HASH_PATH.tmp"; fi
	if [[ -d "$BUILD_APP_PATH" ]]; then /bin/rm -rf "$BUILD_APP_PATH"; fi
	if [[ "$exit_code" -ne 0 && "$AGENT_WAS_LOADED" -eq 1 && -f "$PLIST_PATH" ]]; then
		if ! /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
			/bin/launchctl bootstrap "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
		fi
	fi
	exit "$exit_code"
}
trap cleanup_install EXIT

stop_app() {
	/usr/bin/pkill -TERM -x DebugAutoAllow >/dev/null 2>&1 || true
	local attempt=0
	while /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1 && [[ "$attempt" -lt 20 ]]; do
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	if /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1; then
		fail "旧版 Debug Auto Allow 仍在运行，已停止安装以避免同时运行两个版本。"
	fi
}

SCRIPT_HASH="$(/usr/bin/shasum -a 256 "$SWIFT_PATH" | /usr/bin/awk '{ print $1 }')"
OLD_SCRIPT_HASH=""
if [[ -f "$HASH_PATH" ]]; then OLD_SCRIPT_HASH="$(/bin/cat "$HASH_PATH")"; fi
APP_REBUILT=0
if [[ ! -d "$APP_PATH" || "$SCRIPT_HASH" != "$OLD_SCRIPT_HASH" ]] \
	|| [[ ! -x "$APP_PATH/Contents/MacOS/DebugAutoAllow" ]] \
	|| ! /usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
	/bin/mkdir -p "$APP_PARENT"
	/bin/rm -rf "$BUILD_APP_PATH"
	/bin/mkdir -p "$BUILD_APP_PATH/Contents/MacOS" "$BUILD_APP_PATH/Contents/Resources"

	/usr/bin/swiftc -O -o "$BUILD_APP_EXECUTABLE" "$SWIFT_PATH" \
		-framework AppKit -framework ApplicationServices
	[[ -x "$BUILD_APP_EXECUTABLE" ]] || fail "swiftc 未生成预期的可执行文件。"

	/usr/bin/plutil -create xml1 "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DebugAutoAllow' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.local.DebugAutoAllow' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Debug Auto Allow' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$BUILD_APP_INFO"
	/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$BUILD_APP_INFO"

	/usr/bin/codesign --force --deep --sign - "$BUILD_APP_PATH"
	/usr/bin/codesign --verify --deep --strict "$BUILD_APP_PATH"
	APP_REBUILT=1
fi

if [[ "$APP_REBUILT" -eq 1 ]]; then
	printf '检测到源码更新或应用无效，已准备经过签名验证的新构建。\n'
else
	printf '源码未变化，复用现有应用：%s\n' "$APP_PATH"
fi

/bin/mkdir -p "$PLIST_DIR"
PLIST_TMP="$(/usr/bin/mktemp "$PLIST_DIR/.${LABEL}.XXXXXX")"
/bin/cp "$PLIST_TEMPLATE" "$PLIST_TMP"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:6 '$APP_PATH'" "$PLIST_TMP"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:9 $INTERVAL" "$PLIST_TMP"

NEXT_ARGUMENT_INDEX=10
if [[ "$DRY_RUN" == 1 ]]; then
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:$NEXT_ARGUMENT_INDEX string --dry-run" "$PLIST_TMP"
	NEXT_ARGUMENT_INDEX=$((NEXT_ARGUMENT_INDEX + 1))
fi
if [[ "$FOCUS_STEAL" == 1 ]]; then
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:$NEXT_ARGUMENT_INDEX string --allow-focus-steal" "$PLIST_TMP"
fi

/usr/bin/plutil -lint "$PLIST_TMP"
/bin/chmod 644 "$PLIST_TMP"

if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then AGENT_WAS_LOADED=1; fi
if [[ "$AGENT_WAS_LOADED" -eq 1 ]]; then
	/bin/launchctl bootout "$SERVICE_TARGET" >/dev/null 2>&1 || true
elif [[ -f "$PLIST_PATH" ]]; then
	/bin/launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
fi
stop_app

if [[ "$APP_REBUILT" -eq 1 ]]; then
	/bin/rm -rf "$APP_PATH"
	/bin/mv "$BUILD_APP_PATH" "$APP_PATH"
	/bin/mkdir -p "$STATE_DIR"
	printf '%s\n' "$SCRIPT_HASH" > "$HASH_PATH.tmp"
	/bin/mv -f "$HASH_PATH.tmp" "$HASH_PATH"
	printf '已构建并签名：%s\n' "$APP_PATH"
fi

/bin/mv -f "$PLIST_TMP" "$PLIST_PATH"

/bin/launchctl enable "$SERVICE_TARGET"
/bin/launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
/bin/launchctl print "$SERVICE_TARGET" >/dev/null

printf 'LaunchAgent 已启动：%s\n' "$SERVICE_TARGET"
printf '日志路径：/tmp/debug-auto-allow.debug.log\n'
if [[ "$DRY_RUN" == 1 ]]; then
	printf '当前为常驻 dry-run；再次以 DEBUG_AUTO_ALLOW_DRY_RUN=0 运行安装脚本即可切回实际点击。\n'
fi

if [[ "$APP_REBUILT" -eq 1 ]]; then
	printf '\n'
	printf '======= 需要重新授予辅助功能权限 =======\n'
	printf '应用刚重新编译，代码签名已变化，旧授权通常会失效。\n'
	printf '请按下列步骤操作：\n'
	printf '  1. 打开「系统设置 → 隐私与安全性 → 辅助功能」\n'
	printf '  2. 若列表中已有 Debug Auto Allow，先移除旧条目\n'
	printf '  3. 点击添加，按 ⌘⇧G，输入：\n'
	printf '     %s\n' "$APP_PATH"
	printf '  4. 打开 Debug Auto Allow 的开关\n'
	printf '  5. 用下面命令确认日志出现 ax-trusted=true：\n'
	printf '     tail -f /tmp/debug-auto-allow.debug.log\n'
	printf '======================================\n'
else
	printf '\n若弹窗或横幅无反应，请确认辅助功能已启用本应用，且日志中为 ax-trusted=true。\n'
fi
