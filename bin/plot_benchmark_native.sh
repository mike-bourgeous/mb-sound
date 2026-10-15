#!/bin/bash
# Native plot-pane numbers for ui-2 step 1: bin/plot_benchmark.rb on this
# machine (macOS or Linux, outside Docker), in memory and in the terminal
# window it runs in.  Run it in each terminal to compare (iTerm2,
# Terminal.app, Konsole, ...), with the window at least 122x47 and the
# machine otherwise quiet; about 6 minutes (QUICK=1: about 2).
#
#     bin/plot_benchmark_native.sh
#     QUICK=1 bin/plot_benchmark_native.sh
#
# Steps: compiles the extensions (a native build, as `rake compile` does
# on this machine), then
# 1. in memory, YJIT off and on: the old path (Plot::Text.render with the
#    Ruby kernels, MB_SOUND_PLOT=ruby: close to master-ai) and the new one
#    (Plot::Live with FastUI);
# 2. in this terminal: every look on the scope, spectrum, and 120x45
#    two-channel vis panes, changed cells only, then full redraws, then
#    without synchronized output (fps includes the terminal's own drawing:
#    each run ends with a cursor position query it must answer).
# Results go to tmp/ui-2/native_<host>_<date>/ (tables in summary.md).
set -euo pipefail
cd "$(dirname "$0")/.."
host="$(hostname -s 2>/dev/null || hostname)"
out="tmp/ui-2/native_${host}_$(date +%Y%m%d_%H%M)"
mkdir -p "$out"
bundle exec rake -f Rakefile compile >/dev/null

frames=300
tty_frames=600
looks=scope,blocks,mosaic,quad,spark,ascii
colors=truecolor,ansi256,ansi16,none
if [ "${QUICK:-0}" = 1 ]; then
  frames=100
  tty_frames=300
  looks=scope,blocks,ascii
  colors=truecolor
fi

{
  echo "# Native plot benchmark: $(uname -sm), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')"
  echo "Terminal: ${TERM_PROGRAM:-?} ${TERM_PROGRAM_VERSION:-} ${KONSOLE_VERSION:+Konsole $KONSOLE_VERSION} TERM=${TERM:-?}, window $(tput cols)x$(tput lines)"
  echo
  echo "## In memory: before (Ruby kernels, Text.render)"
  MB_SOUND_PLOT=ruby bin/plot_benchmark.rb --yjit both --api render -n "$frames" -l "$looks" -c "$colors" -j "$out/before.json"
  echo
  echo "## In memory: after (FastUI, Plot::Live)"
  bin/plot_benchmark.rb --yjit both --api live -n "$frames" -l "$looks" -c "$colors" -j "$out/after.json" -B "$out/before.json"
} | tee "$out/summary.md"

# Terminal runs need the terminal on stdout (no tee): each appends its
# table to summary.md and prints it after its alternate screen closes
s="$out/summary.md"
echo "## In this terminal: changed cells, synchronized output" >>"$s"
bin/plot_benchmark.rb --tty -p scope,spectrum,vis -l "$looks" -c truecolor,ansi256 -n "$tty_frames" -j "$out/tty_cells.json" -R "$s"
echo "## In this terminal: full redraws" >>"$s"
bin/plot_benchmark.rb --tty --full -p scope,vis -l scope,blocks,quad,ascii -c truecolor -n "$tty_frames" -j "$out/tty_full.json" -R "$s"
echo "## In this terminal: changed cells, no synchronized output" >>"$s"
bin/plot_benchmark.rb --tty --no-sync -p vis -l scope,blocks,ascii -c truecolor -n "$tty_frames" -j "$out/tty_nosync.json" -R "$s"
echo "## In this terminal: the old path for comparison (Ruby kernels, full redraws)" >>"$s"
MB_SOUND_PLOT=ruby bin/plot_benchmark.rb --tty --full -p vis -l scope,blocks -c truecolor -n 200 -j "$out/tty_before.json" -R "$s"

echo
echo "Saved in $out (summary.md has every table)."
