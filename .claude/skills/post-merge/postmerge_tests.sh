#!/usr/bin/env bash
# Post-merge checks for mb-sound: clean compile, full suite, smoke suite,
# memcheck status; FULLMC=1 also runs the full memcheck.  Output files go in
# $OUT (default: a new temp dir), so results can be grepped instead of rerun.
# Usage: .claude/skills/post-merge/postmerge_tests.sh [checkout dir]
set -uo pipefail
cd "${1:-/app}"
OUT="${OUT:-$(mktemp -d -t postmerge.XXXXXX)}"
echo "output in $OUT"
bundle exec rake -f Rakefile clean compile > "$OUT/compile.txt" 2>&1 && echo "compile ok" || { echo "compile FAILED"; exit 1; }
bundle exec rspec > "$OUT/suite.txt" 2>&1; grep -E "^[0-9]+ examples" "$OUT/suite.txt"; grep -E "^rspec " "$OUT/suite.txt" | head
bundle exec rspec --tag smoke > "$OUT/smoke.txt" 2>&1; grep -E "^[0-9]+ examples" "$OUT/smoke.txt"; grep -E "^rspec " "$OUT/smoke.txt" | head
bundle exec rake -f Rakefile memcheck:status 2>&1 | tail -5
if [ "${FULLMC:-0}" = 1 ]; then
  bundle exec rake -f Rakefile memcheck > "$OUT/memcheck.txt" 2>&1; echo "memcheck exit $?"
  grep -E "^[0-9]+ examples" "$OUT/memcheck.txt" | tail -1
  grep -cE "Invalid (read|write)|definitely lost: [1-9]" "$OUT/memcheck.txt"
  bundle exec rake -f Rakefile memcheck:status 2>&1 | tail -2
fi
