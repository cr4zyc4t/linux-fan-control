#!/bin/bash

set -u

MIN_TEMP=50
MAX_TEMP=70

MIN_PWM=51
MAX_PWM=230

INTERVAL=3

# Find the NCT6798 hwmon device dynamically.
HWMON_DIR=""

for dir in /sys/class/hwmon/hwmon*; do
    if [ -f "$dir/name" ] && [ "$(cat "$dir/name")" = "nct6798" ]; then
        HWMON_DIR="$dir"
        break
    fi
done

if [ -z "$HWMON_DIR" ]; then
    echo "ERROR: nct6798 hwmon device not found" >&2
    exit 1
fi

PWM_PATH="$HWMON_DIR/pwm4"
PWM_ENABLE_PATH="$HWMON_DIR/pwm4_enable"

# PWM2 = CPU fan duty (BIOS keeps driving it, we only read it).
CPU_PWM_PATH="$HWMON_DIR/pwm2"

# PWM1 = rear case fan, follows max(CPU duty, GPU duty).
REAR_PWM_PATH="$HWMON_DIR/pwm1"
REAR_PWM_ENABLE_PATH="$HWMON_DIR/pwm1_enable"

if [ ! -e "$PWM_PATH" ] || [ ! -e "$PWM_ENABLE_PATH" ]; then
    echo "ERROR: pwm4 not found on $HWMON_DIR" >&2
    exit 1
fi

if [ ! -e "$CPU_PWM_PATH" ] || [ ! -e "$REAR_PWM_PATH" ] || [ ! -e "$REAR_PWM_ENABLE_PATH" ]; then
    echo "ERROR: pwm1/pwm2 not found on $HWMON_DIR" >&2
    exit 1
fi

echo "Using $HWMON_DIR"
echo "PWM: $PWM_PATH (GPU fan) + $REAR_PWM_PATH (rear fan)"

# Put PWM4 and PWM1 into manual mode.
echo 1 > "$PWM_ENABLE_PATH"
echo 1 > "$REAR_PWM_ENABLE_PATH"

while true; do
    # Get temperatures from all NVIDIA GPUs.
    temps=$(nvidia-smi --query-gpu=temperature.gpu \
                       --format=csv,noheader,nounits 2>/dev/null)

    # Read current CPU fan duty from BIOS-driven PWM2.
    cpu_pwm=$(cat "$CPU_PWM_PATH" 2>/dev/null)
    [[ "$cpu_pwm" =~ ^[0-9]+$ ]] || cpu_pwm=0

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

    echo "$(date '+%Y-%m-%d %H:%M:%S') GPU=${max_temp}°C PWM=${pwm} CPU=${cpu_pwm} REAR=${rear_pwm}"

    sleep "$INTERVAL"
done
