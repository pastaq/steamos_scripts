#!/bin/bash
# test-hid-lenovo-go.sh — Lenovo Legion Go HID driver attribute test
# Run from ~ as any user. Re-executes itself under sudo if not already root.
#
# Only attributes that ship with a companion _index or _range sibling are
# exercised here — bare RO status/info attrs (firmware_version, hardware_*,
# product_version, protocol_version, physical_location/*, power/*, reset_mcu,
# left_handle/reset, right_handle/reset, *_status, fps_switch_status,
# tx_dongle/*, country, trigger) were discarded per spec: no defined valid
# set to assert against. `brightness` is kept because `max_brightness`
# functions as its range even though it isn't literally named brightness_range.
#
# `mode` (xinput/dinput) changes the USB PID on every switch, exactly like
# gamepad_mode on the MSI Claw — the device re-enumerates and every sysfs
# path under it (including left_handle/, right_handle/, touchpad/, and the
# LED classdev) goes stale and must be re-resolved.
#
# calibrate_gyro / calibrate_joystick / calibrate_trigger are write-only
# "start" actions — there is no "stop": the firmware runs the calibration
# itself, exiting ~2s after the physical motion completes (success) or at a
# 10s timeout (failure), per the Legion Go 2 calibration protocol. These are
# gated behind --with-calibration and SKIPped by default since they run real
# hardware calibration and require the user to perform the motion in-window.
#
# Scoping flags (any combination; default is everything if none given):
#   --mcu            parent-level attrs only (mode, os_mode, fps_mode_dpi,
#   		     rumble_intensity)
#   --left-handle    left_handle/ attrs only
#   --right-handle   right_handle/ attrs only
#   --touchpad       touchpad/ attrs only
#   --rgb            LED classdev attrs only
#   --calibration    calibrate_* actions only (scoped to left/right if
#   		     combined with those flags, otherwise both hands)
# modprobe unload/reload is skipped whenever any --* flag is given, since
# it's a whole-device operation orthogonal to scoping.

WITH_CALIBRATION=0
MCU=0
LEFT=0
RIGHT=0
TOUCHPAD=0
RGB=0
CALIBRATION=0
for arg in "$@"; do
    case "$arg" in
        --mcu)          MCU=1 ;;
        --left-handle)  LEFT=1 ;;
        --right-handle) RIGHT=1 ;;
        --touchpad)     TOUCHPAD=1 ;;
        --rgb)          RGB=1 ;;
        --calibration)  CALIBRATION=1 ;;
    esac
done

ANY_ONLY=0
if [[ "$MCU" -eq 1 || "$LEFT" -eq 1 || "$RIGHT" -eq 1 || \
      "$TOUCHPAD" -eq 1 || "$RGB" -eq 1 || "$CALIBRATION" -eq 1 ]]; then
    ANY_ONLY=1
fi

if [[ "$ANY_ONLY" -eq 1 ]]; then
    RUN_MCU=$MCU
    RUN_RGB=$RGB
    RUN_TOUCHPAD=$TOUCHPAD
    RUN_LEFT_ATTRS=$LEFT
    RUN_RIGHT_ATTRS=$RIGHT

    if [[ "$CALIBRATION" -eq 1 ]]; then
        WITH_CALIBRATION=1
        if [[ "$LEFT" -eq 1 || "$RIGHT" -eq 1 ]]; then
            RUN_CALIB_LEFT=$LEFT
            RUN_CALIB_RIGHT=$RIGHT
        else
            RUN_CALIB_LEFT=1
            RUN_CALIB_RIGHT=1
        fi
    else
        RUN_CALIB_LEFT=0
        RUN_CALIB_RIGHT=0
        [[ "$LEFT" -eq 1  && "$WITH_CALIBRATION" -eq 1 ]] && RUN_CALIB_LEFT=1
        [[ "$RIGHT" -eq 1 && "$WITH_CALIBRATION" -eq 1 ]] && RUN_CALIB_RIGHT=1
    fi
else
    RUN_MCU=1
    RUN_RGB=1
    RUN_TOUCHPAD=1
    RUN_LEFT_ATTRS=1
    RUN_RIGHT_ATTRS=1
    RUN_CALIB_LEFT=$WITH_CALIBRATION
    RUN_CALIB_RIGHT=$WITH_CALIBRATION
fi

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
LED_BASE="/sys/class/leds/go:rgb:joystick_rings"

