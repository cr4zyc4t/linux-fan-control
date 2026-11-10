#!/bin/bash

set -u

usage() {
    echo "Usage: $0 [-n|--dry-run]"
    echo "  -n, --dry-run  Calculate and log the fan curve only;"
    echo "                 do NOT touch pwm*/enable (BIOS keeps control)."
}

DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# Temperature -> duty curve, expressed in PERCENT (0-100).
# All control math happens in %, conversion to the 255-base sysfs
# register happens only at write time, inside pct_to_pwm().
#
# The curve tops out at 100%; loudness is limited via the per-fan
# *_MAX_PWM caps below (the register value that means 100%), not by
# clipping the duty here.
MIN_PERCENT=20
MAX_PERCENT=100

# Temperature bounds of the linear curve.
MIN_TEMP=50
MAX_TEMP=70

INTERVAL=3

# ---------------------------------------------------------------------------
# Per-fan configuration
#
#   <FAN>_MAX_PWM : the 255-base register value that means 100% for this fan.
#                   All control math is done in percent; 100% duty is simply
#                   written as this value. Lower it to cap the fan's top
#                   speed (e.g. 200 out of 255 ~= 78% absolute maximum).
# ---------------------------------------------------------------------------

# CPU_FAN (fan1, BIOS-driven tachometer only). Cannot be capped from here
# (the EC drives it); FULL_RPM is only used to estimate its duty %.
CPU_FAN_FULL_RPM=2343

# SYS_FAN3 / GPU intake fan (pwm4, tach fan4)
INTAKE_MAX_PWM=230

# SYS_FAN2 / rear case fan (pwm3, tach fan3)
REAR_MAX_PWM=200

# Gigabyte Z490 AORUS PRO AX / Z490 VISION D (SIV 0x6008090B), frankcrawford
# it87 fork. Labels verified via "Sensors configs/Gigabyte/install-sensorsd.sh".
#
# Driver provenance (for OS reinstalls) - DKMS version installed on this
# box was "it87/v2.0-6-gbd7a566.20261002":
#
#   repo    : https://github.com/frankcrawford/it87.git
#   commit  : bd7a566c8a60fe0308d67e26761e16260368191a
#             ("Merge pull request #140 from TsunamiMommy/fix-bridge",
#             2026-10-02, `git describe`: v2.0-6-gbd7a566)
#   install : git clone https://github.com/frankcrawford/it87.git
#             cd it87 && git checkout bd7a566c8a60fe0308d67e26761e16260368191a
#             sudo ./dkms-install.sh          # needs dkms + kernel headers
#   runtime : /etc/modprobe.d/it87.conf       -> "options it87 mmio=1"
#             /etc/modules-load.d/it87.conf   -> "it87" (load at boot)
#   verify  : dkms status | grep it87
#             sensors should show "it8688_6008090b" once mmio works
#
# Without mmio=1 the chip is not found and this script aborts. Do NOT
# use the in-tree kernel it87 - it lacks the Gigabyte SIV/H2RAM support.
#
#   IT8688E (this script):
#     fan1/pwm1 = CPU_FAN   -> left to BIOS. The EC runs the SmartFan curve,
#                              but the it8688 duty register is NOT updated
#                              (verified: stuck at 70 while the fan ramped
#                              1320->2343 RPM at PECI 76C), so CPU duty is
#                              estimated from the tachometer instead.
#     fan2/pwm2 = SYS_FAN1  -> empty header
#     fan3/pwm3 = SYS_FAN2  -> rear case fan (max(CPU %, GPU %))
#     fan4/pwm4 = SYS_FAN3  -> GPU intake fan (follows GPU temp)
#     fan5/pwm5 = CPU_OPT   -> left to BIOS (follows CPU cooler)
#   IT8792E (not touched here): SYS_FAN4, SYS_FAN5_PUMP, SYS_FAN6_PUMP - all
#     empty on this box. The it8792 is the chip that announced "H2RAM
#     SmartFan ... channels=3" in dmesg; the it8688 rev 1 never does, which
#     is exactly why its pwmN sysfs reads stay stale. Trust fanN_input, not
#     pwmN, when checking what the system is really doing.
#
# enable semantics (it87 fork): 1 = manual (ours), 2 = BIOS SmartFan.
# The chip registers as e.g. "it8688_6008090b" (SIV hash in the name),
# so match by prefix, not exact string.

