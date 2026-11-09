#!/bin/bash

set -u

MIN_TEMP=50
MAX_TEMP=70

MIN_PWM=51
MAX_PWM=230

INTERVAL=3

# Gigabyte Z490 AORUS PRO AX / Z490 VISION D (SIV 0x6008090B), frankcrawford
# it87 fork. Labels verified via "Sensors configs/Gigabyte/install-sensorsd.sh".
#
#   IT8688E (this script):
#     fan1/pwm1 = CPU_FAN   -> left to BIOS. The EC runs the SmartFan curve,
#                              but the it8688 duty register is NOT updated
#                              (verified: stuck at 70 while the fan ramped
#                              1320->2343 RPM at PECI 76C), so CPU duty is
#                              estimated from the tachometer instead.
#     fan2/pwm2 = SYS_FAN1  -> empty header
#     fan3/pwm3 = SYS_FAN2  -> rear case fan (max(CPU duty, GPU duty))
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
# so CPU duty is estimated as fan RPM vs its measured 100% maximum
# (2343 RPM observed under all-core stress with the fan unobstructed).
CPU_FAN_RPM_PATH="$HWMON_DIR/fan1_input"
CPU_FAN_MAX_RPM=2343

# pwm3 = SYS_FAN2 rear case fan, follows max(CPU duty, GPU duty).
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
trap 'exit 0' INT TERM
trap restore_bios EXIT

# Write a duty value; if the channel no longer accepts writes (EBUSY =
# BIOS/SmartFan owns it again, e.g. a second controller or a stale
# enable=2), give up so systemd Restart= re-initializes us from scratch.
write_pwm() {
    if ! echo "$1" > "$2" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: lost control of $2 -> exiting" >&2
        exit 1
    fi
}

echo "Using $HWMON_DIR ($(cat "$HWMON_DIR/name"))"
echo "PWM: $PWM_PATH (SYS_FAN3/GPU intake) + $REAR_PWM_PATH (SYS_FAN2/rear fan)"
echo "Ctrl-C hands control back to the BIOS (pwm*_enable=2)"

# Put SYS_FAN3 and SYS_FAN2 into manual mode.
echo 1 > "$PWM_ENABLE_PATH"
echo 1 > "$REAR_PWM_ENABLE_PATH"

while true; do
    # Get temperatures from all NVIDIA GPUs.
    temps=$(nvidia-smi --query-gpu=temperature.gpu \
                       --format=csv,noheader,nounits 2>/dev/null)

    # Estimate current CPU fan duty from the BIOS-driven CPU_FAN tachometer.
    cpu_rpm=$(cat "$CPU_FAN_RPM_PATH" 2>/dev/null)
    [[ "$cpu_rpm" =~ ^[0-9]+$ ]] || cpu_rpm=0

    cpu_pwm=$(( cpu_rpm * 255 / CPU_FAN_MAX_RPM ))
    (( cpu_pwm > 255 )) && cpu_pwm=255

    # Fail safe if nvidia-smi fails.
    if [ -z "$temps" ]; then
        write_pwm "$MAX_PWM" "$PWM_PATH"
        write_pwm "$MAX_PWM" "$REAR_PWM_PATH"
        echo "$(date '+%Y-%m-%d %H:%M:%S') NVIDIA ERROR -> PWM=$MAX_PWM"
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
        write_pwm "$MAX_PWM" "$PWM_PATH"
        write_pwm "$MAX_PWM" "$REAR_PWM_PATH"
        echo "$(date '+%Y-%m-%d %H:%M:%S') INVALID TEMP -> PWM=$MAX_PWM"
        sleep "$INTERVAL"
        continue
    fi

    # Linear PWM curve:
    #
    # <= 50C -> 51
    # 50-70C -> 51-230
    # >= 70C -> 230

    if (( max_temp <= MIN_TEMP )); then
        pwm="$MIN_PWM"

    elif (( max_temp >= MAX_TEMP )); then
        pwm="$MAX_PWM"

    else
        pwm=$(( MIN_PWM +
            (max_temp - MIN_TEMP) *
            (MAX_PWM - MIN_PWM) /
            (MAX_TEMP - MIN_TEMP)
        ))
    fi

    write_pwm "$pwm" "$PWM_PATH"

    # Rear fan = max(CPU duty, GPU duty).
    rear_pwm="$pwm"
    if (( cpu_pwm > rear_pwm )); then
        rear_pwm="$cpu_pwm"
    fi

    write_pwm "$rear_pwm" "$REAR_PWM_PATH"

    # Log with tachometers: pwmN sysfs is stale on this chip, so fan
    # RPM is the only proof the writes above actually reached the fan.
    intake_rpm=$(cat "$HWMON_DIR/fan4_input" 2>/dev/null)
    rear_rpm=$(cat "$HWMON_DIR/fan3_input" 2>/dev/null)
    echo "$(date '+%Y-%m-%d %H:%M:%S') GPU=${max_temp}°C PWM=${pwm}(${intake_rpm}rpm) CPU=${cpu_rpm}rpm/${cpu_pwm} REAR=${rear_pwm}(${rear_rpm}rpm)"

    sleep "$INTERVAL"
done
