#!/usr/bin/env bash
# Finds which merge of a batch a failing spec came from: runs the spec at
# each first-parent merge after FROM up to TO (default master-ai), oldest
# first, in a detached scratch worktree, and stops at the first failure.
# Usage: .claude/skills/post-merge/find_merge.sh FROM 'spec/x_spec.rb:42' [TO]
set -euo pipefail
from="$1"; spec="$2"; to="${3:-master-ai}"
dir="/claude/worktrees/find-merge-$$"
OUT="${OUT:-$(mktemp -d -t find_merge.XXXXXX)}"
git -C /app worktree add --detach --lock --reason "find_merge: $spec" "$dir" "$to" > /dev/null
trap 'git -C /app worktree unlock "$dir"; git -C /app worktree remove "$dir" || echo "left $dir in place (git status there)"' EXIT
for m in $(git -C /app rev-list --first-parent --merges --reverse "$from..$to"); do
  git -C "$dir" checkout -q --detach "$m"
  (cd "$dir" && bundle exec rake -f Rakefile compile -j 8) > "$OUT/$m.compile.txt" 2>&1 || { echo "$m: compile FAILED ($OUT/$m.compile.txt)"; exit 1; }
  if (cd "$dir" && bundle exec rspec "$spec" > "$OUT/$m.txt" 2>&1); then
    echo "$m passes: $(git -C /app log -1 --format=%s "$m")"
  else
    echo "$m FAILS: $(git -C /app log -1 --format=%s "$m") ($OUT/$m.txt)"
    exit 0
  fi
done
echo "no merge in $from..$to fails $spec"
