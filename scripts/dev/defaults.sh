#!/bin/bash
# 改 Eyeline 的一项设置：.dev/defaults 里写「键 类型 值」，比如 `mode -string steady`。
cd "$(dirname "$0")/../.."
read -r key type value < .dev/defaults
defaults write com.omniomo.eyeline "$key" "$type" "$value" && defaults read com.omniomo.eyeline "$key"
