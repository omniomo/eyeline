#!/bin/bash
# 现在的 Eyeline 是怎么签的（designated requirement 不该是 cdhash）。
codesign -dv --verbose=2 .build/Build/Products/Debug/Eyeline.app 2>&1 | grep -E "Identifier|Authority|Signature|TeamIdentifier|Runtime" | head
codesign -d -r- .build/Build/Products/Debug/Eyeline.app 2>&1 | tail -1
codesign --verify --deep --strict .build/Build/Products/Debug/Eyeline.app && echo "verify ok"
