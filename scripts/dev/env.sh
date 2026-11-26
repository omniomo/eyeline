#!/bin/bash
sw_vers
uname -m
xcode-select -p
xcodebuild -version
swift --version
which xcodegen && xcodegen --version
system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type|Main Display|Built-in|Retina" | head -20
say -v '?' | grep -E "zh_CN|zh_TW|en_US" | head -20
