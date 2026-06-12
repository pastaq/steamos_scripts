#!/usr/bin/env bash
set -euo pipefail

if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

VER=$1

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

if [[ -f oldver ]]; then
  OLD_VER="$(cat oldver)"

  if [[ -n $OLD_VER ]]; then
    echo "Removing old kernel version $OLD_VER"
    sudo rm -rf "/boot/*${OLD_VER}*" "/lib/modules/*${OLD_VER}*"
  fi
fi

sudo tar -C / --zstd -xvf $ARCHIVE --keep-directory-symlink
rm $ARCHIVE

sudo mkinitcpio -k $VER -g /boot/initramfs-${VER}.img
sudo update-grub
sudo sync

echo "$VER" >oldver
echo "Successfully installed kernel version $VER"
