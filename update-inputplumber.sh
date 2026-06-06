#!/usr/bin/env bash
# Exit immediately if a command fails, or if an unassigned variable is used
set -euo pipefail

ARCHIVE="inputplumber-x86_64.tar.gz"
TARGET_DIR="inputplumber"

# Check if the SteamOS filesystem is read-only and exit if enabled
if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

# 1. Stop service safely
echo "Stopping inputplumber service..."
sudo systemctl stop inputplumber.service || true

# 2. Extract securely
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Error: $ARCHIVE archive file not found." >&2
  exit 1
fi

rm -rf "$TARGET_DIR"
tar xvfz "$ARCHIVE"
rm "$ARCHIVE"

# 3. Deploy system files safely
if [[ -d "$TARGET_DIR/usr" ]]; then
  echo "Deploying system files to root..."
  sudo cp -r "$TARGET_DIR/usr" /
else
  echo "Warning: No 'usr' folder found inside archive."
fi

# 4. Safely shift log history without throwing missing-file errors
if [[ -f .inputplumber.log ]]; then
  mv .inputplumber.log .inputplumber.log.old
fi

sudo systemctl daemon-reload

# 5. Determine runtime logging level
LOG_LEVEL="debug"
USE_TEE=true

case "${1:-}" in
trace)
  LOG_LEVEL="trace"
  ;;
none)
  echo "Files updated. Service left stopped."
  exit 0
  ;;
no-log)
  USE_TEE=false
  ;;
*)
  LOG_LEVEL="debug"
  ;;
esac

# 6. Execute binary directly with proper logging state
echo "Starting inputplumber interactively with LOG_LEVEL=$LOG_LEVEL..."
if [ "$USE_TEE" = true ]; then
  sudo LOG_LEVEL="$LOG_LEVEL" inputplumber 2>&1 | tee .inputplumber.log
else
  sudo LOG_LEVEL="$LOG_LEVEL" inputplumber
fi
