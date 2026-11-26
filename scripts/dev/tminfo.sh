#!/bin/bash
tmutil destinationinfo 2>&1 | grep -vE "^ID|^=" | head -20
tmutil latestbackup 2>&1 | tail -2
