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
MIN_TEMP=45
MAX_TEMP=75

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
# 2040 rpm measured 2026-11-28 on the current cooler: pwm1_enable=1,
# pwm1=255, RPM read at plateau (old Z490 cooler was 2343).
CPU_FAN_FULL_RPM=2040

# SYS_FAN2 / GPU intake fan (pwm3, tach fan3)
INTAKE_MAX_PWM=255

# SYS_FAN1 / rear case fan (pwm2, tach fan2)
REAR_MAX_PWM=200

# SYS_FAN4 / second GPU support fan (IT8792E chip: pwm3, tach fan3)
# NOTE: this fan has a stop/dead zone - at the 20% idle duty produced by the
# curve below it does not spin at all. SUPPORT=20%(0rpm) in the log is normal
# and does NOT mean the PWM write failed; it only starts once the duty rises.
SUPPORT_MAX_PWM=255

# Gigabyte X570 AORUS ULTRA (SIV 0x4008090B), frankcrawford it87 fork.
# Mapping verified against "Sensors configs/Gigabyte/configs/
# gigabyte-it87-amd.conf" SIV 0x4008090B stanza (boards: X570 AORUS PRO /
# PRO WIFI / ULTRA), physical wiring confirmed by the user 2026-11-28:
#   rear fan -> SYS_FAN1, GPU intake -> SYS_FAN2, GPU support -> SYS_FAN4.
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
#             sensors should show "it8688_4008090b" once mmio works
#
# Without mmio=1 the chip is not found and this script aborts. Do NOT
# use the in-tree kernel it87 - it lacks the Gigabyte SIV/H2RAM support.
#
#   IT8688E (this script), X570 AORUS ULTRA header layout:
#     fan1/pwm1 = CPU_FAN    -> left to BIOS. Same as on the Z490, the EC
#                              runs the SmartFan curve but the duty register
#                              is NOT updated in auto mode, so CPU duty is
#                              estimated from the tachometer instead.
#     fan2/pwm2 = SYS_FAN1   -> rear case fan (max(CPU %, GPU %))
#     fan3/pwm3 = SYS_FAN2   -> GPU intake fan (follows GPU temp)
#     fan4/pwm4 = PCH_FAN    -> left to BIOS (X570 chipset fan header,
#                              combo with SYS_FAN3; nothing of ours there)
#     fan5/pwm5 = CPU_OPT    -> left to BIOS (follows CPU cooler)
#   IT8792E (second chip, also driven here):
#     fan1/pwm1 = SYS_FAN5_PUMP -> empty header
#     fan2/pwm2 = SYS_FAN6_PUMP -> empty header
#     fan3/pwm3 = SYS_FAN4      -> GPU support fan (follows GPU temp)
#   The it8792 is the chip that announced "H2RAM
#     SmartFan ... channels=3" in dmesg; the it8688 rev 1 never does, which
#     is exactly why its pwmN sysfs reads stay stale. Trust fanN_input, not
#     pwmN, when checking what the system is really doing.
#
# enable semantics (it87 fork): 1 = manual (ours), 2 = BIOS SmartFan.
# The chip registers as e.g. "it8688_4008090b" (SIV hash in the name),
# so match by prefix, not exact string.

HWMON_DIR=""
HWMON_DIR_8792=""

for dir in /sys/class/hwmon/hwmon*; do
    if [ -f "$dir/name" ]; then
        chip_name=$(cat "$dir/name")
        if [[ "$chip_name" == it8688* ]] && [ -z "$HWMON_DIR" ]; then
            HWMON_DIR="$dir"
        elif [[ "$chip_name" == it8792* ]] && [ -z "$HWMON_DIR_8792" ]; then
            HWMON_DIR_8792="$dir"
        fi
    fi
done

if [ -z "$HWMON_DIR" ]; then
    echo "ERROR: it8688 hwmon device not found (is the it87 fork loaded with mmio=1?)" >&2
    exit 1
fi

if [ -z "$HWMON_DIR_8792" ]; then
    echo "ERROR: it8792 hwmon device not found (SYS_FAN4 lives on this chip)" >&2
    exit 1
fi

# fan1 = CPU_FAN tachometer (BIOS keeps driving CPU_FAN).
# The EC does not sync the pwm duty register in auto mode,
# so CPU duty % is estimated as fan RPM vs its measured 100% maximum.
CPU_FAN_RPM_PATH="$HWMON_DIR/fan1_input"

# pwm2 = SYS_FAN1 rear case fan, follows max(CPU %, GPU %).
REAR_PWM_PATH="$HWMON_DIR/pwm2"
REAR_PWM_ENABLE_PATH="$HWMON_DIR/pwm2_enable"
REAR_RPM_PATH="$HWMON_DIR/fan2_input"

# pwm3 = SYS_FAN2 GPU intake fan, follows GPU temp.
INTAKE_PWM_PATH="$HWMON_DIR/pwm3"
INTAKE_PWM_ENABLE_PATH="$HWMON_DIR/pwm3_enable"
INTAKE_RPM_PATH="$HWMON_DIR/fan3_input"

# IT8792E pwm3 = SYS_FAN4 GPU support fan, follows GPU temp.
SUPPORT_PWM_PATH="$HWMON_DIR_8792/pwm3"
SUPPORT_PWM_ENABLE_PATH="$HWMON_DIR_8792/pwm3_enable"
SUPPORT_RPM_PATH="$HWMON_DIR_8792/fan3_input"

