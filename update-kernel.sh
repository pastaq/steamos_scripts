#!/usr/bin/env bash
set -euo pipefail # Exit instantly on error, unassigned variables, or pipe failures

# Check if the SteamOS filesystem is read-only and exit if enabled
if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

VER="${1:-}"

# 1. Validate input
if [[ -z "$VER" ]]; then
  echo "Error: The kernel version is empty or not provided." >&2
  exit 1
fi

ARCHIVE="linux-${VER}-x86.tar.zst"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Error: $ARCHIVE not present." >&2
  exit 1
fi

echo "Installing kernel version $VER"

# 2. Safely remove old kernel if present
if [[ -f oldver ]]; then
  OLD_VER=$(cat oldver)

  # Ensure OLD_VER is absolutely not empty before running rm
  if [[ -n "$OLD_VER" ]]; then
    echo "Removing old kernel version $OLD_VER"
    # Wrap wildcards securely inside quotes to prevent dangerous expansion splits
    sudo rm -rf "/boot/"*"${OLD_VER}"* "/lib/modules/"*"${OLD_VER}"*
  fi
fi

# 3. Extract and configure
# Target specifically the archive file instead of a global wildcard 'rm linux-*'
sudo tar -C / --zstd -xvf "$ARCHIVE" --keep-directory-symlink
rm "$ARCHIVE"

sudo mkinitcpio -k "$VER" -g "/boot/initramfs-${VER}.img"
sudo update-grub
sudo sync

# 4. Save state
echo "$VER" >oldver
echo "Successfully installed kernel version $VER"
