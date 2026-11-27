#!/bin/bash
# 打一个发给别人的 Eyeline：
#   Release 编译（Apple 芯片和 Intel 都能跑）→ Developer ID 签名（hardened runtime + 时间戳）
#   → 装进 dmg（窗口里一张背景图，蓝点箭头指着「应用程序」，见 scripts/make-dmg.sh）→ 交给 Apple 公证 → 把公证票据钉在 dmg 上。
# 结果在 dist/Eyeline-<版本>.dmg。加 --publish 再发到 GitHub Release（omniomo/eyeline）。
#
# 第一次用之前（各做一次）：
#   1. 由 Apple Developer 团队的账户持有人创建「Developer ID Application」证书，并把证书和私钥放在本机钥匙串里。
#   2. 公证用的凭据存进钥匙串（会让你输入 App 专用密码，在 account.apple.com › 登录与安全 › App 专用密码 里生成）：
#      xcrun notarytool store-credentials eyeline-notary --apple-id "<Apple ID>" --team-id 88D7C437XC
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=88D7C437XC
PROFILE=${NOTARY_PROFILE:-eyeline-notary}
REPO=${RELEASE_REPO:-omniomo/eyeline}
VERSION=$(awk -F '"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)
BUILD=.build/release
APP=$BUILD/Build/Products/Release/Eyeline.app
DMG=dist/Eyeline-$VERSION.dmg

step() { printf '\n▶ %s\n' "$*"; }

step "检查证书"
IDENTITY=$(security find-identity -v -p codesigning | awk -F '"' -v team="$TEAM" '
  $2 ~ /^Developer ID Application: / && $2 ~ ("\\(" team "\\)$") && !found { print $2; found = 1 }
')
if [ -z "$IDENTITY" ]; then
  echo "钥匙串里没有 Developer ID Application 证书（团队 ${TEAM}）。先按文件开头第 1 步导入。"; exit 1
fi
echo "$IDENTITY"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
  echo "无法使用公证凭据「${PROFILE}」，请检查上方的 Apple 错误。"; exit 1
fi

step "编译 ${VERSION}（Release，arm64 + x86_64）"
mkdir -p .dev
xcodegen generate --quiet
xcodebuild -project Eyeline.xcodeproj -scheme Eyeline -configuration Release -derivedDataPath "$BUILD" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=$TEAM \
  OTHER_CODE_SIGN_FLAGS="--timestamp --requirements $PWD/tools/eyeline.req" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build > .dev/release-xcodebuild.log 2>&1 || { tail -n 40 .dev/release-xcodebuild.log; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
ENTITLEMENTS=$(codesign -d --entitlements - "$APP")
if [[ "$ENTITLEMENTS" == *get-task-allow* ]]; then
  echo "Release 版不该带 get-task-allow"; exit 1
fi
lipo "$APP/Contents/MacOS/Eyeline" -verify_arch arm64 x86_64
lipo -archs "$APP/Contents/MacOS/Eyeline"

step "装进 dmg"
mkdir -p dist
WORK=$(mktemp -d dist/.eyeline-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STAGE=$WORK/stage
IMAGE=$WORK/$(basename "$DMG")
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
bash scripts/make-dmg.sh "$STAGE/Eyeline.app" "$IMAGE"
codesign --sign "$IDENTITY" --timestamp "$IMAGE"

step "公证（一般几分钟）"
if ! xcrun notarytool submit "$IMAGE" --keychain-profile "$PROFILE" --wait | tee .dev/release-notary.log \
  || ! grep -qE '^[[:space:]]*status: Accepted[[:space:]]*$' .dev/release-notary.log; then
  id=$(awk '/^[[:space:]]*id:/ { print $2; exit }' .dev/release-notary.log)
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE"
  fi
  exit 1
fi
xcrun stapler staple "$IMAGE"
xcrun stapler validate "$IMAGE"
spctl --assess --type open --context context:primary-signature --verbose=2 "$IMAGE"
mv -f "$IMAGE" "$DMG"
shasum -a 256 "$DMG"
ls -lh "$DMG"

if [ "${1:-}" = "--publish" ]; then
  step "发到 GitHub Release（$REPO v$VERSION）"
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "Eyeline $VERSION" --notes "macOS 13 及以上，Apple 芯片和 Intel 都能用。下载 dmg，把 Eyeline 拖进「应用程序」。"
fi