if [ ! -e "$REAR_PWM_PATH" ] || [ ! -e "$REAR_PWM_ENABLE_PATH" ] \
   || [ ! -e "$INTAKE_PWM_PATH" ] || [ ! -e "$INTAKE_PWM_ENABLE_PATH" ] \
   || [ ! -e "$CPU_FAN_RPM_PATH" ]; then
    echo "ERROR: pwm2/pwm3/fan1 not found on $HWMON_DIR" >&2
    exit 1
fi

if [ ! -e "$SUPPORT_PWM_PATH" ] || [ ! -e "$SUPPORT_PWM_ENABLE_PATH" ]; then
    echo "ERROR: pwm3 not found on $HWMON_DIR_8792" >&2
    exit 1
fi

# On exit (Ctrl-C, kill, crash) hand all channels back to the BIOS
# SmartFan engine; otherwise the fans stay frozen at the last duty we
# wrote forever, because enable=1 blocks the EC from controlling them.
#
# Bash gotcha: a trapped signal does NOT kill the script by itself -
# the trap handler runs and the script continues. So INT/TERM must
# exit explicitly; the EXIT trap then does the single restore.
restore_bios() {
    echo 2 > "$INTAKE_PWM_ENABLE_PATH" 2>/dev/null
    echo 2 > "$REAR_PWM_ENABLE_PATH" 2>/dev/null
    echo 2 > "$SUPPORT_PWM_ENABLE_PATH" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') restored SYS_FAN1/SYS_FAN2/SYS_FAN4 to BIOS (enable=2)"
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
echo "Using $HWMON_DIR_8792 ($(cat "$HWMON_DIR_8792/name"))"
echo "PWM: $INTAKE_PWM_PATH (SYS_FAN2/GPU intake) + $REAR_PWM_PATH (SYS_FAN1/rear fan) + $SUPPORT_PWM_PATH (SYS_FAN4/GPU support fan)"
echo "Max PWM (100%): intake=$INTAKE_MAX_PWM rear=$REAR_MAX_PWM support=$SUPPORT_MAX_PWM (of 255)"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: curve is calculated and logged only, fans stay under BIOS control"
else
    echo "Ctrl-C hands control back to the BIOS (pwm*_enable=2)"
fi

# Put SYS_FAN1, SYS_FAN2 and SYS_FAN4 into manual mode.
if [ "$DRY_RUN" -eq 0 ]; then
    echo 1 > "$INTAKE_PWM_ENABLE_PATH"
    echo 1 > "$REAR_PWM_ENABLE_PATH"
    echo 1 > "$SUPPORT_PWM_ENABLE_PATH"
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
        write_pwm "$(pct_to_pwm 100 "$INTAKE_MAX_PWM")" "$INTAKE_PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$REAR_MAX_PWM")" "$REAR_PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$SUPPORT_MAX_PWM")" "$SUPPORT_PWM_PATH"
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
        write_pwm "$(pct_to_pwm 100 "$INTAKE_MAX_PWM")" "$INTAKE_PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$REAR_MAX_PWM")" "$REAR_PWM_PATH"
        write_pwm "$(pct_to_pwm 100 "$SUPPORT_MAX_PWM")" "$SUPPORT_PWM_PATH"
        echo "$(date '+%Y-%m-%d %H:%M:%S') INVALID TEMP -> 100%"
        sleep "$INTERVAL"
        continue
    fi

    # Linear percent curve:
    #
    # <= MIN_TEMP -> MIN_PERCENT
    # MIN_MAX_TEMP -> linear
    # >= MAX_TEMP -> MAX_PERCENT

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

    write_pwm "$(pct_to_pwm "$gpu_pct" "$INTAKE_MAX_PWM")" "$INTAKE_PWM_PATH"

    # GPU support fan (SYS_FAN4) = same GPU curve as the intake fan.
    write_pwm "$(pct_to_pwm "$gpu_pct" "$SUPPORT_MAX_PWM")" "$SUPPORT_PWM_PATH"

    # Rear fan (SYS_FAN1) = max(CPU %, GPU %).
    rear_pct="$gpu_pct"
    if (( cpu_pct > rear_pct )); then
        rear_pct="$cpu_pct"
    fi

    write_pwm "$(pct_to_pwm "$rear_pct" "$REAR_MAX_PWM")" "$REAR_PWM_PATH"

    # Log with tachometers: pwmN sysfs is stale on this chip, so fan
    # RPM is the only proof the writes above actually reached the fan.
    intake_rpm=$(cat "$INTAKE_RPM_PATH" 2>/dev/null)
    rear_rpm=$(cat "$REAR_RPM_PATH" 2>/dev/null)
    support_rpm=$(cat "$SUPPORT_RPM_PATH" 2>/dev/null)
    echo "$(date '+%Y-%m-%d %H:%M:%S') GPU=${max_temp}°C INTAKE=${gpu_pct}%(${intake_rpm}rpm) CPU=${cpu_rpm}rpm/${cpu_pct}% REAR=${rear_pct}%(${rear_rpm}rpm) SUPPORT=${gpu_pct}%(${support_rpm}rpm)"

    sleep "$INTERVAL"
done
