#!/bin/bash

# Check if the SteamOS filesystem is read-only and exit if enabled
if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

TARGET_FILE="/etc/grub.d/00_header"

# Define the two configuration sub-blocks exactly as required
DEFAULT_BLOCK='## start header steamenv sub block
insmod steamenv
steamenv_loader_mode=${GRUB_GFXMODE}
steamenv_kernel_mode=${GRUB_GFXPAYLOAD_LINUX:-keep}
steamenv_quiet="loglevel=3 splash quiet plymouth.ignore-serial-consoles fbcon=vc:4-6"
steamenv_noisy="loglevel=5 sysrq_always_enabled splash=verbose fbcon=nodefer"
steamenv_verbosity=""
timeout=0
timeout_style=menu
steamenv_init
## end steamenv header sub block'

MODIFIED_BLOCK='## start header steamenv sub block
insmod steamenv
steamenv_loader_mode=${GRUB_GFXMODE}
steamenv_kernel_mode=${GRUB_GFXPAYLOAD_LINUX:-keep}
steamenv_quiet="loglevel=5 sysrq_always_enabled earlycon=efifb"
steamenv_noisy="loglevel=5 sysrq_always_enabled splash=verbose fbcon=nodefer"
steamenv_verbosity=""
timeout_style=menu
steamenv_init
timeout=10
## end steamenv header sub block'

# Status Subfunction: Returns 0 for MODIFIED (true), 1 for DEFAULT (false), 2 for UNKNOWN
get_current_status() {
  if [ ! -f "$TARGET_FILE" ]; then
    return 2
  fi

  local file_content
  file_content=$(cat "$TARGET_FILE")

  if echo "$file_content" | grep -Fq 'earlycon=efifb'; then
    return 0 # Modified configuration is active
  elif echo "$file_content" | grep -Fq 'fbcon=vc:4-6'; then
    return 1 # Default configuration is active
  else
    return 2 # Block not found or corrupted
  fi
}

# Print usage instructions
print_usage() {
  echo "Usage: $0 {true|false|status}"
  echo "  true   - Apply modified kernel configuration"
  echo "  false  - Revert to default kernel configuration"
  echo "  status - Check current configuration state"
}

# Main script logic validation
if [ "$#" -ne 1 ]; then
  print_usage
  exit 1
fi

ACTION=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# Handle the 'status' command immediately (does not require root privileges)
if [ "$ACTION" = "status" ]; then
  get_current_status
  status_code=$?
  if [ $status_code -eq 0 ]; then
    echo "Status: MODIFIED kernel configuration is active"
    exit 0
  elif [ $status_code -eq 1 ]; then
    echo "Status: DEFAULT kernel configuration is active"
    exit 0
  else
    echo "Status: unknown (Could not find a valid steamenv block in $TARGET_FILE)"
    exit 2
  fi
fi

# Apply state modifications (requires root privileges)
if [ "$EUID" -ne 0 ]; then
  echo "Error: Modifying configuration requires root privileges. Please run with sudo." >&2
  exit 1
fi

if [ ! -f "$TARGET_FILE" ]; then
  echo "Error: $TARGET_FILE not found." >&2
  exit 1
fi

get_current_status
current_state=$?

case "$ACTION" in
"true")
  if [ $current_state -eq 0 ]; then
    echo "No-op: Target configuration is already set to true (modified)."
    exit 0
  fi

  echo "Applying MODIFIED kernel configuration..."
  awk -v block="$MODIFIED_BLOCK" '
            BEGIN { p=1 }
            /## start header steamenv sub block/ { print block; p=0; next }
            /## end steamenv header sub block/ { p=1; next }
            p { print }
        ' "$TARGET_FILE" >"${TARGET_FILE}.tmp"
  ;;

"false")
  if [ $current_state -eq 1 ]; then
    echo "No-op: Target configuration is already set to false (default)."
    exit 0
  fi

  echo "Applying DEFAULT kernel configuration..."
  awk -v block="$DEFAULT_BLOCK" '
            BEGIN { p=1 }
            /## start header steamenv sub block/ { print block; p=0; next }
            /## end steamenv header sub block/ { p=1; next }
            p { print }
        ' "$TARGET_FILE" >"${TARGET_FILE}.tmp"
  ;;

*)
  print_usage
  exit 1
  ;;
esac

# Save modifications safely, ensure permissions, and regenerate GRUB configuration
mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
chmod +x "$TARGET_FILE"

echo "Success! Configuration updated. Regenerating GRUB system profile..."
update-grub
