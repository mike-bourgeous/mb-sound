---
name: agent-brief
description: Template for briefing a background agent on mb-sound work (feature branch, research spike, or follow-up round), so its prompt is self-contained and its report arrives once.
---

# Briefing a background agent

A background agent starts with no conversation context.  Its prompt must stand alone.  Include, in order:

1. **Read first:** `/app/CLAUDE.md` (authoritative; it imports `.claude/collaboration.md`), the `design/notes/<topic>.md` files for the subsystems it touches, plus any proposal, research branch, or note the work builds on (give exact paths, branches and commits).
2. **Where to work:** a new worktree `.claude/worktrees/<topic>` on a new branch `<topic>` off `master-ai` (give the current tip), then `bundle exec rake -f Rakefile compile` (`clean compile` if ext/ changed since the last build).  Name any other branch an agent is working on and the files to avoid.
3. **The maintainer's decisions, verbatim or exactly paraphrased,** with dates.  Separate what is decided from what the agent may choose ("conservative choice, list it as a question").
4. **Scope in order,** with the order to stop in if time runs out ("finish in order at clean, tested commit boundaries and say what's left").
5. **Measurements expected:** e.g. `bin/graph_profile.rb --plan both` on named scripts, steady (`c_major.mid`) and worst case (`spec/test_data/dense_modulated.mid`), 128/512-sample buffers, alternating against a master-ai worktree; always report the worst case.
6. **Tests:** affected specs, full suite saved to a file and grepped, `MB_SOUND_PLAN_CHECK=1` suite when plan code changes, `--tag smoke` when bin/ or nodes touching input buffers change, `rake -f Rakefile memcheck:changed` (with `MEMCHECK_DRY=1` first) when ext/ or code calling extensions changes.  No heavy runs concurrently with other heavy runs.
7. **Listening renders** for anything that changes sound: files in `/app/tmp/listening/<topic>/` with a `bench_set.py` (new set id with the date, a `code` snippet per variant, at most 5 variants per item, gains listed); do not publish.
8. **Commits:** step by step, messages written to files (`git commit -F`), ending with the session's attribution lines.  **Do NOT merge.**  Kill only processes it started, by PID.
9. **Progress updates:** a ONE-LINE message to the main session (`SendMessage`; find its name with `ListAgents`) at each milestone: starting a scope item, a commit, a long run started or finished (suite, check mode, smoke, memcheck, profiling), a blocker or a change of plan.  About every 15-30 minutes of work, never more than one every few minutes, never silent for over 30 minutes while working.  Shape: `<branch>: <what just happened>; next: <what's next>` (e.g. `plan-p3b: SIMD Tone op committed (3/5), check-mode suite running ~6 min; next: wavetable ops`).  No summaries, numbers tables, or questions in updates; questions wait for the final report unless the agent is blocked.  If `SendMessage` isn't available, keep going and put the timeline in the final report.  The main session relays these to the maintainer as one-liners (see collaboration.md on holding summaries).
10. **Report:** "ONE final report (no repeats)": commits, design, measurements, tests, renders, and a SHORT numbered list of questions.  (Agents that wait on their own background runs otherwise re-send their report each time they wake.)

Research spikes add: a never-merged `research-<topic>` branch with everything in `research/<topic>/` (README with the question in the maintainer's words, date, method, results, recommendation), committed once, plus a short proposal note pointing to the branch and commit.
