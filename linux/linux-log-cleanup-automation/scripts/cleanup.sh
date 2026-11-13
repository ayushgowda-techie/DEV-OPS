#!/bin/bash

# cleanup.sh - delete rotated logs (*.old) and print one summary line per run
LOG_DIR="/var/log/escbash-app"

# Count the rotated logs first (live app.log never matches *.old)
count=$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.old' | wc -l)

# Delete them
find "$LOG_DIR" -maxdepth 1 -type f -name '*.old' -delete

# Exactly one line of output per run
echo "$(date '+%Y-%m-%d %H:%M:%S') cleanup: removed $count old log file(s) from $LOG_DIR"
