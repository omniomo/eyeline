#!/bin/bash
# 打包、签名、公证（不发布）。完整输出在 .dev/release.log。
cd "$(dirname "$0")/../.."
bash scripts/release.sh