HWMON_DIR=""

for dir in /sys/class/hwmon/hwmon*; do
    if [ -f "$dir/name" ] && [[ "$(cat "$dir/name")" == it8688* ]]; then
        HWMON_DIR="$dir"
        break
    fi
done

if [ -z "$HWMON_DIR" ]; then
    echo "ERROR: it8688 hwmon device not found (is the it87 fork loaded with mmio=1?)" >&2
    exit 1
fi

PWM_PATH="$HWMON_DIR/pwm4"
PWM_ENABLE_PATH="$HWMON_DIR/pwm4_enable"

# fan1 = CPU_FAN tachometer (BIOS keeps driving CPU_FAN).
# The EC does not sync the pwm duty register in auto mode,
# so CPU duty % is estimated as fan RPM vs its measured 100% maximum.
CPU_FAN_RPM_PATH="$HWMON_DIR/fan1_input"

# pwm3 = SYS_FAN2 rear case fan, follows max(CPU %, GPU %).
REAR_PWM_PATH="$HWMON_DIR/pwm3"
REAR_PWM_ENABLE_PATH="$HWMON_DIR/pwm3_enable"

if [ ! -e "$PWM_PATH" ] || [ ! -e "$PWM_ENABLE_PATH" ]; then
    echo "ERROR: pwm4 not found on $HWMON_DIR" >&2
    exit 1
fi

if [ ! -e "$CPU_FAN_RPM_PATH" ] || [ ! -e "$REAR_PWM_PATH" ] || [ ! -e "$REAR_PWM_ENABLE_PATH" ]; then
    echo "ERROR: fan1/pwm3 not found on $HWMON_DIR" >&2
    exit 1
fi

# On exit (Ctrl-C, kill, crash) hand both channels back to the BIOS
# SmartFan engine; otherwise the fans stay frozen at the last duty we
# wrote forever, because enable=1 blocks the EC from controlling them.
#
# Bash gotcha: a trapped signal does NOT kill the script by itself -
# the trap handler runs and the script continues. So INT/TERM must
# exit explicitly; the EXIT trap then does the single restore.
restore_bios() {
    echo 2 > "$PWM_ENABLE_PATH" 2>/dev/null
    echo 2 > "$REAR_PWM_ENABLE_PATH" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') restored SYS_FAN2/SYS_FAN3 to BIOS (enable=2)"
}
if [ "$DRY_RUN" -eq 0 ]; then
    trap 'exit 0' INT TERM
    trap restore_bios EXIT
fi

# Write a duty value; if the channel no longer accepts writes (EBUSY =
# BIOS/SmartFan owns it again, e.g. a second controller or a stale
# enable=2), give up so systemd Restart= re-initializes us from scratch.
# In dry-run mode nothing is written at all.
write_pwm() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if ! echo "$1" > "$2" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: lost control of $2 -> exiting" >&2
        exit 1
    fi
}

# Convert a duty PERCENT (0-100) into the 255-base sysfs value, where
# <max_pwm> is the register value that represents 100% for this fan.
#
#   pwm = percent * max_pwm / 100
pct_to_pwm() {
    local percent="$1" max_pwm="$2"
    (( percent > 100 )) && percent=100
    (( percent < 0 )) && percent=0
    echo $(( percent * max_pwm / 100 ))
}

# Convert a tachometer RPM into duty PERCENT for the BIOS-driven CPU fan.
rpm_to_pct() {
    local rpm="$1" full_rpm="$2"
    local pct=$(( rpm * 100 / full_rpm ))
    (( pct > 100 )) && pct=100
    echo "$pct"
}

