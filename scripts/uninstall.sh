#!/bin/bash
set -euo pipefail

LABEL="com.local.debug-auto-allow"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/Debug Auto Allow"
REMOVE_APP=0
APP_PATH="${DEBUG_AUTO_ALLOW_APP_PATH:-$HOME/Applications/Debug Auto Allow.app}"

fail() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

if [[ "$#" -gt 1 ]]; then fail "用法：$0 [--remove-app]"; fi
if [[ "$#" -eq 1 ]]; then
	[[ "$1" == "--remove-app" ]] || fail "未知选项：$1（用法：$0 [--remove-app]）"
	REMOVE_APP=1
fi

if [[ -z "${DEBUG_AUTO_ALLOW_APP_PATH:-}" && -f "$PLIST_PATH" ]]; then
	CONFIGURED_APP_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:6' "$PLIST_PATH" 2>/dev/null || true)"
	if [[ "$CONFIGURED_APP_PATH" == /*.app ]]; then APP_PATH="$CONFIGURED_APP_PATH"; fi
fi

DOMAIN="gui/$(/usr/bin/id -u)"
SERVICE_TARGET="$DOMAIN/$LABEL"
if [[ -f "$PLIST_PATH" ]]; then
	/bin/launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
	/bin/rm -f "$PLIST_PATH"
fi
/bin/launchctl disable "$SERVICE_TARGET" >/dev/null 2>&1 || true

/usr/bin/pkill -TERM -x DebugAutoAllow >/dev/null 2>&1 || true
attempt=0
while /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1 && [[ "$attempt" -lt 20 ]]; do
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
if /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1; then
	fail "Debug Auto Allow 仍在运行，未继续清理。"
fi

if [[ "$REMOVE_APP" -eq 1 ]]; then
	case "$APP_PATH" in
		/*/Debug\ Auto\ Allow.app) ;;
		*) fail "拒绝删除非预期的应用路径：$APP_PATH" ;;
	esac
	/bin/rm -rf "$APP_PATH"
	/bin/rm -rf "$STATE_DIR"
	printf '已卸载 LaunchAgent 并删除应用：%s\n' "$APP_PATH"
else
	printf '已卸载 LaunchAgent；应用保留在：%s\n' "$APP_PATH"
	printf '应用构建记录也已保留，重新安装时可复用相同构建。\n'
	printf '如需同时删除应用，请再次运行：%s --remove-app\n' "$0"
fi
printf '如不再使用，请在系统设置的“隐私与安全性 → 辅助功能”中手动移除该应用授权。\n'
