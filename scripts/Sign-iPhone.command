#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
trap 'printf "\n按回车关闭。"; read -r || true' EXIT
printf 'iPhone IPA 签名\n需要已导入钥匙串的签名证书及私钥，以及包含此 iPhone 的描述文件。\n\n'
read -r -p 'IPA 文件路径：' relay_ipa
read -r -p '描述文件 .mobileprovision 路径：' relay_profile
read -r -p "输出 IPA 路径 [$HOME/Desktop/BluetoothRelay-signed.ipa]：" relay_output
relay_output="${relay_output:-$HOME/Desktop/BluetoothRelay-signed.ipa}"
./CodexRelaySetup iphone --ipa "$relay_ipa" --profile "$relay_profile" --output "$relay_output"
printf '\n请使用 Apple Configurator 安装生成的 IPA。\n'
