#!/usr/bin/env bash
set -euo pipefail

# Get the absolute folder directory where this script is located
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

echo "🔗 Overwriting and setting up SteamOS utility symlinks..."

# Iterate through every file in the project folder
for filepath in "$REPO_DIR"/*; do
  filename="$(basename "$filepath")"

  # Skip directories, hidden files, markdown files, and this script itself
  if [[ -d "$filepath" ]] || [[ "$filename" == .* ]] || [[ "$filename" == *.md ]] || [[ "$filename" == "$SCRIPT_NAME" ]]; then
    continue
  fi

  # Ensure the target repository script is executable before linking
  chmod +x "$filepath"

  TARGET_LINK="$HOME/$filename"

  # Remove existing files, directories, or broken symlinks to prevent deployment failure
  if [[ -L "$TARGET_LINK" ]] || [[ -e "$TARGET_LINK" ]]; then
    rm -rf "$TARGET_LINK"
  fi

  # Force create the symlink
  ln -sf "$filepath" "$TARGET_LINK"
  echo "🔄 Replaced: ~/$filename -> $filename"
done

echo "🎉 All repository scripts successfully linked to your home directory."
