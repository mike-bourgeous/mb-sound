#!/bin/bash
# SessionStart hook (resume, compact): repeats CLAUDE.md's "How we build"
# section and where to look next, since a summary keeps the task but tends
# to lose the project's habits (maintainer, 2026-11-04: an unbriefed
# session wrote a standalone audio engine instead of using graph nodes).
dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
echo "mb-sound session restarted: keep building on the library."
sed -n '/^### How we build/,/^## /p' "$dir/CLAUDE.md" | sed '$d'
echo "Next: find building blocks in design/notes/README.md (Quick references) before writing code; re-read the topic's note before changing a subsystem."
