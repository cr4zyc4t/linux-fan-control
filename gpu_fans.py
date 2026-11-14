#!/usr/bin/env python3
"""
gpu_fans.py - show the speed of EVERY fan on an NVIDIA GPU, plus temps and power.

nvidia-smi only prints one aggregate fan %, but NVML has per-fan APIs:
  * nvmlDeviceGetNumFans(handle)              -> number of fans
  * nvmlDeviceGetFanSpeed_v2(handle, idx)     -> duty cycle % of fan idx
  * nvmlDeviceGetFanSpeedRPM(handle, &info)   -> real RPM of fan idx (NVML >= 12)
  * nvmlDeviceGetPowerUsage(handle, &mW)      -> current power draw
  * nvmlDeviceGetPowerManagementLimit(handle, &mW) -> set power limit

Uses ctypes against libnvidia-ml.so, so no pip installs are needed.

Usage:
    python3 gpu_fans.py            # every GPU, every fan, once
    python3 gpu_fans.py 0          # only GPU 0
    python3 gpu_fans.py -i 2       # update every 2 seconds
    python3 gpu_fans.py 1 --interval 0.5   # GPU 1, twice a second
"""

import argparse
import ctypes as C
import sys
import time

NVML_SUCCESS = 0
NVML_ERROR_NOT_SUPPORTED = 3
NVML_FAN_REMOVED = 0x00000002  # NVML_FAN_REMOVED: parameter sentinel

# NVMLFanSpeedInfo (nvml.h): 24 bytes -> 6 x u32, no pointers
class FanSpeedInfo(C.Structure):
    _fields_ = [
        ("version", C.c_uint),      # set to 1
        ("fanType", C.c_uint),      # in: NVML_FAN_REMOVED etc.; 0 = normal
        ("speedType", C.c_uint),    # out: NVML_FAN_SPEED_TYPE_NORMAL=0 / TARGET=1
        ("fan", C.c_uint),          # in: which fan, 0-based
        ("speed", C.c_float),       # out: RPM
        ("reserved", C.c_uint),
    ]


def load_nvml():
    for name in ("libnvidia-ml.so.1", "libnvidia-ml.so", "nvidia-ml.dll"):
        try:
            return C.CDLL(name)
        except OSError:
            continue
    sys.exit("ERROR: libnvidia-ml not found - is the NVIDIA driver installed?")


def err(handle, fn, rc):
    msg = b"?"
    try:
        buf = C.create_string_buffer(256)
        if handle.nvmlErrorString(rc, C.byref(buf), 256) == NVML_SUCCESS:
            msg = buf.value
    except Exception:
        pass
    print(f"ERROR: {fn} failed: rc={rc} ({msg.decode(errors='replace')})")
    sys.exit(1)


def fan_speed(nvml, dev, fan_idx, rpm_supported):
    """Try the RPM API; on any failure fall back to duty-cycle %."""
    if rpm_supported:
        info = FanSpeedInfo()
        info.version = 1
        info.fanType = 0          # normal (non-removed) fan
        info.fan = fan_idx
        rc = nvml.nvmlDeviceGetFanSpeedRPM(dev, C.byref(info))
        if rc == NVML_SUCCESS:
            return f"{info.speed:7.0f} rpm"
        # NO_DATA / NOT_SUPPORTED is common on consumer cards -> use %
    speed = C.c_uint()
    rc = nvml.nvmlDeviceGetFanSpeed_v2(dev, fan_idx, C.byref(speed))
    if rc == NVML_SUCCESS:
        return f"{speed.value:6d} %   (duty)"
    return f"   n/a   (rc={rc})"


def get_temp(nvml, dev, sensor):
    """nvmlDeviceGetTemperature -> '57 C' or 'n/a'. sensor: 0=GPU 1=memory."""
    t = C.c_uint()
    rc = nvml.nvmlDeviceGetTemperature(dev, sensor, C.byref(t))
    return f"{t.value} C" if rc == NVML_SUCCESS else "n/a"