echo "Using $HWMON_DIR ($(cat "$HWMON_DIR/name"))"
echo "PWM: $PWM_PATH (SYS_FAN3/GPU intake) + $REAR_PWM_PATH (SYS_FAN2/rear fan)"
echo "Max PWM (100%): intake=$INTAKE_MAX_PWM rear=$REAR_MAX_PWM (of 255)"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: curve is calculated and logged only, fans stay under BIOS control"
else
    echo "Ctrl-C hands control back to the BIOS (pwm*_enable=2)"
fi

# Put SYS_FAN3 and SYS_FAN2 into manual mode.
if [ "$DRY_RUN" -eq 0 ]; then
    echo 1 > "$PWM_ENABLE_PATH"
    echo 1 > "$REAR_PWM_ENABLE_PATH"
fi

while true; do
    # Get temperatures from all NVIDIA GPUs.
    temps=$(nvidia-smi --query-gpu=temperature.gpu \
                       --format=csv,noheader,nounits 2>/dev/null)

    # Estimate current CPU fan duty % from the BIOS-driven CPU_FAN tachometer.
    cpu_rpm=$(cat "$CPU_FAN_RPM_PATH" 2>/dev/null)
    [[ "$cpu_rpm" =~ ^[0-9]+$ ]] || cpu_rpm=0
    cpu_pct=$(rpm_to_pct "$cpu_rpm" "$CPU_FAN_FULL_RPM")

    # Fail safe if nvidia-smi fails.
    if [ -z "$temps" ]; then
        write_pwm "$(pct_to_pwm 100 "$INTAKE_MAX_PWM")" "$PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$REAR_MAX_PWM")" "$REAR_PWM_PATH"
        echo "$(date '+%Y-%m-%d %H:%M:%S') NVIDIA ERROR -> 100%"
        sleep "$INTERVAL"
        continue
    fi

    # Find the hottest GPU.
    max_temp=0

    while read -r temp; do
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > max_temp )); then
            max_temp="$temp"
        fi
    done <<< "$temps"

    # Fail safe if no valid temperature was found.
    if (( max_temp == 0 )); then
        write_pwm "$(pct_to_pwm 100 "$INTAKE_MAX_PWM")" "$PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$REAR_MAX_PWM")" "$REAR_PWM_PATH"
        echo "$(date '+%Y-%m-%d %H:%M:%S') INVALID TEMP -> 100%"
        sleep "$INTERVAL"
        continue
    fi

    # Linear percent curve:
    #
    # <= 50C -> MIN_PERCENT
    # 50-70C -> MIN_PERCENT-MAX_PERCENT
    # >= 70C -> MAX_PERCENT

    if (( max_temp <= MIN_TEMP )); then
        gpu_pct="$MIN_PERCENT"

    elif (( max_temp >= MAX_TEMP )); then
        gpu_pct="$MAX_PERCENT"

    else
        gpu_pct=$(( MIN_PERCENT +
            (max_temp - MIN_TEMP) *
            (MAX_PERCENT - MIN_PERCENT) /
            (MAX_TEMP - MIN_TEMP)
        ))
    fi

    write_pwm "$(pct_to_pwm "$gpu_pct" "$INTAKE_MAX_PWM")" "$PWM_PATH"

    # Rear fan = max(CPU %, GPU %).
    rear_pct="$gpu_pct"
    if (( cpu_pct > rear_pct )); then
        rear_pct="$cpu_pct"
    fi

    write_pwm "$(pct_to_pwm "$rear_pct" "$REAR_MAX_PWM")" "$REAR_PWM_PATH"

    # Log with tachometers: pwmN sysfs is stale on this chip, so fan
    # RPM is the only proof the writes above actually reached the fan.
    intake_rpm=$(cat "$HWMON_DIR/fan4_input" 2>/dev/null)
    rear_rpm=$(cat "$HWMON_DIR/fan3_input" 2>/dev/null)
    echo "$(date '+%Y-%m-%d %H:%M:%S') GPU=${max_temp}°C INTAKE=${gpu_pct}%(${intake_rpm}rpm) CPU=${cpu_rpm}rpm/${cpu_pct}% REAR=${rear_pct}%(${rear_rpm}rpm)"

    sleep "$INTERVAL"
done