find_gamepad_dev() {
    # Resolve via the stable LED device symlink so PID re-enumeration on
    # mode switch doesn't invalidate the path. Falls back to bus scan.
    if [[ -L "${LED_BASE}/device" ]]; then
        local hid_dev
        hid_dev=$(readlink -f "${LED_BASE}/device")
        if [[ -f "${hid_dev}/mode" ]] && [[ -d "${hid_dev}/left_handle" ]]; then
            echo "${hid_dev}/"
            return
        fi
        hid_dev=$(dirname "$hid_dev")
        if [[ -f "${hid_dev}/mode" ]] && [[ -d "${hid_dev}/left_handle" ]]; then
            echo "${hid_dev}/"
            return
        fi
    fi

    # Fallback: scan HID bus for the Legion Go controller node
    for d in /sys/bus/hid/devices/*/; do
        [[ -f "${d}mode" ]] && [[ -d "${d}left_handle" ]] && { echo "$d"; return; }
    done
    return 1
}

# Re-resolve gamepad + LED paths after a mode switch causes re-enumeration.
# Retries for up to $1 seconds (default 5).
refresh_gamepad_dev() {
    local timeout="${1:-5}"
    local elapsed=0
    while (( elapsed < timeout )); do
        GAMEPAD_DEV=$(find_gamepad_dev 2>/dev/null || true)
        if [[ -n "$GAMEPAD_DEV" ]]; then
            LED_DEV=""
            [[ -d "$LED_BASE" ]] && LED_DEV="${LED_BASE}/"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    echo -e "${RED}ERROR${NC}: Could not re-find gamepad sysfs after re-enumeration"
    return 1
}

echo "=== Lenovo Legion Go HID Driver Attribute Test ==="
[[ "$WITH_CALIBRATION" -eq 1 ]] && echo -e "${YELLOW}NOTE${NC}: --with-calibration set — calibrate_* actions will run"
if [[ "$ANY_ONLY" -eq 1 ]]; then
    scope=""
    [[ "$RUN_MCU" -eq 1 ]]         && scope+="mcu "
    [[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && scope+="left_handle "
    [[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && scope+="right_handle "
    [[ "$RUN_TOUCHPAD" -eq 1 ]]    && scope+="touchpad "
    [[ "$RUN_RGB" -eq 1 ]]         && scope+="rgb "
    [[ "$RUN_CALIB_LEFT" -eq 1 || "$RUN_CALIB_RIGHT" -eq 1 ]] && scope+="calibration "
    echo -e "${YELLOW}NOTE${NC}: scoped run — testing: ${scope:-<nothing selected>}"
fi
echo

LED_DEV=""
[[ -d "$LED_BASE" ]] && LED_DEV="${LED_BASE}/"

GAMEPAD_DEV=$(find_gamepad_dev || true)

if [[ -z "$GAMEPAD_DEV" ]]; then
    echo -e "${RED}ERROR${NC}: No Legion Go controller sysfs node found. Is the driver loaded and device connected?"
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
	echo "failed first try, checking again..."
    	actual=$(cat "$path" 2>/dev/null | tr -d '\n')
    	if [[ "$actual" == "$expected" ]]; then
    	    pass "'$actual'"
    	else
            fail "expected '$expected', got '$actual'"
	fi
    fi
}

# check_attr_stable: like check_attr but re-resolves GAMEPAD_DEV/LED_DEV after
# write, since the path may have changed due to a mode-switch PID change.
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

# ── Calibration runner ────────────────────────────────────────────────────────
# Per the Legion Go calibration protocol: write "start", the user performs the
# physical motion, and the firmware exits on its own — success ~2s after the
# motion completes, or a failure/timeout report at 10s if it doesn't. There is
# no "stop" write; this polls <attr>_status until it changes or 10s elapses.
#
# The wire protocol reports a numeric code (0x01 success, 0x02 generic
# failure, plus per-module reason bitmasks), but the driver abstracts that —
# <attr>_status reads back a string, not the raw code, matching this driver's
# usual attr/attr_index pairing. The success string is taken from
# <attr>_status_index (whichever token contains "success"); anything else,
# including an unchanged/timed-out reading, counts as failure. Reason
# bitmasks aren't decoded here.
#
# <attr>_status has no _range sibling and only sometimes has _status_index
# (normally grounds for discarding it per spec), but it's kept as the only
# way to observe the outcome of a calibration action.
# run_calibration <side> <attr_name> <motion_instruction>
run_calibration() {
    local side="$1" attr="$2" instruction="$3"
    local status_path="${GAMEPAD_DEV}${side}/${attr}_status"
    local index_path="${GAMEPAD_DEV}${side}/${attr}_status_index"
    local start_path="${GAMEPAD_DEV}${side}/${attr}"

    echo "=== ${side}/${attr} (--with-calibration) ==="

    if [[ ! -e "$start_path" ]]; then
        skip "${attr} — attribute not present"
        echo
        return
    fi

    local baseline=""
    [[ -e "$status_path" ]] && baseline=$(cat "$status_path" 2>/dev/null | tr -d '\n')

    echo -e "  ${YELLOW}${instruction}${NC}"
    read -r -p "  Press Enter once ready to write 'start' and begin calibration ... " _ < /dev/tty

    echo -n "  Writing 'start' to ${attr} ... "
    if ! echo "start" | tee "$start_path" > /dev/null 2>&1; then
        fail "write rejected"
        echo
        return
    fi
    pass "accepted"

    if [[ ! -e "$status_path" ]]; then
        skip "${attr}_status — not present, cannot confirm outcome"
        echo
        return
    fi

    echo -n "  Polling ${attr}_status (up to 11s) "
    local elapsed=0 final=""
    while (( elapsed < 11 )); do
        sleep 1
        elapsed=$((elapsed + 1))
        echo -n "."
        final=$(cat "$status_path" 2>/dev/null | tr -d '\n')
        [[ "$final" != "$baseline" ]] && break
    done
    echo " ${final:-<empty>}"

    if [[ "$final" == "$baseline" ]]; then
        fail "${attr}_status unchanged after 11s — likely timed out"
        echo
        return
    fi

    # Determine the success token from <attr>_status_index (the entry
    # containing "success"), falling back to the literal word "success" if
    # the index attribute isn't present.
    local success_token="success"
    if [[ -e "$index_path" ]]; then
        local index_content match
        index_content=$(cat "$index_path" 2>/dev/null)
        match=$(echo "$index_content" | tr ' ' '\n' | grep -i "success" | head -1)
        [[ -n "$match" ]] && success_token="$match"
    fi

    local final_lc token_lc
    final_lc=$(echo "$final" | tr '[:upper:]' '[:lower:]')
    token_lc=$(echo "$success_token" | tr '[:upper:]' '[:lower:]')

    if [[ "$final_lc" == "$token_lc" ]]; then
        pass "${attr}_status: '$final' (success)"
    else
        fail "${attr}_status: '$final' (not success — expected '$success_token')"
    fi
    echo
}

# ── Save current state ────────────────────────────────────────────────────────
ORIG_MODE=$(cat "${GAMEPAD_DEV}mode"                          2>/dev/null || echo "xinput")
ORIG_OS_MODE=$(cat "${GAMEPAD_DEV}os_mode"                     2>/dev/null || echo "linux")
ORIG_FPS_DPI=$(cat "${GAMEPAD_DEV}fps_mode_dpi"                2>/dev/null || echo "")
ORIG_RUMBLE=$(cat "${GAMEPAD_DEV}rumble_intensity"             2>/dev/null || echo "")

ORIG_L_SLEEP=$(cat "${GAMEPAD_DEV}left_handle/auto_sleep_time"      2>/dev/null || echo "")
ORIG_R_SLEEP=$(cat "${GAMEPAD_DEV}right_handle/auto_sleep_time"     2>/dev/null || echo "")
ORIG_L_IMU_BYPASS=$(cat "${GAMEPAD_DEV}left_handle/imu_bypass_enabled"   2>/dev/null || echo "")
ORIG_R_IMU_BYPASS=$(cat "${GAMEPAD_DEV}right_handle/imu_bypass_enabled"  2>/dev/null || echo "")
ORIG_L_IMU_EN=$(cat "${GAMEPAD_DEV}left_handle/imu_enabled"         2>/dev/null || echo "")
ORIG_R_IMU_EN=$(cat "${GAMEPAD_DEV}right_handle/imu_enabled"        2>/dev/null || echo "")
ORIG_L_RUMBLE_MODE=$(cat "${GAMEPAD_DEV}left_handle/rumble_mode"    2>/dev/null || echo "")
ORIG_R_RUMBLE_MODE=$(cat "${GAMEPAD_DEV}right_handle/rumble_mode"   2>/dev/null || echo "")
ORIG_L_RUMBLE_NOTIF=$(cat "${GAMEPAD_DEV}left_handle/rumble_notification"  2>/dev/null || echo "")
ORIG_R_RUMBLE_NOTIF=$(cat "${GAMEPAD_DEV}right_handle/rumble_notification" 2>/dev/null || echo "")

ORIG_TP_ENABLED=$(cat "${GAMEPAD_DEV}touchpad/enabled"              2>/dev/null || echo "")
ORIG_TP_VIB_EN=$(cat "${GAMEPAD_DEV}touchpad/vibration_enabled"     2>/dev/null || echo "")
ORIG_TP_VIB_INT=$(cat "${GAMEPAD_DEV}touchpad/vibration_intensity"  2>/dev/null || echo "")

ORIG_LED_EFFECT=$(cat "${LED_DEV}effect"           2>/dev/null || echo "")
ORIG_LED_ENABLED=$(cat "${LED_DEV}enabled"         2>/dev/null || echo "")
ORIG_LED_MODE=$(cat "${LED_DEV}mode"               2>/dev/null || echo "")
ORIG_LED_SPEED=$(cat "${LED_DEV}speed"             2>/dev/null || echo "")
ORIG_LED_BRIGHTNESS=$(cat "${LED_DEV}brightness"   2>/dev/null || echo "")
ORIG_LED_PROFILE=$(cat "${LED_DEV}profile"         2>/dev/null || echo "")
ORIG_LED_MULTI=$(cat "${LED_DEV}multi_intensity"   2>/dev/null || echo "")

echo "--- Saved: mode='$ORIG_MODE' os_mode='$ORIG_OS_MODE' fps_mode_dpi='$ORIG_FPS_DPI' rumble_intensity='$ORIG_RUMBLE'"
echo "--- Saved: left_handle sleep='$ORIG_L_SLEEP' imu_bypass='$ORIG_L_IMU_BYPASS' imu_enabled='$ORIG_L_IMU_EN' rumble_mode='$ORIG_L_RUMBLE_MODE' rumble_notif='$ORIG_L_RUMBLE_NOTIF'"
echo "--- Saved: right_handle sleep='$ORIG_R_SLEEP' imu_bypass='$ORIG_R_IMU_BYPASS' imu_enabled='$ORIG_R_IMU_EN' rumble_mode='$ORIG_R_RUMBLE_MODE' rumble_notif='$ORIG_R_RUMBLE_NOTIF'"
echo "--- Saved: touchpad enabled='$ORIG_TP_ENABLED' vibration_enabled='$ORIG_TP_VIB_EN' vibration_intensity='$ORIG_TP_VIB_INT'"
echo "--- Saved: LED effect='$ORIG_LED_EFFECT' enabled='$ORIG_LED_ENABLED' mode='$ORIG_LED_MODE' speed='$ORIG_LED_SPEED' brightness='$ORIG_LED_BRIGHTNESS' profile='$ORIG_LED_PROFILE' multi_intensity='$ORIG_LED_MULTI'"
echo

# ══════════════════════════════════════════════════════════════════════════════
if [[ "$RUN_MCU" -eq 1 ]]; then
echo "=== mode (PID changes on every switch — re-enumeration) ==="
for m in dinput xinput; do
    check_attr_stable "mode" "$m" "$m" 3
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== mode_index (RO) ==="
check_contains "${GAMEPAD_DEV}mode_index" "xinput"
check_contains "${GAMEPAD_DEV}mode_index" "dinput"
echo

# ══════════════════════════════════════════════════════════════════════════════
# MCU delay: 0.5s here vs. 0.5s on the MSI Claw's equivalent parent-level
# attrs (mkeys_function, button_m1/m2, rumble_intensity_left/right — all
# 0.5s in test-hid-msi.sh and reliable there). The Go MCU write path is
# empirically slower to settle at 0.5s (false negatives), so this uses 3x
# MSI's baseline — well short of the 3s reserved for a full re-enumeration,
# since these aren't PID-changing writes.
echo "=== os_mode ==="
for m in windows linux; do
    check_attr "${GAMEPAD_DEV}os_mode" "$m" "$m" 0.5
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== os_mode_index (RO) ==="
check_contains "${GAMEPAD_DEV}os_mode_index" "windows"
check_contains "${GAMEPAD_DEV}os_mode_index" "linux"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== fps_mode_dpi ==="
for dpi in 500 800 1200 1800; do
    check_attr "${GAMEPAD_DEV}fps_mode_dpi" "$dpi" "$dpi" 0.5
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== fps_mode_dpi_index (RO) ==="
for dpi in 500 800 1200 1800; do
    check_contains "${GAMEPAD_DEV}fps_mode_dpi_index" "$dpi"
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== rumble_intensity ==="
for level in off low medium high; do
    check_attr "${GAMEPAD_DEV}rumble_intensity" "$level" "$level" 0.5
done
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== rumble_intensity_index (RO) ==="
for level in off low medium high; do
    check_contains "${GAMEPAD_DEV}rumble_intensity_index" "$level"
done
echo
else
    skip "mcu (mode/os_mode/fps_mode_dpi/rumble_intensity) — excluded by selection"
    echo
fi

# ══════════════════════════════════════════════════════════════════════════════
# left_handle / right_handle share a schema — loop over both.
for side in left_handle right_handle; do
    if [[ "$side" == "left_handle" ]]; then
        attrs_flag=$RUN_LEFT_ATTRS
        calib_flag=$RUN_CALIB_LEFT
    else
        attrs_flag=$RUN_RIGHT_ATTRS
        calib_flag=$RUN_CALIB_RIGHT
    fi

    if [[ "$attrs_flag" -ne 1 && "$calib_flag" -ne 1 ]]; then
        skip "${side} — excluded by selection"
        continue
    fi

    if [[ "$attrs_flag" -eq 1 ]]; then
    echo "=== ${side}/auto_sleep_time ==="
    check_attr "${GAMEPAD_DEV}${side}/auto_sleep_time" "0"   "0"   0.5
    check_attr "${GAMEPAD_DEV}${side}/auto_sleep_time" "60"  "60"  0.5
    check_attr "${GAMEPAD_DEV}${side}/auto_sleep_time" "255" "255" 0.5
    echo

    echo "=== ${side}/auto_sleep_time_range (RO) ==="
    check_contains "${GAMEPAD_DEV}${side}/auto_sleep_time_range" "0-255"
    echo

    echo "=== ${side}/imu_bypass_enabled ==="
    check_attr "${GAMEPAD_DEV}${side}/imu_bypass_enabled" "false" "false" 0.5
    check_attr "${GAMEPAD_DEV}${side}/imu_bypass_enabled" "true"  "true"  0.5
    echo

    echo "=== ${side}/imu_bypass_enabled_index (RO) ==="
    check_contains "${GAMEPAD_DEV}${side}/imu_bypass_enabled_index" "true"
    check_contains "${GAMEPAD_DEV}${side}/imu_bypass_enabled_index" "false"
    echo

    echo "=== ${side}/imu_enabled ==="
    check_attr "${GAMEPAD_DEV}${side}/imu_enabled" "false" "false" 0.5
    check_attr "${GAMEPAD_DEV}${side}/imu_enabled" "true"  "true"  0.5
    echo

    echo "=== ${side}/imu_enabled_index (RO) ==="
    check_contains "${GAMEPAD_DEV}${side}/imu_enabled_index" "true"
    check_contains "${GAMEPAD_DEV}${side}/imu_enabled_index" "false"
    echo

    echo "=== ${side}/rumble_mode ==="
    for mode in fps racing standard spg rpg; do
        check_attr "${GAMEPAD_DEV}${side}/rumble_mode" "$mode" "$mode" 0.5
    done
    echo

    echo "=== ${side}/rumble_mode_index (RO) ==="
    for mode in fps racing standard spg rpg; do
        check_contains "${GAMEPAD_DEV}${side}/rumble_mode_index" "$mode"
    done
    echo

    echo "=== ${side}/rumble_notification ==="
    check_attr "${GAMEPAD_DEV}${side}/rumble_notification" "true"  "true"  0.5
    check_attr "${GAMEPAD_DEV}${side}/rumble_notification" "false" "false" 0.5
    echo

    echo "=== ${side}/rumble_notification_index (RO) ==="
    check_contains "${GAMEPAD_DEV}${side}/rumble_notification_index" "true"
    check_contains "${GAMEPAD_DEV}${side}/rumble_notification_index" "false"
    echo
    else
        skip "${side} attrs (auto_sleep_time/imu/rumble_mode/rumble_notification) — excluded by selection"
    fi

    if [[ "$calib_flag" -eq 1 ]]; then
        run_calibration "$side" "calibrate_joystick" \
            "Rotate the joystick along its edge for two full circles, then return it to center."
        run_calibration "$side" "calibrate_gyro" \
            "Set the controller down on a flat, stationary surface and don't touch it."
        run_calibration "$side" "calibrate_trigger" \
            "Pull the trigger through its full range, then release."
    else
        skip "${side}/calibrate_joystick — pass --with-calibration to run (write-only hardware action)"
        skip "${side}/calibrate_gyro — pass --with-calibration to run (write-only hardware action)"
        skip "${side}/calibrate_trigger — pass --with-calibration to run (write-only hardware action)"
        echo
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
if [[ "$RUN_TOUCHPAD" -eq 1 ]]; then
echo "=== touchpad/enabled ==="
check_attr "${GAMEPAD_DEV}touchpad/enabled" "false" "false" 0.5
check_attr "${GAMEPAD_DEV}touchpad/enabled" "true"  "true"  0.5
echo

echo "=== touchpad/enabled_index (RO) ==="
check_contains "${GAMEPAD_DEV}touchpad/enabled_index" "true"
check_contains "${GAMEPAD_DEV}touchpad/enabled_index" "false"
echo

echo "=== touchpad/vibration_enabled ==="
check_attr "${GAMEPAD_DEV}touchpad/vibration_enabled" "true"  "true"  0.5
check_attr "${GAMEPAD_DEV}touchpad/vibration_enabled" "false" "false" 0.5
echo

echo "=== touchpad/vibration_enabled_index (RO) ==="
check_contains "${GAMEPAD_DEV}touchpad/vibration_enabled_index" "true"
check_contains "${GAMEPAD_DEV}touchpad/vibration_enabled_index" "false"
echo

echo "=== touchpad/vibration_intensity ==="
for level in off low medium high; do
    check_attr "${GAMEPAD_DEV}touchpad/vibration_intensity" "$level" "$level" 0.5
done
echo

echo "=== touchpad/vibration_intensity_index (RO) ==="
for level in off low medium high; do
    check_contains "${GAMEPAD_DEV}touchpad/vibration_intensity_index" "$level"
done
echo
else
    skip "touchpad — excluded by selection"
    echo
fi

# ══════════════════════════════════════════════════════════════════════════════
if [[ "$RUN_RGB" -eq 1 ]]; then
echo "=== RGB: effect ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect" ]]; then
    for effect in monocolor breathe chroma rainbow; do
        check_attr "${LED_DEV}effect" "$effect" "$effect" 0.5
    done
else
    skip "effect — LED device not present"
fi
echo

echo "=== RGB: effect_index (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect_index" ]]; then
    for effect in monocolor breathe chroma rainbow; do
        check_contains "${LED_DEV}effect_index" "$effect"
    done
else
    skip "effect_index — LED device not present"
fi
echo

echo "=== RGB: enabled ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}enabled" ]]; then
    check_attr "${LED_DEV}enabled" "false" "false" 0.5
    check_attr "${LED_DEV}enabled" "true"  "true"  0.5
else
    skip "enabled — LED device not present"
fi
echo

echo "=== RGB: enabled_index (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}enabled_index" ]]; then
    check_contains "${LED_DEV}enabled_index" "true"
    check_contains "${LED_DEV}enabled_index" "false"
else
    skip "enabled_index — LED device not present"
fi
echo

echo "=== RGB: mode ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}mode" ]]; then
    check_attr "${LED_DEV}mode" "dynamic" "dynamic" 0.5
    check_attr "${LED_DEV}mode" "custom"  "custom"  0.5
else
    skip "mode — LED device not present"
fi
echo

echo "=== RGB: mode_index (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}mode_index" ]]; then
    check_contains "${LED_DEV}mode_index" "dynamic"
    check_contains "${LED_DEV}mode_index" "custom"
else
    skip "mode_index — LED device not present"
fi
echo

echo "=== RGB: speed ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed" ]]; then
    check_attr "${LED_DEV}speed" "0"   "0"   0.5
    check_attr "${LED_DEV}speed" "50"  "50"  0.5
    check_attr "${LED_DEV}speed" "100" "100" 0.5
else
    skip "speed — LED device not present"
fi
echo

echo "=== RGB: speed_range (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed_range" ]]; then
    check_contains "${LED_DEV}speed_range" "0-100"
else
    skip "speed_range — LED device not present"
fi
echo

echo "=== RGB: profile ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}profile" ]]; then
    check_attr "${LED_DEV}profile" "1" "1" 0.5
    check_attr "${LED_DEV}profile" "2" "2" 0.5
    check_attr "${LED_DEV}profile" "3" "3" 0.5
else
    skip "profile — LED device not present"
fi
echo

echo "=== RGB: profile_range (RO) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}profile_range" ]]; then
    check_contains "${LED_DEV}profile_range" "1-3"
else
    skip "profile_range — LED device not present"
fi
echo

echo "=== RGB: multi_intensity (paired with multi_index / multi_max_intensity) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}multi_intensity" ]]; then
    check_attr "${LED_DEV}multi_intensity" "100 0 0"   "100 0 0"   0.5
    check_attr "${LED_DEV}multi_intensity" "0 100 0"   "0 100 0"   0.5
    check_attr "${LED_DEV}multi_intensity" "1 90 100"  "1 90 100"  0.5
else
    skip "multi_intensity — LED device not present"
fi
echo

echo "=== RGB: multi_index (RO) ==="
check_contains "${LED_DEV}multi_index" "red"
check_contains "${LED_DEV}multi_index" "green"
check_contains "${LED_DEV}multi_index" "blue"
echo

echo "=== RGB: multi_max_intensity (RO) ==="
check_contains "${LED_DEV}multi_max_intensity" "100 100 100"
echo

echo "=== RGB: brightness (LED core, bounded by max_brightness) ==="
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}brightness" ]]; then
    check_attr "${LED_DEV}brightness" "50"  "50"  0.5
    check_attr "${LED_DEV}brightness" "100" "100" 0.5
    check_attr "${LED_DEV}brightness" "80"  "80"  0.5
else
    skip "brightness — LED device not present"
fi
echo

echo "=== RGB: max_brightness (RO) ==="
check_contains "${LED_DEV}max_brightness" "100"
echo
else
    skip "rgb — excluded by selection"
    echo
fi

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Boundary / rejection tests ==="

if [[ "$RUN_MCU" -eq 1 ]]; then
echo -n "  mode invalid value ... "
if echo "invalid_mode" | tee "${GAMEPAD_DEV}mode" > /dev/null 2>&1; then
    fail "should have rejected 'invalid_mode'"
else
    pass "correctly rejected"
fi

echo -n "  os_mode invalid value ... "
if echo "macos" | tee "${GAMEPAD_DEV}os_mode" > /dev/null 2>&1; then
    fail "should have rejected 'macos'"
else
    pass "correctly rejected"
fi

echo -n "  fps_mode_dpi invalid value (9999) ... "
if echo "9999" | tee "${GAMEPAD_DEV}fps_mode_dpi" > /dev/null 2>&1; then
    fail "should have rejected 9999"
else
    pass "correctly rejected"
fi

echo -n "  rumble_intensity invalid value ... "
if echo "extreme" | tee "${GAMEPAD_DEV}rumble_intensity" > /dev/null 2>&1; then
    fail "should have rejected 'extreme'"
else
    pass "correctly rejected"
fi
else
    skip "mcu boundary tests — excluded by selection"
fi

BOUNDARY_SIDE=""
if [[ "$RUN_LEFT_ATTRS" -eq 1 ]]; then
    BOUNDARY_SIDE="left_handle"
elif [[ "$RUN_RIGHT_ATTRS" -eq 1 ]]; then
    BOUNDARY_SIDE="right_handle"
fi

if [[ -n "$BOUNDARY_SIDE" ]]; then
    if [[ -e "${GAMEPAD_DEV}${BOUNDARY_SIDE}/auto_sleep_time" ]]; then
        echo -n "  ${BOUNDARY_SIDE}/auto_sleep_time out-of-range (256) ... "
        if echo "256" | tee "${GAMEPAD_DEV}${BOUNDARY_SIDE}/auto_sleep_time" > /dev/null 2>&1; then
            fail "should have rejected 256"
        else
            pass "correctly rejected"
        fi
    fi

    if [[ -e "${GAMEPAD_DEV}${BOUNDARY_SIDE}/rumble_mode" ]]; then
        echo -n "  ${BOUNDARY_SIDE}/rumble_mode invalid value ... "
        if echo "turbo" | tee "${GAMEPAD_DEV}${BOUNDARY_SIDE}/rumble_mode" > /dev/null 2>&1; then
            fail "should have rejected 'turbo'"
        else
            pass "correctly rejected"
        fi
    fi
else
    skip "handle boundary tests — excluded by selection"
fi

if [[ "$RUN_RGB" -eq 1 ]]; then
if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}speed" ]]; then
    echo -n "  RGB speed out-of-range (101) ... "
    if echo "101" | tee "${LED_DEV}speed" > /dev/null 2>&1; then
        fail "should have rejected 101"
    else
        pass "correctly rejected"
    fi
fi

if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}profile" ]]; then
    echo -n "  RGB profile out-of-range (4) ... "
    if echo "4" | tee "${LED_DEV}profile" > /dev/null 2>&1; then
        fail "should have rejected 4"
    else
        pass "correctly rejected"
    fi
fi

if [[ -n "$LED_DEV" ]] && [[ -e "${LED_DEV}effect" ]]; then
    echo -n "  RGB effect invalid value ... "
    if echo "strobe" | tee "${LED_DEV}effect" > /dev/null 2>&1; then
        fail "should have rejected 'strobe'"
    else
        pass "correctly rejected"
    fi
fi
else
    skip "rgb boundary tests — excluded by selection"
fi
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Restoring original state ==="

if [[ "$RUN_MCU" -eq 1 ]]; then
# mode first — causes re-enumeration so resolve path after
echo -n "  mode -> '$ORIG_MODE' ... "
echo "$ORIG_MODE" | tee "${GAMEPAD_DEV}mode" > /dev/null 2>&1 || true
sleep 3
refresh_gamepad_dev 5 || true
echo "done"
fi

restore_attr() {
    local path="$1" val="$2" label="$3"
    if [[ -n "$val" ]] && [[ -e "$path" ]]; then
        echo -n "  ${label} -> '${val}' ... "
        echo "$val" | tee "$path" > /dev/null 2>&1 || true
        sleep .1
        echo "done"
    fi
}

[[ "$RUN_MCU" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}os_mode"                          "$ORIG_OS_MODE"       "os_mode"
[[ "$RUN_MCU" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}fps_mode_dpi"                     "$ORIG_FPS_DPI"       "fps_mode_dpi"
[[ "$RUN_MCU" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}rumble_intensity"                 "$ORIG_RUMBLE"        "rumble_intensity"

[[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && restore_attr "${GAMEPAD_DEV}left_handle/auto_sleep_time"      "$ORIG_L_SLEEP"       "left_handle/auto_sleep_time"
[[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}right_handle/auto_sleep_time"     "$ORIG_R_SLEEP"       "right_handle/auto_sleep_time"
[[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && restore_attr "${GAMEPAD_DEV}left_handle/imu_bypass_enabled"   "$ORIG_L_IMU_BYPASS"  "left_handle/imu_bypass_enabled"
[[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}right_handle/imu_bypass_enabled"  "$ORIG_R_IMU_BYPASS"  "right_handle/imu_bypass_enabled"
[[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && restore_attr "${GAMEPAD_DEV}left_handle/imu_enabled"          "$ORIG_L_IMU_EN"      "left_handle/imu_enabled"
[[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}right_handle/imu_enabled"         "$ORIG_R_IMU_EN"      "right_handle/imu_enabled"
[[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && restore_attr "${GAMEPAD_DEV}left_handle/rumble_mode"          "$ORIG_L_RUMBLE_MODE" "left_handle/rumble_mode"
[[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}right_handle/rumble_mode"         "$ORIG_R_RUMBLE_MODE" "right_handle/rumble_mode"
[[ "$RUN_LEFT_ATTRS" -eq 1 ]]  && restore_attr "${GAMEPAD_DEV}left_handle/rumble_notification"  "$ORIG_L_RUMBLE_NOTIF" "left_handle/rumble_notification"
[[ "$RUN_RIGHT_ATTRS" -eq 1 ]] && restore_attr "${GAMEPAD_DEV}right_handle/rumble_notification" "$ORIG_R_RUMBLE_NOTIF" "right_handle/rumble_notification"

if [[ "$RUN_TOUCHPAD" -eq 1 ]]; then
restore_attr "${GAMEPAD_DEV}touchpad/enabled"             "$ORIG_TP_ENABLED"  "touchpad/enabled"
restore_attr "${GAMEPAD_DEV}touchpad/vibration_enabled"   "$ORIG_TP_VIB_EN"   "touchpad/vibration_enabled"
restore_attr "${GAMEPAD_DEV}touchpad/vibration_intensity" "$ORIG_TP_VIB_INT"  "touchpad/vibration_intensity"
fi

if [[ "$RUN_RGB" -eq 1 ]]; then
restore_attr "${LED_DEV}effect"     "$ORIG_LED_EFFECT"     "LED effect"
restore_attr "${LED_DEV}enabled"    "$ORIG_LED_ENABLED"    "LED enabled"
restore_attr "${LED_DEV}mode"       "$ORIG_LED_MODE"       "LED mode"
restore_attr "${LED_DEV}speed"      "$ORIG_LED_SPEED"      "LED speed"
restore_attr "${LED_DEV}profile"    "$ORIG_LED_PROFILE"    "LED profile"
restore_attr "${LED_DEV}multi_intensity" "$ORIG_LED_MULTI" "LED multi_intensity"
restore_attr "${LED_DEV}brightness" "$ORIG_LED_BRIGHTNESS" "LED brightness"
fi
echo

# ── dmesg helper ─────────────────────────────────────────────────────────────
# check_dmesg_since <iso_timestamp> <section_label>
check_dmesg_since() {
    local since="$1" label="$2"
    local errors=""

    if [[ -n "$since" ]]; then
        errors=$(dmesg --time-format iso 2>/dev/null \
            | awk -v start="$since" '$1 >= start' \
            | grep -i "hid-lenovo-go\|hid_lenovo_go" \
            | grep -iE "error|warn|fail|bug|oops|panic|null|invalid" \
            || true)
    else
        errors=$(dmesg 2>/dev/null \
            | tail -500 \
            | grep -i "hid-lenovo-go\|hid_lenovo_go" \
            | grep -iE "error|warn|fail|bug|oops|panic|null|invalid" \
            || true)
    fi

    if [[ -n "$errors" ]]; then
        echo -e "  ${RED}Kernel messages during ${label}:${NC}"
        echo "$errors" | while IFS= read -r line; do
            echo -e "  ${RED}>>>${NC} $line"
        done
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}No hid-lenovo-go errors or warnings during ${label}${NC}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo "=== dmesg check: test run ==="
check_dmesg_since "$TEST_START_TIME" "test run"
echo

# ══════════════════════════════════════════════════════════════════════════════
echo "=== modprobe unload/reload ==="
if [[ "$ANY_ONLY" -eq 1 ]]; then
    skip "modprobe reload — skipped due to --* scoping (whole-device operation)"
elif ! modinfo hid_lenovo_go > /dev/null 2>&1; then
    skip "hid_lenovo_go module not found (built-in?), skipping modprobe test"
else
    UNLOAD_TIME=$(dmesg --time-format iso 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    echo -n "  modprobe -r hid_lenovo_go ... "
    if modprobe -r hid_lenovo_go 2>/dev/null; then
        echo "done"
    else
        fail "modprobe -r hid_lenovo_go failed"
    fi
    sleep 1
    check_dmesg_since "$UNLOAD_TIME" "modprobe -r"

    LOAD_TIME=$(dmesg --time-format iso 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    echo -n "  modprobe hid_lenovo_go ... "
    if modprobe hid_lenovo_go 2>/dev/null; then
        echo "done"
    else
        fail "modprobe hid_lenovo_go failed"
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
