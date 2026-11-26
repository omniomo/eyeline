#!/bin/bash
log show --last 3m --style compact --predicate 'process == "Eyeline"' 2>/dev/null \
  | grep -iE "AVCapture(Session|MovieFileOutput|FileOutput)|startRunning|stopRunning|Recording|failureReason| E  " \
  | grep -vE "HALC_|caulk|AUHAL" | cut -c1-260 | tail -40
