#!/bin/bash

set -u

MIN_TEMP=50
MAX_TEMP=70

MIN_PWM=51
MAX_PWM=230

INTERVAL=3

# Gigabyte Z490 AORUS PRO AX fan layout (ITE IT8688E via MMIO, frankcrawford it87 fork):
#
#   fan1/pwm1 = CPU_FAN   -> BIOS keeps driving it; in auto mode the duty
#                            register stays stale, so we estimate CPU duty
#                            from the tachometer (RPM / max RPM) instead
#   fan2/pwm2 = empty header
#   fan3/pwm3 = rear case fan (max(CPU duty, GPU duty))
#   fan4/pwm4 = GPU intake fan (SYS_FAN2, follows GPU temp)
#   fan5/pwm5 = CPU_OPT    -> left to BIOS (follows CPU cooler)
#
# The chip registers as e.g. "it8688_6008090b" (H2RAM hash in the name),
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
# The SmartFan engine does not sync the pwm duty register in auto mode,
# so CPU duty is estimated as fan RPM vs its measured 100% maximum.
CPU_FAN_RPM_PATH="$HWMON_DIR/fan1_input"
CPU_FAN_MAX_RPM=2235

# PWM3 = rear case fan, follows max(CPU duty, GPU duty).
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

echo "Using $HWMON_DIR ($(cat "$HWMON_DIR/name"))"
echo "PWM: $PWM_PATH (GPU intake) + $REAR_PWM_PATH (rear fan)"

# Put PWM4 and PWM3 into manual mode.
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
        echo "$MAX_PWM" > "$PWM_PATH"
        echo "$MAX_PWM" > "$REAR_PWM_PATH"
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
        echo "$MAX_PWM" > "$PWM_PATH"
        echo "$MAX_PWM" > "$REAR_PWM_PATH"
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

    echo "$pwm" > "$PWM_PATH"

    # Rear fan = max(CPU duty, GPU duty).
    rear_pwm="$pwm"
    if (( cpu_pwm > rear_pwm )); then
        rear_pwm="$cpu_pwm"
    fi

    echo "$rear_pwm" > "$REAR_PWM_PATH"

    echo "$(date '+%Y-%m-%d %H:%M:%S') GPU=${max_temp}°C PWM=${pwm} CPU=${cpu_rpm}rpm/${cpu_pwm} REAR=${rear_pwm}"

    sleep "$INTERVAL"
done
