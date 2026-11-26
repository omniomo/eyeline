#!/bin/bash
# 清掉系统里记着的旧 Eyeline 权限（以前 ad-hoc 签名的那些对不上现在的签名），下次用到时重新给一次。
for s in ScreenCapture Camera Microphone SpeechRecognition AppleEvents; do
  tccutil reset $s com.omniomo.eyeline 2>&1 | sed "s/^/$s: /"
done
