#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
trap 'printf "\n按回车关闭。"; read -r || true' EXIT
printf 'Codex Relay 安装\n\n请先退出正在运行的 Bluetooth Codex。\n'
relay_source="$HOME/.codex-2"
if [[ ! -f "$relay_source/config.toml" ]]; then relay_source="$HOME/.codex"; fi
read -r -p "API 配置目录 [$relay_source]: " relay_input
relay_source="${relay_input:-$relay_source}"
if [[ "$relay_source" == '~/'* ]]; then relay_source="$HOME/${relay_source#\~/}"; fi
relay_apps="$HOME/Applications"
if [[ -f '/Applications/Bluetooth Codex.app/Contents/Resources/managed.txt' && -w /Applications ]]; then
  relay_apps=/Applications
fi
printf '\n安装到 %s\n' "$relay_apps"
./CodexRelaySetup --source "$relay_source" --apps "$relay_apps" --skip-build
printf '\n安装完成。请打开 Codex 3，配对手机并开始转发。\n'
/usr/bin/open "$relay_apps"
