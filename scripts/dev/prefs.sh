#!/bin/bash
defaults read com.omniomo.eyeline 2>&1 | grep -vE "NSWindow|NSSplitView|NSNavPanel" | head -30
