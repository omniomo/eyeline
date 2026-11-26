#!/bin/bash
# 语音识别、麦克风相关的日志。
log show --last ${MINUTES:-6}m --style compact --predicate 'process == "Eyeline"' 2>/dev/null \
  | grep -iE "speech|SFSpeech|recogni|dictation|AVAudioEngine|kAFAssistant|TCC|1110|1101|siri|assistant|inputNode|Eyeline ribbon" \
  | grep -vE "HALC_|caulk|AUHAL|vfx" | cut -c1-240 | tail -50
echo "--- takes"; ls -la ~/Movies/Eyeline
