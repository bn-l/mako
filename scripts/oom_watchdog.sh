#!/usr/bin/env bash
# Brutal, early, immediate OOM watchdog for TTS generation on Apple Silicon.
#
# Adapted from llama-testing/scripts/oom_watchdog.sh. TTS generation here loads
# multi-gigabyte models (fish-audio-s2-pro bf16 ~10 GB; VoxCPM2 runs fp32 on MPS),
# and when RAM runs out macOS thrashes into a multi-minute whole-machine hang
# instead of failing fast. So we kill the generation the moment memory gets tight,
# while the system is still responsive.
#
# SIGKILLs every process matching <pgrep_pattern> the instant ANY of these fire:
#   1. Truly-free RAM (free + speculative + inactive + purgeable) < FLOOR_MB.
#   2. A swap storm: pageouts jump by more than SWAP_DELTA pages in one interval.
#   3. An OOM signature appears in the optional log file.
#
# Usage: oom_watchdog.sh <pgrep_pattern> [floor_mb] [swap_delta_pages] [interval_s] [log_path]
#
#   scripts/oom_watchdog.sh 'scripts/tts-gen/gen_' 3000 &
#   WATCHDOG=$!
#   uv run scripts/tts-gen/gen_mlx.py --model ... --out ...
#   kill $WATCHDOG 2>/dev/null
#
# Prefer this when driving generation from the shell. The scripts also arm an
# in-process guard (scripts/tts-gen/oomguard.py); running both is fine and is the
# belt-and-braces default.

set -u

PATTERN="${1:?pgrep pattern required}"
FLOOR_MB="${2:-3000}"
SWAP_DELTA="${3:-80000}"   # pages (16KiB each) => ~1.25 GiB paged out in one interval
INTERVAL="${4:-0.3}"
LOG="${5:-}"
PAGE=16384

ts() { date +%H:%M:%S; }

kill_gen() {
  echo "[watchdog $(ts)] !!! TRIGGER: $1 -> SIGKILL '$PATTERN' NOW"
  pkill -9 -f "$PATTERN"
  local pids
  pids=$(pgrep -f "$PATTERN")
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  echo "[watchdog $(ts)] killed. watchdog exiting."
  exit 42
}

avail_mb() {
  vm_stat | awk -v pg=$PAGE '
    /Pages free/        {gsub("[^0-9]","",$3); f=$3}
    /Pages speculative/ {gsub("[^0-9]","",$3); s=$3}
    /Pages inactive/    {gsub("[^0-9]","",$3); i=$3}
    /Pages purgeable/   {gsub("[^0-9]","",$3); p=$3}
    END{print int((f+s+i+p)*pg/1048576)}'
}

prev_pageout=$(vm_stat | awk '/Pageouts/{gsub("[^0-9]","",$NF);print $NF}')
[ -z "$prev_pageout" ] && prev_pageout=0

echo "[watchdog $(ts)] armed on pattern='$PATTERN' floor=${FLOOR_MB}MiB swap_delta=${SWAP_DELTA}pg interval=${INTERVAL}s"

while true; do
  # Nothing to guard yet is fine (the model may still be downloading), but once a
  # target has appeared and then vanished, our work is done.
  if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    seen=1
  elif [ "${seen:-0}" = "1" ]; then
    echo "[watchdog $(ts)] target finished; exiting."
    exit 0
  fi

  availmb=$(avail_mb)
  if [ -n "$availmb" ] && [ "$availmb" -lt "$FLOOR_MB" ]; then
    kill_gen "available RAM ${availmb}MiB < floor ${FLOOR_MB}MiB"
  fi

  cur_pageout=$(vm_stat | awk '/Pageouts/{gsub("[^0-9]","",$NF);print $NF}')
  [ -z "$cur_pageout" ] && cur_pageout=$prev_pageout
  delta=$(( cur_pageout - prev_pageout ))
  if [ "$delta" -gt "$SWAP_DELTA" ]; then
    kill_gen "swap storm: ${delta} pages paged out in one interval (>${SWAP_DELTA})"
  fi
  prev_pageout=$cur_pageout

  if [ -n "$LOG" ] && grep -qiE "Insufficient Memory|OutOfMemory|MTLCommandBuffer|command buffer [0-9]+ failed|failed to allocate|Metal error|std::bad_alloc" "$LOG" 2>/dev/null; then
    kill_gen "OOM/Metal-failure signature in $LOG"
  fi

  sleep "$INTERVAL"
done
