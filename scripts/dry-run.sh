#!/bin/bash
set -euo pipefail

LABEL="com.local.debug-auto-allow"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_PATH="${DEBUG_AUTO_ALLOW_APP_PATH:-$HOME/Applications/Debug Auto Allow.app}"
INTERVAL="${DEBUG_AUTO_ALLOW_INTERVAL:-0.4}"
DOMAIN="gui/$(/usr/bin/id -u)"
SERVICE_TARGET="$DOMAIN/$LABEL"
RESTORE_AGENT=0
DRY_RUN_STARTED=0

fail() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

stop_app() {
	/usr/bin/pkill -TERM -x DebugAutoAllow >/dev/null 2>&1 || true
	local attempt=0
	while /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1 && [[ "$attempt" -lt 20 ]]; do
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	! /usr/bin/pgrep -x DebugAutoAllow >/dev/null 2>&1
}

if [[ -z "${DEBUG_AUTO_ALLOW_APP_PATH:-}" && -f "$PLIST_PATH" ]]; then
	CONFIGURED_APP_PATH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:6' "$PLIST_PATH" 2>/dev/null || true)"
	if [[ "$CONFIGURED_APP_PATH" == /*.app ]]; then APP_PATH="$CONFIGURED_APP_PATH"; fi
fi
if [[ -z "${DEBUG_AUTO_ALLOW_INTERVAL:-}" && -f "$PLIST_PATH" ]]; then
	CONFIGURED_INTERVAL="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:9' "$PLIST_PATH" 2>/dev/null || true)"
	if [[ -n "$CONFIGURED_INTERVAL" ]]; then INTERVAL="$CONFIGURED_INTERVAL"; fi
fi
[[ -d "$APP_PATH" ]] || fail "找不到应用，请先运行 scripts/install.sh：$APP_PATH"
[[ -x "$APP_PATH/Contents/MacOS/DebugAutoAllow" ]] || fail "应用缺少可执行文件，请重新安装：$APP_PATH"
[[ "$INTERVAL" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || fail "DEBUG_AUTO_ALLOW_INTERVAL 必须是数字。"
/usr/bin/awk -v interval="$INTERVAL" 'BEGIN { exit !(interval >= 0.2 && interval <= 5) }' || fail "DEBUG_AUTO_ALLOW_INTERVAL 必须在 0.2–5 秒之间。"

restore_agent() {
	local exit_code=$?
	trap - EXIT HUP INT TERM
	if [[ "$RESTORE_AGENT" -eq 1 ]]; then
		if ! stop_app; then
			printf '\n错误：dry-run 应用仍在运行，未能安全恢复 LaunchAgent。\n' >&2
			exit_code=1
		elif /bin/launchctl bootstrap "$DOMAIN" "$PLIST_PATH"; then
			printf '\n已恢复原 LaunchAgent。\n'
		else
			printf '\n错误：无法自动恢复 LaunchAgent，请运行 scripts/install.sh。\n' >&2
			exit_code=1
		fi
	elif [[ "$DRY_RUN_STARTED" -eq 1 ]] && ! stop_app; then
		printf '\n错误：dry-run 应用仍在运行，请手动运行 scripts/uninstall.sh 停止。\n' >&2
		exit_code=1
	fi
	exit "$exit_code"
}

trap restore_agent EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
	[[ -f "$PLIST_PATH" ]] || fail "服务已加载但找不到 plist：$PLIST_PATH"
	RESTORE_AGENT=1
	/bin/launchctl bootout "$DOMAIN" "$PLIST_PATH"
fi
stop_app || fail "无法停止此前运行的 Debug Auto Allow。"

printf '前台 dry-run 已启动。日志见 /tmp/debug-auto-allow.debug.log；按 Ctrl-C 结束。\n'
DRY_RUN_STARTED=1
/usr/bin/open -n -W --stdout /tmp/debug-auto-allow.debug.log --stderr /tmp/debug-auto-allow.debug.log "$APP_PATH" --args --dry-run --interval "$INTERVAL"
