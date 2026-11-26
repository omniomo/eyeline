#!/bin/bash
# 这台 Mac 上所有的 Eyeline（同一个 bundle id），各自怎么签的。
mdfind "kMDItemCFBundleIdentifier == 'com.omniomo.eyeline'" 2>/dev/null | while read -r app; do
  echo "$app :: $(codesign -dv "$app" 2>&1 | grep -E '^(Signature|Authority)=' | head -1)"
done
ls -d /Applications/Eyeline*.app 2>/dev/null
