#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="inputplumber-x86_64.tar.gz"
TARGET_DIR="inputplumber"

if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

echo "Stopping inputplumber service..."
sudo systemctl stop inputplumber.service || true

if [[ ! -f $ARCHIVE ]]; then
  echo "Error: $ARCHIVE archive file not found." >&2
  exit 1
fi

rm -rf $TARGET_DIR
tar xvfz $ARCHIVE
rm $ARCHIVE

if [[ -d "$TARGET_DIR/usr" ]]; then
  echo "Deploying system files to root..."
  sudo cp -r "$TARGET_DIR/usr" /
else
  echo "Warning: No 'usr' folder found inside archive."
fi

if [[ -f .inputplumber.log ]]; then
  mv .inputplumber.log .inputplumber.log.old
fi

sudo systemctl daemon-reload

LOG_LEVEL="debug"
USE_TEE=true

case $1 in
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

echo "Starting inputplumber interactively with LOG_LEVEL=$LOG_LEVEL..."
if [ "$USE_TEE" = true ]; then
  sudo LOG_LEVEL=$LOG_LEVEL inputplumber 2>&1 | tee .inputplumber.log
else
  sudo LOG_LEVEL=$LOG_LEVEL inputplumber
fi
