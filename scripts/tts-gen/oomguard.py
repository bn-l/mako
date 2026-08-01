"""In-process OOM guard for the TTS generation scripts.

TTS generation loads multi-gigabyte models (fish-audio-s2-pro bf16 is ~10 GB, VoxCPM2
runs fp32 on MPS because MPS won't take its bf16). When available RAM runs out macOS
does not fail fast — it thrashes into a multi-minute hang that takes the whole machine
down. So we do not wait for an allocation to fail: we SIGKILL ourselves the instant
memory gets tight, while the system is still responsive.

Adapted from llama-testing/scripts/oom_watchdog.sh and its bench-script thread guard.

    from oomguard import arm
    arm()          # before loading any model

Two triggers, polled every INTERVAL seconds:
  1. available RAM below floor_mb
  2. a swap storm — pages written to swap jumping by more than swap_delta_mb in one
     interval, which is the real early warning on Apple silicon

SIGKILL (not SIGTERM) is deliberate: a graceful shutdown still has to unwind gigabytes
of allocations, which is exactly what we cannot afford at that moment.
"""

import logging
import os
import signal
import threading
import time

import psutil

FLOOR_MB = 3000
SWAP_DELTA_MB = 1024
INTERVAL = 1.0

log = logging.getLogger("oomguard")


def watch(floor_mb, swap_delta_mb, interval):
    previous_swap = psutil.swap_memory().sout
    while True:
        time.sleep(interval)
        available_mb = psutil.virtual_memory().available / (1024 * 1024)
        if available_mb < floor_mb:
            trip(f"available RAM {available_mb:.0f}MiB < floor {floor_mb}MiB")
        current_swap = psutil.swap_memory().sout
        swapped_mb = (current_swap - previous_swap) / (1024 * 1024)
        previous_swap = current_swap
        if swapped_mb > swap_delta_mb:
            trip(f"swap storm: {swapped_mb:.0f}MiB paged out in {interval}s (>{swap_delta_mb}MiB)")


def trip(reason):
    # Bypass logging handlers/buffering — we are about to die on purpose.
    message = f"\n[oomguard] !!! TRIGGER: {reason} -> SIGKILL self (pid {os.getpid()}) NOW\n"
    try:
        os.write(2, message.encode())
    except OSError:
        pass
    os.kill(os.getpid(), signal.SIGKILL)


def arm(floor_mb=FLOOR_MB, swap_delta_mb=SWAP_DELTA_MB, interval=INTERVAL):
    """Start the guard. Call before loading a model."""
    if os.environ.get("TTS_NO_OOMGUARD"):
        log.warning("oomguard DISABLED via TTS_NO_OOMGUARD — generation can hang the machine")
        return
    thread = threading.Thread(
        target=watch, args=(floor_mb, swap_delta_mb, interval), daemon=True
    )
    thread.start()
    total_gb = psutil.virtual_memory().total / (1024 ** 3)
    log.info(
        "oomguard armed: floor=%dMiB swap_delta=%dMiB interval=%.1fs (machine %.0f GiB)",
        floor_mb, swap_delta_mb, interval, total_gb,
    )