def get_power_mw(nvml, dev, fn):
    """nvmlDeviceGetPowerUsage / GetPowerManagementLimit -> milliwatts or None."""
    mw = C.c_uint()
    rc = getattr(nvml, fn)(dev, C.byref(mw))
    return mw.value if rc == NVML_SUCCESS else None


def render_gpus(nvml, want, rpm_supported):
    """Build the display lines for the requested GPUs."""
    lines = []
    for i in want:
        dev = C.c_void_p()
        rc = nvml.nvmlDeviceGetHandleByIndex_v2(i, C.byref(dev))
        if rc != NVML_SUCCESS:
            err(nvml, "nvmlDeviceGetHandleByIndex", rc)

        name = C.create_string_buffer(96)
        nvml.nvmlDeviceGetName(dev, name, 96)

        nfans = C.c_uint()
        rc = nvml.nvmlDeviceGetNumFans(dev, C.byref(nfans))
        if rc != NVML_SUCCESS or nfans.value == 0:
            # older API reports one aggregate fan
            nfans.value = 1

        lines.append(f"GPU {i}: {name.value.decode(errors='replace')}  "
                     f"({nfans.value} fan{'s' if nfans.value != 1 else ''})")
        line = f"  temp: gpu {get_temp(nvml, dev, 0)}"
        mem = get_temp(nvml, dev, 1)
        if mem != "n/a":
            line += f", memory {mem}"
        lines.append(line)
        usage = get_power_mw(nvml, dev, "nvmlDeviceGetPowerUsage")
        limit = get_power_mw(nvml, dev, "nvmlDeviceGetPowerManagementLimit")
        if usage is not None or limit is not None:
            u = f"{usage / 1000:.0f}" if usage is not None else "n/a"
            line = f"  power: {u}"
            if limit is not None:
                line += f" / {limit / 1000:.0f}"
            line += " W"
            lines.append(line)
        for f in range(nfans.value):
            lines.append(f"  fan {f}: {fan_speed(nvml, dev, f, rpm_supported)}")
    return lines


def main():
    ap = argparse.ArgumentParser(description="Per-fan speed, temps and power for NVIDIA GPUs")
    ap.add_argument("gpu", nargs="?", type=int, help="GPU index (default: all)")
    ap.add_argument("-i", "--interval", "-w", "--watch", type=float, metavar="SEC",
                    help="update interval in seconds (default: print once)")
    args = ap.parse_args()

    nvml = load_nvml()
    rc = nvml.nvmlInit_v2()
    if rc != NVML_SUCCESS:
        sys.exit(f"ERROR: nvmlInit failed, rc={rc}")

    count = C.c_uint()
    rc = nvml.nvmlDeviceGetCount_v2(C.byref(count))
    if rc != NVML_SUCCESS:
        err(nvml, "nvmlDeviceGetCount", rc)

    # nvmlDeviceGetFanSpeedRPM only exists on driver >= 525 (NVML 12)
    rpm_supported = True
    try:
        nvml.nvmlDeviceGetFanSpeedRPM
    except AttributeError:
        rpm_supported = False

    try:
        want = range(count.value) if args.gpu is None else [args.gpu]
        if args.gpu is not None and not 0 <= args.gpu < count.value:
            sys.exit(f"ERROR: GPU index {args.gpu} out of range (0..{count.value - 1})")

        prev_lines = 0
        while True:
            lines = render_gpus(nvml, want, rpm_supported)
            if not args.interval:
                print("\n".join(lines))
                break
            out = "\n".join(lines)
            if prev_lines:
                # cursor back to the top of the previous frame, overwrite in
                # place, then erase anything left below (no scroll, no clear)
                out = f"\x1b[{prev_lines}F" + out
            out += "\x1b[J\n"  # erase to end of screen
            sys.stdout.write(out)
            sys.stdout.flush()
            prev_lines = len(lines)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n")
    finally:
        nvml.nvmlShutdown()


if __name__ == "__main__":
    main()
