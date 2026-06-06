#!/bin/bash

# Check if the SteamOS filesystem is read-only and exit if enabled
if command -v steamos-readonly &>/dev/null; then
  if [ "$(steamos-readonly status)" = "enabled" ]; then
    echo "Warning: Filesystem is read-only. Aborting modifications." >&2
    echo "Please disable protection first via: steamos-readonly disable" >&2
    exit 1
  fi
fi

# Initialize arrays to store menu titles and their corresponding GRUB selection specifiers
declare -a menu_titles
declare -a menu_specifiers

# Use AWK to parse the GRUB config and store menu entries in arrays
while IFS= read -r line; do
  menu_specifiers+=("$(echo "$line" | awk '{print $1}')") # Selection format specifier
  menu_titles+=("$(echo "$line" | cut -d' ' -f2-)")       # Title only
done < <(awk '
  BEGIN { top_index=-1; sub_index=0; in_submenu=0; }

  # Match submenu entries, handling both single and double quotes
  /submenu / {
    top_index++; sub_index=0; in_submenu=1;
    next;
  }

  # Match menu entries, handling both single and double quotes
  /menuentry / {
    match($0, /menuentry [^"\047]*["\047]([^"\047]*)["\047]/, title);
    entry_title = title[1];

    if (in_submenu) {
      format = top_index ">" sub_index;
      print format " " entry_title;
      sub_index++;
    } else {
      top_index++; sub_index=0;
      format = top_index;
      print format " " entry_title;
    }
  }

  # Detect closing braces to exit submenu mode
  /^}/ {
    if (in_submenu) {
      in_submenu = 0;
    }
  }
' /boot/efi/EFI/steamos/grub.cfg)

# Check if there are any menu entries
if [ ${#menu_titles[@]} -eq 0 ]; then
  echo "No menu entries found."
  exit 1
fi

# User selection loop
while true; do
  echo "Available boot options:"
  for i in "${!menu_titles[@]}"; do
    echo "$((i + 1))) ${menu_titles[i]}"
  done
  echo "0) Cancel"

  # Ask the user for their selection
  echo -n "Select a boot entry (enter number): "
  read choice

  # If user chooses to cancel
  if [[ "$choice" == "0" ]]; then
    echo "Cancelled."
    exit 0
  fi

  # Validate input
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#menu_titles[@]}" ]; then
    selected_specifier="${menu_specifiers[$((choice - 1))]}"
    break
  else
    echo "Invalid choice. Please enter a valid number."
  fi
done

# Set the selected boot entry by modifying /etc/default/grub
echo "Setting default boot entry to: $selected_specifier"
sed -i '0,/^GRUB_DEFAULT=/s/^GRUB_DEFAULT=.*/GRUB_DEFAULT="'"$selected_specifier"'"/' /etc/default/grub
update-grub
