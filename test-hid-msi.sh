#!/bin/bash
# test-msi-claw.sh — MSI Claw HID driver attribute test
# Run from ~ as any user. Re-executes itself under sudo if not already root.
#
# Device paths increment on each USB re-enumeration caused by gamepad_mode
# switching. The LED classdev path is stable; its device/ symlink is used
# to reach the HID device attributes which may have moved.

if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# Capture dmesg timestamp at test start so we only report new messages
TEST_START_TIME=$(dmesg --time-format iso 2>/dev/null | tail -1 | awk '{print $1}' || echo "")

pass() { echo -e "${GREEN}PASS${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}FAIL${NC} $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC} $*"; SKIP=$((SKIP + 1)); }

# ── Locate sysfs paths ────────────────────────────────────────────────────────
LED_BASE="/sys/class/leds/msi_claw:rgb:joystick_rings"

find_gamepad_dev() {
    # Resolve via the stable LED device symlink so re-enumeration doesn't
    # invalidate the path. Falls back to bus scan if LED isn't registered yet.
    if [[ -L "${LED_BASE}/device" ]]; then
        local hid_dev
        hid_dev=$(readlink -f "${LED_BASE}/device")
        # Walk up to the HID device which holds the gamepad attrs
        # The LED device parent is the HID device itself
        if [[ -f "${hid_dev}/gamepad_mode" ]]; then
            echo "${hid_dev}/"
            return
        fi
        # One level up in case device points to a sub-device
        hid_dev=$(dirname "$hid_dev")
        if [[ -f "${hid_dev}/gamepad_mode" ]]; then
            echo "${hid_dev}/"
            return
        fi
    fi

    # Fallback: scan HID bus
    for d in /sys/bus/hid/devices/*/; do
        [[ -f "${d}gamepad_mode" ]] && { echo "$d"; return; }
    done
    return 1
}

# Re-resolve gamepad path after a mode switch causes re-enumeration.
# Retries for up to $1 seconds (default 5).
refresh_gamepad_dev() {
    local timeout="${1:-5}"
    local elapsed=0
    while (( elapsed < timeout )); do
        GAMEPAD_DEV=$(find_gamepad_dev 2>/dev/null || true)
        [[ -n "$GAMEPAD_DEV" ]] && return 0
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo -e "${RED}ERROR${NC}: Could not re-find gamepad sysfs after re-enumeration"
    return 1
}

echo "=== MSI Claw HID Driver Attribute Test ==="
echo

LED_DEV=""
[[ -d "$LED_BASE" ]] && LED_DEV="${LED_BASE}/"

GAMEPAD_DEV=$(find_gamepad_dev || true)

if [[ -z "$GAMEPAD_DEV" ]]; then
    echo -e "${RED}ERROR${NC}: No MSI Claw gamepad sysfs node found. Is the driver loaded and device connected?"
    exit 1
fi

echo "Gamepad sysfs: $GAMEPAD_DEV"
[[ -n "$LED_DEV" ]] && echo "LED sysfs:     $LED_DEV" \
                     || echo -e "${YELLOW}WARN${NC}: LED device not found, RGB tests will be skipped."
echo

# ── Helper: write then read-back ──────────────────────────────────────────────
# check_attr <path> <write_value> <expected_read> [delay_secs]
check_attr() {
    local path="$1" write_val="$2" expected="$3" delay="${4:-0}"

    if [[ ! -e "$path" ]]; then
        skip "$(basename "$path") — attribute not present"
        return
    fi

    echo -n "  Writing '${write_val}' to $(basename "$path") ... "
    if ! echo "$write_val" | tee "$path" > /dev/null 2>&1; then
        fail "write failed for '$write_val'"
        return
    fi

    [[ "$delay" != "0" ]] && sleep "$delay"

    local actual
    actual=$(cat "$path" 2>/dev/null | tr -d '\n')
    if [[ "$actual" == "$expected" ]]; then
        pass "'$actual'"
    else
        fail "expected '$expected', got '$actual'"
    fi
}

# check_attr_stable: like check_attr but re-resolves GAMEPAD_DEV after write
# since the path may have changed due to USB re-enumeration.
# check_attr_stable <attr_name> <write_value> <expected_read> [reenumeration_wait]
check_attr_stable() {
    local attr="$1" write_val="$2" expected="$3" wait="${4:-3}"

    if [[ ! -e "${GAMEPAD_DEV}${attr}" ]]; then
        skip "${attr} — attribute not present"
        return
    fi

    echo -n "  Writing '${write_val}' to ${attr} ... "
    if ! echo "$write_val" | tee "${GAMEPAD_DEV}${attr}" > /dev/null 2>&1; then
        fail "write failed for '$write_val'"
        return
    fi

    # Wait for re-enumeration then re-resolve the path
    sleep "$wait"
    if ! refresh_gamepad_dev 5; then
        fail "gamepad sysfs lost after mode switch"
        return
    fi

    local actual
    actual=$(cat "${GAMEPAD_DEV}${attr}" 2>/dev/null | tr -d '\n')
    if [[ "$actual" == "$expected" ]]; then
        pass "'$actual'"
    else
        fail "expected '$expected', got '$actual'"
    fi
}

# ── Helper: verify read-only attr contains expected string ────────────────────
check_contains() {
    local path="$1" expected="$2"

    if [[ ! -e "$path" ]]; then
        skip "$(basename "$path") — attribute not present"
        return
    fi

    local actual
    actual=$(cat "$path" 2>/dev/null)
    if echo "$actual" | grep -qF "$expected"; then
        pass "$(basename "$path") contains '$expected'"
    else
        fail "$(basename "$path") missing '$expected' — got: $actual"
    fi
}

# ── Save current state ────────────────────────────────────────────────────────
ORIG_MODE=$(cat "${GAMEPAD_DEV}gamepad_mode"    2>/dev/null || echo "xinput")
ORIG_MKEYS=$(cat "${GAMEPAD_DEV}mkeys_function" 2>/dev/null || echo "macro")
ORIG_M1=$([[ -e "${GAMEPAD_DEV}button_m1" ]] && cat "${GAMEPAD_DEV}button_m1" 2>/dev/null || echo "")
ORIG_M2=$([[ -e "${GAMEPAD_DEV}button_m2" ]] && cat "${GAMEPAD_DEV}button_m2" 2>/dev/null || echo "")
ORIG_RUMBLE_L=$(cat "${GAMEPAD_DEV}rumble_intensity_left"  2>/dev/null || echo "")
ORIG_RUMBLE_R=$(cat "${GAMEPAD_DEV}rumble_intensity_right" 2>/dev/null || echo "")
ORIG_EFFECT=$(cat "${LED_DEV}effect"      2>/dev/null || echo "")
ORIG_ENABLED=$(cat "${LED_DEV}enabled"    2>/dev/null || echo "")
ORIG_SPEED=$(cat "${LED_DEV}speed"        2>/dev/null || echo "")
ORIG_BRIGHTNESS=$(cat "${LED_DEV}brightness" 2>/dev/null || echo "")

echo "--- Saved: gamepad_mode='$ORIG_MODE' mkeys_function='$ORIG_MKEYS'"
echo "--- Saved: button_m1='$ORIG_M1' button_m2='$ORIG_M2'"
echo "--- Saved: rumble_left='$ORIG_RUMBLE_L' rumble_right='$ORIG_RUMBLE_R'"
echo "--- Saved: effect='$ORIG_EFFECT' enabled='$ORIG_ENABLED' speed='$ORIG_SPEED' brightness='$ORIG_BRIGHTNESS'"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== gamepad_mode ==="
# Each mode switch causes USB disconnect/reconnect. Re-resolve path after each.
for mode in dinput desktop xinput; do
    check_attr_stable "gamepad_mode" "$mode" "$mode" 3
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== gamepad_mode_index (RO) ==="
check_contains "${GAMEPAD_DEV}gamepad_mode_index" "xinput"
check_contains "${GAMEPAD_DEV}gamepad_mode_index" "dinput"
check_contains "${GAMEPAD_DEV}gamepad_mode_index" "desktop"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== mkeys_function ==="
for fn in disabled combination macro; do
    check_attr "${GAMEPAD_DEV}mkeys_function" "$fn" "$fn" 0.5
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== mkeys_function_index (RO) ==="
check_contains "${GAMEPAD_DEV}mkeys_function_index" "macro"
check_contains "${GAMEPAD_DEV}mkeys_function_index" "disabled"
check_contains "${GAMEPAD_DEV}mkeys_function_index" "combination"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== button_m1 ==="
if [[ -e "${GAMEPAD_DEV}button_m1" ]]; then
    check_attr "${GAMEPAD_DEV}button_m1" "BTN_SOUTH" "BTN_SOUTH" 0.5
    check_attr "${GAMEPAD_DEV}button_m1" "KEY_LEFTCTRL KEY_Z" "KEY_LEFTCTRL KEY_Z" 0.5
    # DISABLED (code 0xff) reads back as (not set) by design
    check_attr "${GAMEPAD_DEV}button_m1" "DISABLED" "(not set)" 0.5
    # Empty write also clears to (not set)
    echo -n "  Clearing button_m1 via empty write ... "
    echo "" | tee "${GAMEPAD_DEV}button_m1" > /dev/null 2>&1 || true
    sleep 0.5
    actual=$(cat "${GAMEPAD_DEV}button_m1" 2>/dev/null | tr -d '\n')
    [[ "$actual" == "(not set)" ]] && pass "'(not set)'" \
                                   || fail "expected '(not set)', got '$actual'"
else
    skip "button_m1 — not present (firmware may not support bmap)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== button_m2 ==="
if [[ -e "${GAMEPAD_DEV}button_m2" ]]; then
    check_attr "${GAMEPAD_DEV}button_m2" "BTN_NORTH" "BTN_NORTH" 0.5
    check_attr "${GAMEPAD_DEV}button_m2" "KEY_LEFTALT KEY_F4" "KEY_LEFTALT KEY_F4" 0.5
    # DISABLED (code 0xff) reads back as (not set) by design
    check_attr "${GAMEPAD_DEV}button_m2" "DISABLED" "(not set)" 0.5
    echo -n "  Clearing button_m2 via empty write ... "
    echo "" | tee "${GAMEPAD_DEV}button_m2" > /dev/null 2>&1 || true
    sleep 0.5
    actual=$(cat "${GAMEPAD_DEV}button_m2" 2>/dev/null | tr -d '\n')
    [[ "$actual" == "(not set)" ]] && pass "'(not set)'" \
                                   || fail "expected '(not set)', got '$actual'"
else
    skip "button_m2 — not present (firmware may not support bmap)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== button_mapping_options (RO) ==="
check_contains "${GAMEPAD_DEV}button_mapping_options" "BTN_SOUTH"
check_contains "${GAMEPAD_DEV}button_mapping_options" "KEY_ESC"
check_contains "${GAMEPAD_DEV}button_mapping_options" "DISABLED"
check_contains "${GAMEPAD_DEV}button_mapping_options" "REL_WHEEL_UP"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== rumble_intensity_left ==="
if [[ -e "${GAMEPAD_DEV}rumble_intensity_left" ]]; then
    check_attr "${GAMEPAD_DEV}rumble_intensity_left" "0"   "0"   0.5
    check_attr "${GAMEPAD_DEV}rumble_intensity_left" "50"  "50"  0.5
    check_attr "${GAMEPAD_DEV}rumble_intensity_left" "100" "100" 0.5
else
    skip "rumble_intensity_left — not present (firmware may not support rumble)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== rumble_intensity_right ==="
if [[ -e "${GAMEPAD_DEV}rumble_intensity_right" ]]; then
    check_attr "${GAMEPAD_DEV}rumble_intensity_right" "0"   "0"   0.5
    check_attr "${GAMEPAD_DEV}rumble_intensity_right" "75"  "75"  0.5
    check_attr "${GAMEPAD_DEV}rumble_intensity_right" "100" "100" 0.5
else
    skip "rumble_intensity_right — not present (firmware may not support rumble)"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== rumble_intensity_range (RO) ==="
check_contains "${GAMEPAD_DEV}rumble_intensity_range" "0-100"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: effect ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect" ]]; then
    for effect in monocolor breathe chroma rainbow frostfire; do
        check_attr "${LED_DEV}effect" "$effect" "$effect" 0.5
    done
else
    skip "effect — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: effect_index (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect_index" ]]; then
    for effect in monocolor breathe chroma rainbow frostfire; do
        check_contains "${LED_DEV}effect_index" "$effect"
    done
else
    skip "effect_index — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: enabled ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}enabled" ]]; then
    check_attr "${LED_DEV}enabled" "false" "false" 0.5
    check_attr "${LED_DEV}enabled" "true"  "true"  0.5
else
    skip "enabled — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: enabled_index (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}enabled_index" ]]; then
    check_contains "${LED_DEV}enabled_index" "true"
    check_contains "${LED_DEV}enabled_index" "false"
else
    skip "enabled_index — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: speed ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed" ]]; then
    check_attr "${LED_DEV}speed" "0"  "0"  0.5
    check_attr "${LED_DEV}speed" "10" "10" 0.5
    check_attr "${LED_DEV}speed" "20" "20" 0.5
else
    skip "speed — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: speed_range (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed_range" ]]; then
    check_contains "${LED_DEV}speed_range" "0-20"
else
    skip "speed_range — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== RGB: brightness (LED core) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}brightness" ]]; then
    check_attr "${LED_DEV}brightness" "50"  "50"  0.5
    check_attr "${LED_DEV}brightness" "100" "100" 0.5
    check_attr "${LED_DEV}brightness" "80"  "80"  0.5
else
    skip "brightness — LED device not present"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Boundary / rejection tests ==="

echo -n "  gamepad_mode invalid value ... "
if echo "invalid_mode" | tee "${GAMEPAD_DEV}gamepad_mode" > /dev/null 2>&1; then
    fail "should have rejected 'invalid_mode'"
else
    pass "correctly rejected"
fi

if [[ -e "${GAMEPAD_DEV}rumble_intensity_left" ]]; then
    echo -n "  rumble_intensity_left out-of-range (101) ... "
    if echo "101" | tee "${GAMEPAD_DEV}rumble_intensity_left" > /dev/null 2>&1; then
        fail "should have rejected 101"
    else
        pass "correctly rejected"
    fi
fi

if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed" ]]; then
    echo -n "  speed out-of-range (21) ... "
    if echo "21" | tee "${LED_DEV}speed" > /dev/null 2>&1; then
        fail "should have rejected 21"
    else
        pass "correctly rejected"
    fi
fi

if [[ -e "${GAMEPAD_DEV}button_m1" ]]; then
    echo -n "  button_m1 too many keys (6) ... "
    if echo "BTN_SOUTH BTN_NORTH BTN_EAST BTN_WEST BTN_TL BTN_TR" \
        | tee "${GAMEPAD_DEV}button_m1" > /dev/null 2>&1; then
        fail "should have rejected 6 keys"
    else
        pass "correctly rejected"
    fi

    echo -n "  button_m1 invalid key name ... "
    if echo "NOT_A_KEY" | tee "${GAMEPAD_DEV}button_m1" > /dev/null 2>&1; then
        fail "should have rejected 'NOT_A_KEY'"
    else
        pass "correctly rejected"
    fi
fi

echo -n "  reset with false ... "
if echo "false" | tee "${GAMEPAD_DEV}reset" > /dev/null 2>&1; then
    fail "should have rejected 'false'"
else
    pass "correctly rejected"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Restoring original state ==="

# gamepad_mode first — causes re-enumeration so resolve path after
echo -n "  gamepad_mode -> '$ORIG_MODE' ... "
echo "$ORIG_MODE" | tee "${GAMEPAD_DEV}gamepad_mode" > /dev/null 2>&1 || true
sleep 3
refresh_gamepad_dev 5 || true
echo "done"

echo -n "  mkeys_function -> '$ORIG_MKEYS' ... "
echo "$ORIG_MKEYS" | tee "${GAMEPAD_DEV}mkeys_function" > /dev/null 2>&1 || true
sleep 0.5
echo "done"

if [[ -e "${GAMEPAD_DEV}button_m1" ]]; then
    echo -n "  button_m1 -> '$ORIG_M1' ... "
    if [[ "$ORIG_M1" == "(not set)" ]] || [[ -z "$ORIG_M1" ]]; then
        echo "" | tee "${GAMEPAD_DEV}button_m1" > /dev/null 2>&1 || true
    else
        echo "$ORIG_M1" | tee "${GAMEPAD_DEV}button_m1" > /dev/null 2>&1 || true
    fi
    sleep 0.5
    echo "done"
fi

if [[ -e "${GAMEPAD_DEV}button_m2" ]]; then
    echo -n "  button_m2 -> '$ORIG_M2' ... "
    if [[ "$ORIG_M2" == "(not set)" ]] || [[ -z "$ORIG_M2" ]]; then
        echo "" | tee "${GAMEPAD_DEV}button_m2" > /dev/null 2>&1 || true
    else
        echo "$ORIG_M2" | tee "${GAMEPAD_DEV}button_m2" > /dev/null 2>&1 || true
    fi
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_RUMBLE_L" ]] && [[ -e "${GAMEPAD_DEV}rumble_intensity_left" ]]; then
    echo -n "  rumble_intensity_left -> '$ORIG_RUMBLE_L' ... "
    echo "$ORIG_RUMBLE_L" | tee "${GAMEPAD_DEV}rumble_intensity_left" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_RUMBLE_R" ]] && [[ -e "${GAMEPAD_DEV}rumble_intensity_right" ]]; then
    echo -n "  rumble_intensity_right -> '$ORIG_RUMBLE_R' ... "
    echo "$ORIG_RUMBLE_R" | tee "${GAMEPAD_DEV}rumble_intensity_right" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_EFFECT" ]] && [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect" ]]; then
    echo -n "  effect -> '$ORIG_EFFECT' ... "
    echo "$ORIG_EFFECT" | tee "${LED_DEV}effect" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_ENABLED" ]] && [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}enabled" ]]; then
    echo -n "  enabled -> '$ORIG_ENABLED' ... "
    echo "$ORIG_ENABLED" | tee "${LED_DEV}enabled" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_SPEED" ]] && [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed" ]]; then
    echo -n "  speed -> '$ORIG_SPEED' ... "
    echo "$ORIG_SPEED" | tee "${LED_DEV}speed" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi

if [[ -n "$ORIG_BRIGHTNESS" ]] && [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}brightness" ]]; then
    echo -n "  brightness -> '$ORIG_BRIGHTNESS' ... "
    echo "$ORIG_BRIGHTNESS" | tee "${LED_DEV}brightness" > /dev/null 2>&1 || true
    sleep 0.5
    echo "done"
fi
echo

# ── dmesg helper ─────────────────────────────────────────────────────────────
# check_dmesg_since <iso_timestamp> <section_label>
# Prints any hid-msi error/warn lines since the given timestamp and counts
# them as a failure. Falls back to tail -500 if timestamp is empty.
check_dmesg_since() {
    local since="$1" label="$2"
    local errors=""

    if [[ -n "$since" ]]; then
        errors=$(dmesg --time-format iso 2>/dev/null             | awk -v start="$since" '$1 >= start'             | grep -i "hid-msi\|hid_msi"             | grep -iE "error|warn|fail|bug|oops|panic|null|invalid"             || true)
    else
        errors=$(dmesg 2>/dev/null             | tail -500             | grep -i "hid-msi\|hid_msi"             | grep -iE "error|warn|fail|bug|oops|panic|null|invalid"             || true)
    fi

    if [[ -n "$errors" ]]; then
        echo -e "  ${RED}Kernel messages during ${label}:${NC}"
        echo "$errors" | while IFS= read -r line; do
            echo -e "  ${RED}>>>${NC} $line"
        done
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}No hid-msi errors or warnings during ${label}${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo "=== dmesg check: test run ==="
check_dmesg_since "$TEST_START_TIME" "test run"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== modprobe unload/reload ==="
if ! modinfo hid_msi > /dev/null 2>&1; then
    skip "hid_msi module not found (built-in?), skipping modprobe test"
else
    UNLOAD_TIME=$(dmesg --time-format iso 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    echo -n "  modprobe -r hid_msi ... "
    if modprobe -r hid_msi 2>/dev/null; then
        echo "done"
    else
        fail "modprobe -r hid_msi failed"
    fi
    sleep 1
    check_dmesg_since "$UNLOAD_TIME" "modprobe -r"

    LOAD_TIME=$(dmesg --time-format iso 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    echo -n "  modprobe hid_msi ... "
    if modprobe hid_msi 2>/dev/null; then
        echo "done"
    else
        fail "modprobe hid_msi failed"
    fi
    sleep 2
    check_dmesg_since "$LOAD_TIME" "modprobe load"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Results ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"
echo

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}TEST SUITE FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}TEST SUITE PASSED${NC}"
    exit 0
fi
