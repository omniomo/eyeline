#!/bin/bash
# Icon Composer 自带的 ictool：先看看怎么用。
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ls -la "$IC" || find /Applications/Xcode.app -name ictool -maxdepth 8 2>/dev/null
"$IC" --help 2>&1 | head -60
"$IC" 2>&1 | head -20
