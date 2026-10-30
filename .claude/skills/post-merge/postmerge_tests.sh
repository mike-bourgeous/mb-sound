#!/usr/bin/env bash
# The end of a merge batch for mb-sound (the merge train, 2026-10-30): clean
# compile, then `rake merge:batch` (the full suite with the :slow tier,
# smoke, golden:check, and a fuzz soak; spec/merge_gate.rb), then the
# memcheck status; FULLMC=1 also runs the full memcheck (only when the
# maintainer asks: full runs are manual since 2026-10-18).  Each merge of
# the batch already passed `rake merge:gate`.  Output files go in $OUT
# (default: a new temp dir), so results can be grepped instead of rerun.
# Usage: .claude/skills/post-merge/postmerge_tests.sh [checkout dir]
set -uo pipefail
cd "${1:-/app}"
OUT="${OUT:-$(mktemp -d -t postmerge.XXXXXX)}"
export OUT
echo "output in $OUT"
bundle exec rake -f Rakefile clean compile > "$OUT/compile.txt" 2>&1 && echo "compile ok" || { echo "compile FAILED"; exit 1; }
bundle exec rake -f Rakefile merge:batch > "$OUT/batch.txt" 2>&1; echo "merge:batch exit $?"
grep -E "^merge:batch: |^  rspec " "$OUT/batch.txt"
bundle exec rake -f Rakefile memcheck:status 2>&1 | tail -5
if [ "${FULLMC:-0}" = 1 ]; then
  bundle exec rake -f Rakefile memcheck > "$OUT/memcheck.txt" 2>&1; echo "memcheck exit $?"
  grep -E "^[0-9]+ examples" "$OUT/memcheck.txt" | tail -1
  grep -cE "Invalid (read|write)|definitely lost: [1-9]" "$OUT/memcheck.txt"
  bundle exec rake -f Rakefile memcheck:status 2>&1 | tail -2
fi
