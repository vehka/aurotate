#!/bin/bash
# analyze.sh: one disk pass over a tape, writing the analysis cache.
#
#   analyze.sh <cache dir> <aurpeaks binary> <file> [<file> ...]
#
# Several files are a reel (recorder split files): they are analysed as one
# tape, in the order given (sox concatenates them).
#
# Writes into the cache dir:
#   peaks      aurpeaks output (level 0 grows while the pass runs)
#   p1.wav     proxy, mono 16-bit, rate / 8   (≈ 6 kHz for 48 kHz)
#   p2.wav     proxy, mono 16-bit, rate / 64  (≈ 750 Hz)
#   info       key=value: frames, rate, channels, p1_rate, p2_rate, secs, bext_*
#   progress   frames analysed so far (from aurpeaks)
#   pid        while running (the process group id: kill -- -<pid>)
#   lock       flock'd while a job runs; a second job for the dir exits
#   done       when finished; `fail` (with the reason) otherwise
#
# Builds aurpeaks from aurpeaks.c next to this script when the binary is
# missing or older. Meant to run detached: setsid nice ionice … &

set -u -o pipefail
dir=$1
bin=$2
shift 2
ins=("$@")
in=${ins[0]}
src=$(cd "$(dirname "$0")" && pwd)/aurpeaks.c

mkdir -p "$dir" || exit 1
cd "$dir" || exit 1
# one job per cache dir. A job the script couldn't kill (stopped before it
# wrote its pid) would otherwise run alongside the next one: two decoders
# fighting over the same files (and the SD card, which gave xruns)
exec 9> lock
flock -n 9 || exit 0
rm -f done fail progress info peaks p1.wav p2.wav ./*.tmp ./*.tmp.wav fifo_*
echo $$ > pid
t0=$(date +%s.%N)

fail() {
  echo "$1" > fail
  jobs -p | xargs -r kill 2> /dev/null
  rm -f pid fifo_*
  exit 1
}

if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
  mkdir -p "$(dirname "$bin")"
  gcc -O2 -o "$bin" "$src" -lm 2> build.log || fail "can't build aurpeaks (build.log)"
fi

rate=$(soxi -r "$in" 2> /dev/null) || fail "not a sound file sox can read"
ch=$(soxi -c "$in")
p1=$(( (rate + 4) / 8 ))
p2=$(( (rate + 32) / 64 ))
raw="-t raw -e signed -b 16 -L -r $rate -c $ch"

mkfifo fifo_pk fifo_p1 || fail "mkfifo"
"$bin" -r "$rate" -c "$ch" -p progress peaks.tmp < fifo_pk > peaks.info &
pk=$!
# shellcheck disable=SC2086
sox -V1 $raw fifo_p1 -b 16 p1.tmp.wav channels 1 rate "$p1" &
s1=$!
# shellcheck disable=SC2086
sox -V1 "${ins[@]}" -t raw -e signed -b 16 -L - | tee fifo_pk fifo_p1 \
  | sox -V1 $raw - -b 16 p2.tmp.wav channels 1 rate "$p2" || fail "decode / P2"
wait $pk || fail "aurpeaks"
wait $s1 || fail "P1"

mv peaks.tmp peaks && mv p1.tmp.wav p1.wav && mv p2.tmp.wav p2.wav || fail "rename"
{
  cat peaks.info
  echo "p1_rate=$p1"
  echo "p2_rate=$p2"
  awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "secs=%.1f\n", b - a }'
  case "${in,,}" in
    *.wav | *.bwf) "$bin" -w "$in" ;;
  esac
} > info
rm -f pid fifo_* peaks.info
touch done
